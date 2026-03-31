#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# install-nemoclaw-conda.sh
#
# v11
#
# Installs NemoClaw + OpenShell into a dedicated conda environment so the CLI
# tooling stays contained. Docker still runs on the host.
#
# Key behavior:
#   - Creates or reuses a named conda env
#   - Installs Node.js into that env
#   - Keeps npm global packages inside the env
#   - Installs NemoClaw from a local source tree by default
#   - Refuses the broken placeholder npm package "nemoclaw" unless overridden
#   - Installs OpenShell into $CONDA_PREFIX/bin
#   - Creates conda activate/deactivate hooks for PATH
#   - Verifies hook files exist
#   - Verifies the nemoclaw executable exists in the env npm-global/bin
#   - Safely handles conda activation even when external activate scripts are
#     not compatible with `set -u`
#   - Skips OpenShell download if already present, unless forced
#   - Supports --force-reinstall
#   - Only runs npm build if a build script actually exists
#   - Prints installer version on startup
#   - Supports custom OpenAI-compatible endpoints such as remote Ollama during onboarding
#   - Optionally runs 'nemoclaw onboard'
#
# -----------------------------------------------------------------------------

SCRIPT_VERSION="v11"

ENV_NAME="nemoclaw"
NODE_VERSION="22"
SOURCE_DIR=""
NPM_PACKAGE=""
ALLOW_PLACEHOLDER_NPM="no"
RUN_ONBOARD="yes"
OPEN_SHELL_VERSION=""   # optional: e.g. "0.0.16"
MIN_OPEN_SHELL_VERSION="0.1.0"
FORCE_REINSTALL="no"
OLLAMA_BASE_URL=""
OLLAMA_MODEL_ID=""

log()  { printf '\n[%s] %s\n' "INFO" "$*"; }
warn() { printf '\n[%s] %s\n' "WARN" "$*" >&2; }
err()  { printf '\n[%s] %s\n' "ERROR" "$*" >&2; }

usage() {
  cat <<EOF
install-nemoclaw-conda.sh ${SCRIPT_VERSION}

Usage:
  $(basename "$0") [options]

Options:
  --env NAME                 Conda environment name (default: ${ENV_NAME})
  --node VERSION             Node.js version for conda (default: ${NODE_VERSION})
  --source DIR               Install NemoClaw from local source tree at DIR
  --npm-package NAME         Install NemoClaw from npm package NAME
  --allow-placeholder-npm    Allow npm package 'nemoclaw' (NOT recommended)
  --openshell-version V      Install a specific OpenShell version
  --force-reinstall          Reinstall NemoClaw/OpenShell even if already present
  --skip-onboard             Do not run 'nemoclaw onboard'
  --ollama-base-url URL      Custom remote Ollama/OpenAI-compatible base URL
  --ollama-model MODEL       Optional model id for non-interactive onboarding
  --version                  Print script version and exit
  --help                     Show this help

Recommended:
  --source /path/to/NemoClaw

Notes:
  - Exactly one of --source or --npm-package may be provided.
  - If neither is provided, the script installs from the current working
    directory if it looks like a NemoClaw source tree.
  - Otherwise, it refuses to default to npm package 'nemoclaw' because that
    package name is currently unsafe/broken for the real CLI.
  - For remote Ollama, use the native base URL without /v1, for example:
      http://172.32.1.250:24601
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="${2:?missing value for --env}"
      shift 2
      ;;
    --node)
      NODE_VERSION="${2:?missing value for --node}"
      shift 2
      ;;
    --source)
      SOURCE_DIR="${2:?missing value for --source}"
      shift 2
      ;;
    --npm-package)
      NPM_PACKAGE="${2:?missing value for --npm-package}"
      shift 2
      ;;
    --allow-placeholder-npm)
      ALLOW_PLACEHOLDER_NPM="yes"
      shift
      ;;
    --openshell-version)
      OPEN_SHELL_VERSION="${2:?missing value for --openshell-version}"
      shift 2
      ;;
    --force-reinstall)
      FORCE_REINSTALL="yes"
      shift
      ;;
    --skip-onboard)
      RUN_ONBOARD="no"
      shift
      ;;
    --ollama-base-url)
      OLLAMA_BASE_URL="${2:?missing value for --ollama-base-url}"
      shift 2
      ;;
    --ollama-model)
      OLLAMA_MODEL_ID="${2:?missing value for --ollama-model}"
      shift 2
      ;;
    --version)
      echo "$(basename "$0") ${SCRIPT_VERSION}"
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

printf '%s %s\n' "$(basename "$0")" "${SCRIPT_VERSION}"

if [[ -n "$SOURCE_DIR" && -n "$NPM_PACKAGE" ]]; then
  err "Use only one of --source or --npm-package"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command not found: $1"
    exit 1
  }
}

need_cmd conda
need_cmd curl
need_cmd tar
need_cmd install
need_cmd grep
need_cmd node
need_cmd npm

safe_eval_conda_hook() {
  set +u
  eval "$("$(command -v conda)" shell.bash hook)"
  set -u
}

safe_conda_activate() {
  set +u
  conda activate "$1"
  set -u
}

safe_eval_conda_hook

conda_env_exists() {
  conda env list | awk '{print $1}' | grep -Fxq "$1"
}

if ! conda_env_exists "$ENV_NAME"; then
  log "Creating conda environment '$ENV_NAME' with Node.js $NODE_VERSION"
  conda create -y -n "$ENV_NAME" "nodejs=$NODE_VERSION"
else
  log "Conda environment '$ENV_NAME' already exists"
fi

log "Activating conda environment '$ENV_NAME'"
safe_conda_activate "$ENV_NAME"

if [[ -z "${CONDA_PREFIX:-}" ]]; then
  err "Failed to activate conda environment"
  exit 1
fi

log "Using CONDA_PREFIX=$CONDA_PREFIX"

mkdir -p \
  "$CONDA_PREFIX/bin" \
  "$CONDA_PREFIX/npm-global" \
  "$CONDA_PREFIX/etc/conda/activate.d" \
  "$CONDA_PREFIX/etc/conda/deactivate.d"

npm config set prefix "$CONDA_PREFIX/npm-global" >/dev/null

export PATH="$CONDA_PREFIX/bin:$CONDA_PREFIX/npm-global/bin:$PATH"
hash -r

log "Node version: $(node --version)"
log "npm version:  $(npm --version)"

write_conda_hooks() {
  local act_hook="$CONDA_PREFIX/etc/conda/activate.d/nemoclaw-path.sh"
  local deact_hook="$CONDA_PREFIX/etc/conda/deactivate.d/nemoclaw-path.sh"

  cat > "$act_hook" <<'EOF'
#!/usr/bin/env bash
export _NEMOCLAW_OLD_PATH="${PATH:-}"
export PATH="$CONDA_PREFIX/bin:$CONDA_PREFIX/npm-global/bin:$PATH"
hash -r 2>/dev/null || true
EOF

  cat > "$deact_hook" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${_NEMOCLAW_OLD_PATH:-}" ]]; then
  export PATH="$_NEMOCLAW_OLD_PATH"
  unset _NEMOCLAW_OLD_PATH
fi
hash -r 2>/dev/null || true
EOF

  chmod +x "$act_hook" "$deact_hook"

  [[ -f "$act_hook" ]] || {
    err "Failed to create conda activate hook: $act_hook"
    exit 1
  }

  [[ -f "$deact_hook" ]] || {
    err "Failed to create conda deactivate hook: $deact_hook"
    exit 1
  }
}

detect_source_tree() {
  local dir="$1"
  [[ -f "$dir/package.json" ]] || return 1
  grep -qi 'nemoclaw' "$dir/package.json"
}

has_npm_build_script() {
  node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    process.exit(pkg.scripts && typeof pkg.scripts.build === "string" && pkg.scripts.build.trim() ? 0 : 1);
  ' >/dev/null 2>&1
}

install_nemoclaw_from_source() {
  local src="$1"

  [[ -d "$src" ]] || {
    err "Source dir not found: $src"
    exit 1
  }

  log "Installing NemoClaw from source: $src"
  pushd "$src" >/dev/null

  [[ -f package.json ]] || {
    err "No package.json found in source directory: $src"
    exit 1
  }

  if [[ "$FORCE_REINSTALL" == "yes" ]]; then
    warn "Force reinstall requested, removing existing global link if present"
    npm uninstall -g nemoclaw >/dev/null 2>&1 || true
  fi

  npm install

  if has_npm_build_script; then
    log "Build script detected, running npm run build"
    npm run build
  else
    log "No build script defined, skipping npm run build"
  fi

  npm link

  popd >/dev/null
  hash -r
}

install_nemoclaw_from_npm() {
  local pkg="$1"

  if [[ "$pkg" == "nemoclaw" && "$ALLOW_PLACEHOLDER_NPM" != "yes" ]]; then
    err "Refusing to install npm package 'nemoclaw' because the public package is currently unsafe/broken for the real CLI."
    err "Use --source /path/to/NemoClaw instead."
    err "If you really want it anyway, re-run with --allow-placeholder-npm."
    exit 1
  fi

  log "Installing NemoClaw from npm package: $pkg"

  if [[ "$FORCE_REINSTALL" == "yes" ]]; then
    npm uninstall -g "$pkg" >/dev/null 2>&1 || true
  fi

  npm install -g "$pkg"
  hash -r
}

choose_nemoclaw_install_method() {
  if [[ -n "$SOURCE_DIR" ]]; then
    install_nemoclaw_from_source "$SOURCE_DIR"
    return
  fi

  if [[ -n "$NPM_PACKAGE" ]]; then
    install_nemoclaw_from_npm "$NPM_PACKAGE"
    return
  fi

  if detect_source_tree "$PWD"; then
    log "Detected NemoClaw source tree in current directory"
    install_nemoclaw_from_source "$PWD"
    return
  fi

  err "No install source specified."
  err "Refusing to default to npm package 'nemoclaw'."
  err "Re-run with: --source /path/to/NemoClaw"
  exit 1
}

verify_nemoclaw_launcher() {
  local expected_bin="$CONDA_PREFIX/npm-global/bin/nemoclaw"

  [[ -e "$expected_bin" ]] || {
    err "nemoclaw binary was not created at expected path: $expected_bin"
    err "npm prefix -g: $(npm prefix -g)"
    err "npm config get prefix: $(npm config get prefix)"
    exit 1
  }
}

extract_semver() {
  local value="$1"
  sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' <<<"$value" | head -n1
}

version_ge() {
  local left="$1"
  local right="$2"
  [[ "$left" == "$right" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$right" "$left" | sort -V | tail -n1)" == "$left" ]]
}

install_openshell() {
  local version="$1"
  local arch os url tmpdir tarball extracted_bin api_url current_version current_output

  if [[ "$FORCE_REINSTALL" != "yes" && -x "$CONDA_PREFIX/bin/openshell" ]]; then
    current_output="$("$CONDA_PREFIX/bin/openshell" --version 2>/dev/null || true)"
    current_version="$(extract_semver "$current_output")"

    if [[ -n "$current_version" ]] && version_ge "$current_version" "$MIN_OPEN_SHELL_VERSION"; then
      log "OpenShell already present at $CONDA_PREFIX/bin/openshell (version $current_version), skipping download"
      return
    fi

    warn "Existing OpenShell version '${current_version:-unknown}' is older than required minimum ${MIN_OPEN_SHELL_VERSION}"
    warn "Upgrading OpenShell in $CONDA_PREFIX/bin"
  fi

  case "$(uname -m)" in
    x86_64)         arch="x86_64" ;;
    aarch64|arm64)  arch="aarch64" ;;
    *)
      err "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac

  os="unknown-linux-musl"

  if [[ -n "$version" ]]; then
    log "Installing OpenShell version v${version}"
  else
    log "Resolving latest OpenShell version"
    api_url="https://api.github.com/repos/NVIDIA/OpenShell/releases/latest"
    version="$(
      curl -fsSL "$api_url" \
      | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' \
      | head -n1
    )"

    [[ -n "$version" ]] || {
      err "Could not resolve latest OpenShell release version"
      err "You can also specify one explicitly with --openshell-version X.Y.Z"
      exit 1
    }
  fi

  url="https://github.com/NVIDIA/OpenShell/releases/download/v${version}/openshell-${arch}-${os}.tar.gz"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  tarball="$tmpdir/openshell.tar.gz"

  log "Downloading OpenShell from: $url"
  curl -fL "$url" -o "$tarball"

  log "Extracting OpenShell"
  tar -xzf "$tarball" -C "$tmpdir"

  extracted_bin="$(find "$tmpdir" -type f -name openshell | head -n1)"
  [[ -n "$extracted_bin" ]] || {
    err "Could not find extracted openshell binary"
    exit 1
  }

  install -m 0755 "$extracted_bin" "$CONDA_PREFIX/bin/openshell"
  hash -r
}

verify_in_env() {
  local tool="$1"
  local resolved
  resolved="$(command -v "$tool" || true)"

  if [[ -z "$resolved" ]]; then
    err "$tool not found after installation"
    exit 1
  fi

  log "$tool resolved to: $resolved"

  case "$resolved" in
    "$CONDA_PREFIX"/*) ;;
    *)
      warn "$tool is not resolving from CONDA_PREFIX"
      ;;
  esac
}

normalize_remote_ollama_base_url() {
  local raw="$1"

  [[ -n "$raw" ]] || {
    err "Empty remote Ollama base URL"
    exit 1
  }

  if [[ "$raw" =~ ^https?://[^/]+$ ]]; then
    printf '%s/v1\n' "$raw"
    return
  fi

  if [[ "$raw" =~ ^https?://[^/]+/$ ]]; then
    printf '%sv1\n' "$raw"
    return
  fi

  printf '%s\n' "${raw%/}"
}

run_nemoclaw_onboard_with_policy_recovery() {
  local session_file="${HOME}/.nemoclaw/onboard-session.json"
  local log_file
  local status=0

  log_file="$(mktemp)"
  trap 'rm -f "$log_file"' RETURN

  set +e
  "$@" 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -ne 0 ]]; then
    if [[ -f "$session_file" ]] && grep -Eq "Unimplemented|policy updates are not supported" "$log_file"; then
      warn "NemoClaw policy presets are not supported by the current gateway build"
      warn "Clearing saved policy preset selections from the onboarding session"
      node -e '
        const fs = require("fs");
        const path = process.argv[1];
        const data = JSON.parse(fs.readFileSync(path, "utf8"));
        data.policyPresets = [];
        fs.writeFileSync(path, JSON.stringify(data, null, 2));
      ' "$session_file"
      warn "Attempting onboarding recovery by resuming with policy presets skipped"
      NEMOCLAW_POLICY_MODE=skip nemoclaw onboard --resume --non-interactive
      return
    fi
    return "$status"
  fi
}

run_onboard() {
  if [[ "$RUN_ONBOARD" != "yes" ]]; then
    log "Skipping onboarding as requested"
    return
  fi

  log "Running NemoClaw onboarding"

  if [[ -n "$OLLAMA_BASE_URL" ]]; then
    local normalized_base_url
    normalized_base_url="$(normalize_remote_ollama_base_url "$OLLAMA_BASE_URL")"

    log "Using custom OpenAI-compatible endpoint for remote Ollama: $normalized_base_url"
    if [[ -n "$OLLAMA_MODEL_ID" ]]; then
      log "Using custom model: $OLLAMA_MODEL_ID"
    fi
    log "Providing placeholder COMPATIBLE_API_KEY for non-interactive custom endpoint onboarding"

    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_ENDPOINT_URL="$normalized_base_url" \
    NEMOCLAW_MODEL="${OLLAMA_MODEL_ID:-}" \
    COMPATIBLE_API_KEY="${COMPATIBLE_API_KEY:-ollama}" \
    run_nemoclaw_onboard_with_policy_recovery nemoclaw onboard --non-interactive
  else
    nemoclaw onboard
  fi
}

write_conda_hooks
choose_nemoclaw_install_method
verify_nemoclaw_launcher
verify_in_env nemoclaw

install_openshell "$OPEN_SHELL_VERSION"
verify_in_env openshell

log "Versions"
echo "  installer: ${SCRIPT_VERSION}"
echo "  node:      $(node --version)"
echo "  npm:       $(npm --version)"
echo "  nemoclaw:  $(command -v nemoclaw)"
echo "  openshell: $(command -v openshell)"
openshell --version || true

run_onboard

if ! echo "$PATH" | tr ':' '\n' | grep -Fxq "$CONDA_PREFIX/npm-global/bin"; then
  warn "$CONDA_PREFIX/npm-global/bin is not on PATH in the current shell"
  warn "Run: conda deactivate && conda activate $ENV_NAME"
fi

log "Done"
echo
echo "To use later:"
echo "  conda activate $ENV_NAME"
echo
echo "If 'which nemoclaw' is empty in the current shell, run:"
echo "  conda deactivate && conda activate $ENV_NAME"
echo
echo "Installed paths:"
echo "  $CONDA_PREFIX/bin/openshell"
echo "  $CONDA_PREFIX/npm-global/bin (npm global binaries)"

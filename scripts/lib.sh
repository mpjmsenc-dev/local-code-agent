#!/usr/bin/env bash
# scripts/lib.sh — shared library for local-code-agent.
# This file is sourced by every script in the project; it is never executed
# directly. It provides logging, privilege handling, .env management and
# Ollama helpers so every script behaves the same way.

# Guard against double-sourcing (setup.sh sources it, then calls scripts that
# source it again — harmless, but re-detecting colors etc. is wasted work).
if [[ -n "${LCA_LIB_LOADED:-}" ]]; then
  return 0
fi
LCA_LIB_LOADED=1

LCA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LCA_LIB_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"
OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_DROPIN="${OLLAMA_DROPIN_DIR}/local-code-agent.conf"
NETMODE_DIR="/etc/local-code-agent"
NETMODE_STATE_FILE="${NETMODE_DIR}/netmode.state"

# ---------------------------------------------------------------------------
# Colors — tput when stdout is a terminal, plain text when piped/redirected.
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 \
  && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_BOLD="$(tput bold)"
  C_RESET="$(tput sgr0)"
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
  C_RESET=""
fi

info() { printf '%b\n' "${C_BLUE}[info]${C_RESET} $*"; }
ok()   { printf '%b\n' "${C_GREEN}[ ok ]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[warn]${C_RESET} $*" >&2; }
err()  { printf '%b\n' "${C_RED}[FAIL]${C_RESET} $*" >&2; }
die()  { err "$@"; exit 1; }
step() { printf '\n%b\n' "${C_BOLD}${C_BLUE}==> $*${C_RESET}"; }

# have CMD — true if CMD exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# require_cmd CMD... — die with a clear message if any command is missing.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "Required command '${cmd}' not found. Run ./setup.sh (or scripts/install_dependencies.sh) first."
  done
}

# as_root CMD... — run CMD with root privileges. Uses sudo only when needed.
as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    have sudo || die "Root privileges needed for: $* — but 'sudo' is not installed and you are not root. Re-run as root or install sudo."
    sudo "$@"
  fi
}

# confirm PROMPT — ask yes/no. Auto-answers YES when non-interactive so
# unattended installs (cloud-init user-data) never hang on a prompt.
confirm() {
  local prompt="${1:-Continue?}"
  if [[ ! -t 0 ]]; then
    info "Non-interactive session — auto-confirming: ${prompt}"
    return 0
  fi
  local reply=""
  read -r -p "${prompt} [Y/n] " reply || true
  [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}

# systemd_available — true when systemd is PID 1 and systemctl is usable.
systemd_available() {
  have systemctl && [[ -d /run/systemd/system ]]
}

# ---------------------------------------------------------------------------
# .env handling
# ---------------------------------------------------------------------------

# load_env — create .env from .env.example on first run, source it, then
# apply defaults for anything left unset. Safe to call repeatedly; a repeat
# call re-reads the file, so changes made via set_env_var become visible.
load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${ENV_EXAMPLE}" ]]; then
      cp "${ENV_EXAMPLE}" "${ENV_FILE}"
      info "Created ${ENV_FILE} from .env.example (edit it to customize)."
    else
      warn "Neither .env nor .env.example found in ${REPO_ROOT}; using built-in defaults."
    fi
  fi
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
  AUTO_TUNE="${AUTO_TUNE:-true}"
  MODEL_NAME="${MODEL_NAME:-qwen2.5-coder:7b}"
  OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
  OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
  AIDER_VERSION="${AIDER_VERSION:-}"
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  VENV_NAME="${VENV_NAME:-.venv}"
  SKIP_DOCKER="${SKIP_DOCKER:-false}"
  ENABLE_WEBUI="${ENABLE_WEBUI:-true}"
  WEBUI_PORT="${WEBUI_PORT:-3000}"
  WEBUI_CONTAINER="${WEBUI_CONTAINER:-open-webui}"
  WEBUI_ENABLE_SIGNUP="${WEBUI_ENABLE_SIGNUP:-true}"
}

# set_env_var KEY VALUE — update KEY in .env in place, or append it. The
# written line is plain KEY=VALUE, so a following load_env reads it back
# unchanged (values here never contain spaces, quotes or '|').
set_env_var() {
  local key="$1" value="$2"
  if [[ ! -f "${ENV_FILE}" ]]; then
    touch "${ENV_FILE}"
  fi
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# Python venv helpers
# ---------------------------------------------------------------------------
venv_dir() { printf '%s/%s\n' "${REPO_ROOT}" "${VENV_NAME:-.venv}"; }
venv_python() { printf '%s/bin/python\n' "$(venv_dir)"; }
aider_bin() { printf '%s/bin/aider\n' "$(venv_dir)"; }

# ---------------------------------------------------------------------------
# Ollama helpers
# ---------------------------------------------------------------------------

# ollama_url — the base URL clients should use to reach the local Ollama
# API. OLLAMA_HOST may be 0.0.0.0:PORT (a listen address); clients need a
# connectable address, so that is rewritten to 127.0.0.1.
ollama_url() {
  local host="${OLLAMA_HOST:-127.0.0.1:11434}"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%/}"
  if [[ "${host}" == 0.0.0.0:* ]]; then
    host="127.0.0.1:${host#0.0.0.0:}"
  elif [[ "${host}" == "0.0.0.0" ]]; then
    host="127.0.0.1"
  fi
  printf 'http://%s\n' "${host}"
}

# wait_for_ollama [TIMEOUT_SECONDS] — poll /api/version until it answers.
wait_for_ollama() {
  local timeout="${1:-60}" waited=0
  local url
  url="$(ollama_url)"
  while ! curl -fsS --max-time 3 "${url}/api/version" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      return 1
    fi
    sleep 2
    waited=$((waited+2))
  done
  return 0
}

# model_present MODEL — true if MODEL is already downloaded.
model_present() {
  ollama show "$1" >/dev/null 2>&1
}

# pull_model MODEL — download MODEL with progress, with a clear failure.
pull_model() {
  local model="$1"
  info "Pulling model '${model}' (this can take several minutes on first download)..."
  if ! ollama pull "${model}"; then
    err "Failed to pull '${model}'. Check your internet connection (is netmode offline? run: sudo ${REPO_ROOT}/netmode.sh status)."
    return 1
  fi
  ok "Model '${model}' is available locally."
}

# model_responds MODEL [TIMEOUT] — prove MODEL can actually generate text by
# asking the running Ollama server for a tiny real completion.
model_responds() {
  local model="$1" timeout="${2:-300}"
  local url payload response
  url="$(ollama_url)"
  payload="$(jq -n --arg model "${model}" \
    '{model: $model, prompt: "Reply with the single word: ready", stream: false, options: {num_predict: 16}}')"
  response="$(curl -fsS --max-time "${timeout}" -X POST "${url}/api/generate" \
    -H 'Content-Type: application/json' -d "${payload}" 2>/dev/null \
    | { jq -r '.response // empty' || true; })"
  [[ -n "${response}" ]]
}

# detect_ram_gib — total system RAM in GiB, rounded to the nearest GiB so a
# nominal 16 GB machine (whose kernel reports ~15.6 GiB usable) lands on 16.
detect_ram_gib() {
  awk '/^MemTotal:/ {printf "%d\n", ($2 + 524288) / 1048576}' /proc/meminfo
}

# render_ollama_dropin — (re)write the ollama systemd drop-in from the
# current .env values plus any extra KEY=VALUE lines in config/ollama.env.
# Used by install_ollama.sh at install time and tune.sh on every re-tune.
render_ollama_dropin() {
  local extra_env="${REPO_ROOT}/config/ollama.env"
  as_root mkdir -p "${OLLAMA_DROPIN_DIR}"
  {
    echo "# Managed by local-code-agent (scripts/install_ollama.sh and scripts/tune.sh)."
    echo "# Manual edits will be overwritten on the next install or tune run."
    echo "[Service]"
    echo "Environment=OLLAMA_HOST=${OLLAMA_HOST}"
    echo "Environment=OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
    echo "Environment=OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
    if [[ -f "${extra_env}" ]]; then
      { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${extra_env}" || true; } \
        | sed 's/^/Environment=/'
    fi
  } | as_root tee "${OLLAMA_DROPIN}" >/dev/null
  ok "Wrote ${OLLAMA_DROPIN}"
}

# restart_ollama — reload systemd and restart the ollama service, then wait
# for the API to come back. Warns (does not crash) where systemd is absent.
restart_ollama() {
  if systemd_available; then
    as_root systemctl daemon-reload
    as_root systemctl restart ollama
    if wait_for_ollama 90; then
      ok "Ollama restarted and answering at $(ollama_url)"
    else
      die "Ollama did not answer after restart. Inspect it with: sudo systemctl status ollama"
    fi
  else
    warn "systemd not available — restart Ollama manually for new settings to apply (e.g. 'ollama serve')."
  fi
}

# netmode_state — current persisted netmode ('online' when never toggled).
netmode_state() {
  if [[ -f "${NETMODE_STATE_FILE}" ]]; then
    cat "${NETMODE_STATE_FILE}"
  else
    echo "online"
  fi
}

# net_guard WHAT — die early with a helpful message when the netmode kill
# switch is engaged, instead of letting downloads time out confusingly.
net_guard() {
  local what="${1:-This step}"
  if [[ "$(netmode_state)" == "offline" ]]; then
    die "${what} needs internet access, but netmode is OFFLINE. Run: sudo ${REPO_ROOT}/netmode.sh online — then retry."
  fi
}

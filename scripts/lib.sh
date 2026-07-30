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

# Debian gives non-root users a PATH without /usr/sbin and /sbin, where nft
# (and other admin tools this project relies on) live; Ubuntu includes them.
# Add them so have()/require_cmd() and as_root find those tools on every
# supported distro, for root and non-root callers alike.
case ":${PATH}:" in
  *:/usr/sbin:*) ;;
  *) PATH="${PATH}:/usr/sbin:/sbin" ;;
esac
export PATH

# Some non-login contexts run with $HOME unset — notably cloud-init user-data
# (how deploy/do-user-data.sh invokes setup.sh on a fresh droplet) and root
# systemd oneshots (the on-boot tune service). The ollama CLI PANICS with
# "$HOME is not defined" when it is unset, so every pull/show/generate would
# crash. Set HOME to the invoking user's home (root's /root under cloud-init
# and the boot services) so ollama always initializes.
if [[ -z "${HOME:-}" ]]; then
  HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "${HOME}" ]] || HOME=/root
  export HOME
fi

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

# can_root — true if we could obtain root (already root, or sudo is present).
# Unlike as_root this never exits, so callers that must keep running even
# without a way to escalate (check-system.sh) can degrade gracefully instead
# of dying silently inside a redirected probe.
can_root() {
  [[ "${EUID}" -eq 0 ]] || have sudo
}

# apt_get ARGS... — apt-get as root, non-interactive, and tolerant of the
# dpkg lock that apt-daily / unattended-upgrades routinely hold during the
# first minutes of a fresh boot (waits up to 10 min instead of failing hard).
# Every apt-get call in the project goes through this so an unattended
# cloud-init install never aborts on a transient lock. (DPkg::Lock::Timeout
# is supported on apt >= 1.9.11, i.e. Ubuntu 20.04+ / Debian 11+.)
apt_get() {
  as_root env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=600 "$@"
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
      # Notice goes to stderr: load_env may run inside commands whose stdout
      # is data (a message on stdout would corrupt it).
      info "Created ${ENV_FILE} from .env.example (edit it to customize)." >&2
    else
      warn "Neither .env nor .env.example found in ${REPO_ROOT}; using built-in defaults."
    fi
  fi
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # Strip CR first so a CRLF (Windows-edited) .env never leaves a trailing
    # '\r' in values — which would break numeric checks, ports and URLs.
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "${ENV_FILE}")
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
# API. OLLAMA_HOST may be a listen address (0.0.0.0[:PORT]); clients need a
# connectable address, so 0.0.0.0 is rewritten to 127.0.0.1, and a missing
# port is filled with Ollama's default 11434 (ollama itself defaults the
# port, so a port-less OLLAMA_HOST is valid and must not become port 80).
ollama_url() {
  local host="${OLLAMA_HOST:-127.0.0.1:11434}"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%/}"
  host="${host/#0.0.0.0/127.0.0.1}"
  [[ "${host}" == *:* ]] || host="${host}:11434"
  printf 'http://%s\n' "${host}"
}

# ollama_bind_is_public — true when OLLAMA_HOST binds beyond loopback. The
# Ollama API is unauthenticated, so a non-loopback bind exposes it to anyone
# who can reach the host; callers warn loudly rather than fail open silently.
ollama_bind_is_public() {
  local host="${OLLAMA_HOST:-127.0.0.1:11434}"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%/}"
  # IPv6 wildcard / loopback forms first — a greedy ':' strip would collapse
  # '::' or '[::]:port' to empty and misread an all-interfaces bind as safe.
  case "${host}" in
    "::"|"[::]"|"[::]:"*|"0:0:0:0:0:0:0:0"*) return 0 ;;  # IPv6 any -> public
    "[::1]"|"[::1]:"*|"::1") return 1 ;;                   # IPv6 loopback
  esac
  host="${host%%:*}"
  case "${host}" in
    127.0.0.1|localhost|"") return 1 ;;
    *) return 0 ;;
  esac
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

# has_nvidia_gpu — true if an NVIDIA GPU Ollama can use is present. Ollama
# uses a supported GPU automatically (no config needed); this is only for
# reporting/observability, so CPU-only stays the fully-supported default.
has_nvidia_gpu() {
  have nvidia-smi && nvidia-smi -L >/dev/null 2>&1
}

# render_ollama_dropin_content — print the drop-in the current .env implies,
# to stdout (no writes). Kept separate so callers can diff it against the
# installed file to detect drift.
render_ollama_dropin_content() {
  local extra_env="${REPO_ROOT}/config/ollama.env"
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
}

# render_ollama_dropin — (re)write the ollama systemd drop-in from the
# current .env values plus any extra KEY=VALUE lines in config/ollama.env.
# Used by install_ollama.sh at install time and tune.sh on every re-tune.
render_ollama_dropin() {
  as_root mkdir -p "${OLLAMA_DROPIN_DIR}"
  render_ollama_dropin_content | as_root tee "${OLLAMA_DROPIN}" >/dev/null
  ok "Wrote ${OLLAMA_DROPIN}"
}

# ollama_dropin_matches — true if the installed drop-in already equals what
# the current .env would render. A mismatch means an earlier tune wrote .env
# but was interrupted before re-rendering/restarting (config drift).
ollama_dropin_matches() {
  [[ -f "${OLLAMA_DROPIN}" ]] || return 1
  diff -q <(render_ollama_dropin_content) "${OLLAMA_DROPIN}" >/dev/null 2>&1
}

# restart_ollama — reload systemd and restart the ollama service, then wait
# for the API to come back. Warns (does not crash) where systemd is absent.
restart_ollama() {
  if systemd_available; then
    as_root systemctl daemon-reload
    as_root systemctl restart ollama
    if wait_for_ollama 90; then
      # The API answering is not proof OUR service is healthy: a stray
      # 'ollama serve' holding the port answers too while the unit crash-loops
      # on the bind error, silently discarding the drop-in we just rendered.
      if ! systemctl is-active --quiet ollama 2>/dev/null; then
        die "The Ollama API answers but the ollama systemd service is not active — another process may hold port 11434. See docs/TROUBLESHOOTING.md (Port 11434 already in use)."
      fi
      ok "Ollama restarted and answering at $(ollama_url)"
    else
      die "Ollama did not answer after restart. Inspect it with: sudo systemctl status ollama"
    fi
  else
    warn "systemd not available — restart Ollama manually for new settings to apply (e.g. 'ollama serve')."
  fi
}

# webui_url — loopback URL for the local Open WebUI.
webui_url() { printf 'http://127.0.0.1:%s\n' "${WEBUI_PORT:-3000}"; }

# webui_responds — true only if Open WebUI's own /health endpoint answers.
# Probing /health (not '/') means another service squatting the port cannot
# masquerade as a healthy WebUI.
webui_responds() {
  curl -fsS --max-time 3 "$(webui_url)/health" >/dev/null 2>&1
}

# wait_for_webui [TIMEOUT_SECONDS] — poll Open WebUI's /health until it
# answers. A cold container start takes noticeably longer than 'docker
# start' returning, so start/restart/install all wait through this.
wait_for_webui() {
  local timeout="${1:-120}" waited=0
  while ! webui_responds; do
    if (( waited >= timeout )); then
      return 1
    fi
    sleep 3
    waited=$((waited+3))
  done
  return 0
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

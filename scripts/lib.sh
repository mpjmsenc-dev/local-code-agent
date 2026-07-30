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
  MODEL_FAMILY="${MODEL_FAMILY:-qwen2.5-coder}"
  OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
  OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
  AIDER_VERSION="${AIDER_VERSION:-}"
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  VENV_NAME="${VENV_NAME:-.venv}"
  AIDER_CONVENTIONS="${AIDER_CONVENTIONS:-true}"
  LCA_EDIT_FORMAT="${LCA_EDIT_FORMAT:-auto}"
  LCA_ASK_TOKENS="${LCA_ASK_TOKENS:-512}"
  SKIP_DOCKER="${SKIP_DOCKER:-false}"
  ENABLE_WEBUI="${ENABLE_WEBUI:-true}"
  WEBUI_PORT="${WEBUI_PORT:-3000}"
  WEBUI_CONTAINER="${WEBUI_CONTAINER:-open-webui}"
  WEBUI_NAME="${WEBUI_NAME:-local-code-agent}"
  WEBUI_ENABLE_SIGNUP="${WEBUI_ENABLE_SIGNUP:-true}"
  BACKUP_KEEP="${BACKUP_KEEP:-7}"
  BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-*-*-* 03:30:00}"
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

# aider_token_budget CTX — echo "INPUT OUTPUT" (two integers) splitting an
# Ollama context window of CTX tokens into a prompt budget and a reply budget.
# Ollama's num_ctx is the WHOLE window (prompt + generation share it), so we
# reserve a quarter of it (at least 1024 tokens) for the model's reply and give
# the rest to the prompt. run-agent.sh feeds these to aider via a model-metadata
# file so aider packs the repo map / history / files to what Ollama will
# actually process — otherwise aider trusts litellm's generic metadata (e.g.
# 32k for qwen2.5-coder) while the server is capped at OLLAMA_CONTEXT_LENGTH,
# and every over-limit prompt is SILENTLY truncated by Ollama (the system
# prompt drops off and the model "forgets" its instructions). Bad/empty CTX
# falls back to 8192 so a corrupt .env can never yield a zero budget.
aider_token_budget() {
  local ctx="${1:-8192}" out
  if ! [[ "${ctx}" =~ ^[0-9]+$ ]] || (( ctx < 256 )); then ctx=8192; fi
  out=$(( ctx / 4 ))
  if (( out < 1024 )); then out=1024; fi
  if (( out >= ctx )); then out=$(( ctx / 2 )); fi
  printf '%s %s\n' "$(( ctx - out ))" "${out}"
}

# aider_edit_format MODEL — how aider should ask MODEL to express edits.
# Small models routinely emit malformed search/replace blocks, and every
# malformed block is a wasted round trip on a machine doing a few tokens a
# second. Rewriting the whole file ("whole") is far more reliable for them, at
# the cost of tokens. From roughly 7B upward the "diff" format works well and is
# much cheaper, which matters when the context window is only 4-16k.
# Unknown/odd tags fall back to "diff" (aider's own default behaviour).
aider_edit_format() {
  local model="${1:-}" size num
  size="${model##*:}"          # qwen2.5-coder:7b -> 7b
  num="${size%[bB]}"
  if [[ "${num}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Decimal tags exist (0.5b), so compare as a float.
    if awk -v n="${num}" 'BEGIN{exit !(n <= 4)}'; then
      printf 'whole\n'
      return 0
    fi
  fi
  printf 'diff\n'
}

# aider_map_tokens CTX — repo-map budget for a context window of CTX tokens.
# aider's default (1024) is a third of the usable prompt on a 4096 window, which
# crowds out the code being edited. Scale it with the window instead, clamped so
# it stays useful but never dominates.
aider_map_tokens() {
  local ctx="${1:-8192}" in out map
  read -r in out <<<"$(aider_token_budget "${ctx}")"
  : "${out}"                   # out is unused here; budget returns both
  map=$(( in / 8 ))
  if (( map < 256 )); then map=256; fi
  if (( map > 4096 )); then map=4096; fi
  printf '%s\n' "${map}"
}

# backups_to_prune KEEP — read backup file paths on stdin (one per line) and
# print the ones that should be DELETED to retain only the newest KEEP. Backup
# filenames embed a sortable YYYYMMDD-HHMMSS stamp, so lexical order equals
# chronological order; we sort and print all but the last KEEP. KEEP that is
# empty, zero, or non-numeric prints nothing — retention disabled means keep
# everything, so a bad value can never delete a backup. Pure (stdin->stdout),
# so backup.sh's retention is unit-tested without ever touching the disk.
backups_to_prune() {
  local keep="${1:-}"
  [[ "${keep}" =~ ^[0-9]+$ ]] || return 0
  (( keep > 0 )) || return 0
  sort | awk -v k="${keep}" '{a[NR]=$0} END{for (i = 1; i <= NR - k; i++) print a[i]}'
}

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
  # A bare ':PORT' (empty host part) binds ALL interfaces, exactly like
  # 0.0.0.0 — Ollama's own default when the host is omitted. The '%%:*' strip
  # below would leave an empty string, which the "" case then misread as
  # loopback-private, so a publicly-bound unauthenticated API looked safe.
  case "${host}" in
    :*) return 0 ;;
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

# detect_ram_gib — usable RAM in GiB, rounded to the nearest GiB (a nominal
# 16 GB machine reports ~15.6 GiB usable and lands on 16). Inside a
# memory-limited container /proc/meminfo shows the HOST's RAM, which would
# make auto-tune pick a model that OOMs; so prefer a smaller cgroup limit.
detect_ram_gib() {
  local mem_kb mem_bytes cg=""
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  mem_bytes=$(( mem_kb * 1024 ))
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    cg="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"                    # cgroup v2
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    cg="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"  # cgroup v1
  fi
  # Use the cgroup limit only when it is a real, smaller-than-host value
  # ("max" or an unlimited sentinel is ignored).
  if [[ "${cg}" =~ ^[0-9]+$ ]] && (( cg > 0 )) && (( cg < mem_bytes )); then
    mem_bytes="${cg}"
  fi
  awk -v b="${mem_bytes}" 'BEGIN { printf "%d\n", (b + 536870912) / 1073741824 }'
}

# has_nvidia_gpu — true if an NVIDIA GPU Ollama can use is present. Ollama
# uses a supported GPU automatically (no config needed); this is only for
# reporting/observability, so CPU-only stays the fully-supported default.
has_nvidia_gpu() {
  have nvidia-smi && nvidia-smi -L >/dev/null 2>&1
}

# gpu_hardware_present — an NVIDIA card is physically present, whether or not a
# driver is installed. The difference matters: with the card but no driver the
# user gets slow CPU inference and no explanation, and "no GPU detected" would
# be actively misleading.
gpu_hardware_present() {
  have lspci || return 1
  lspci 2>/dev/null | grep -qi 'nvidia'
}

# vram_mib_from_smi — read `nvidia-smi --query-gpu=memory.total ...` output on
# stdin and echo the LARGEST card's VRAM in MiB. Largest, not first: with a
# display adapter alongside a compute card, the first line can be the small one
# and every recommendation built on it would be wrong.
vram_mib_from_smi() {
  local best=0 line
  while read -r line; do
    line="${line//[^0-9]/}"
    [[ -n "${line}" ]] || continue
    (( line > best )) && best="${line}"
  done
  (( best > 0 )) || return 1
  printf '%s\n' "${best}"
}

# gpu_vram_mib — VRAM of the largest NVIDIA card, or nonzero when it cannot be
# determined (no driver, no card).
gpu_vram_mib() {
  have nvidia-smi || return 1
  nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | vram_mib_from_smi
}

# classify_gpu HAS_CARD HAS_DRIVER PLACEMENT — pure classifier for the GPU
# situation, echoing one of:
#   none        no NVIDIA card in the machine
#   no-driver   card present but no driver — the silent case, where everything
#               works and is simply 10x slower with no explanation given
#   idle        driver works, but the model is running on the CPU anyway
#               (usually too little VRAM, or Ollama needs the container toolkit)
#   split       partially offloaded — runs at close to CPU speed, the trap
#   active      fully on the GPU, which is the point
#   unknown     the model is not resident, so placement cannot be read
# Kept pure so every branch is unit-testable on a machine with no GPU at all.
classify_gpu() {
  local has_card="$1" has_driver="$2" placement="$3"
  if [[ "${has_card}" != "true" && "${has_driver}" != "true" ]]; then
    printf 'none\n'; return 0
  fi
  if [[ "${has_driver}" != "true" ]]; then
    printf 'no-driver\n'; return 0
  fi
  case "${placement}" in
    "")        printf 'unknown\n' ;;
    *"/"*)     printf 'split\n' ;;
    *GPU*)     printf 'active\n' ;;
    *)         printf 'idle\n' ;;
  esac
}

# gpu_state — classify_gpu against this machine.
gpu_state() {
  local card=false driver=false
  gpu_hardware_present && card=true
  have nvidia-smi && nvidia-smi -L >/dev/null 2>&1 && driver=true
  classify_gpu "${card}" "${driver}" "$(ollama_processor "${1:-${MODEL_NAME:-}}" 2>/dev/null || true)"
}

# largest_model_for_vram VRAM_MIB — the biggest parameter count that fits
# entirely in VRAM at q4 (~0.6 GB per billion, plus ~1.5 GB for context and
# CUDA overhead). Fitting COMPLETELY is the point: a model that spills is not
# "most of the speed", it runs at close to CPU speed.
largest_model_for_vram() {
  local mib="$1"
  [[ "${mib}" =~ ^[0-9]+$ ]] || return 1
  awk -v m="${mib}" 'BEGIN { p = (m / 1024 - 1.5) / 0.6; if (p < 1) exit 1; printf "%d\n", p }'
}

# processor_from_ps MODEL — read `ollama ps` output on stdin and echo how MODEL
# is actually running: "100% GPU", "100% CPU", or a split like "38%/62% CPU/GPU".
# This is the only authoritative answer to "is my GPU being used?" — a driver
# can be installed and Ollama still fall back to CPU (too little VRAM for the
# model, or a runner mismatch). Parsed by pattern, not column index: the
# PROCESSOR field itself contains a space, so $4 would only ever capture "100%".
processor_from_ps() {
  local model="$1" line
  line="$(grep -F -- "${model}" || true)"
  [[ -n "${line}" ]] || return 1
  local proc
  proc="$(grep -oE '[0-9]+%/[0-9]+% [A-Z]+/[A-Z]+|[0-9]+% (GPU|CPU)' <<<"${line}" | head -1)"
  [[ -n "${proc}" ]] || return 1
  printf '%s\n' "${proc}"
}

# ollama_processor MODEL — processor_from_ps against the live server. Empty when
# the model is not currently loaded (nothing has used it recently).
ollama_processor() {
  have ollama || return 1
  ollama ps 2>/dev/null | processor_from_ps "$1"
}

# model_params_b MODEL — billions of parameters implied by an Ollama tag
# ('qwen2.5-coder:14b' -> 14). Returns nonzero when the tag carries no size, so
# callers can fall back rather than silently compute from a wrong number.
model_params_b() {
  local tag="${1##*:}" n
  n="$(grep -oiE '^[0-9]+(\.[0-9]+)?b$' <<<"${tag}" || true)"
  [[ -n "${n}" ]] || return 1
  n="${n%[bB]}"
  # Round to a whole number; sizes like 1.5b exist and integer maths is enough
  # for the bandwidth estimate this feeds.
  awk -v v="${n}" 'BEGIN { printf "%.0f\n", (v < 1 ? 1 : v) }'
}

# tokens_per_second COUNT DURATION_NS — throughput to one decimal place.
# Ollama reports both counters per request, which is far more accurate than
# wall-clock timing: it excludes model load time and connection overhead.
tokens_per_second() {
  local count="$1" ns="$2"
  [[ "${count}" =~ ^[0-9]+$ && "${ns}" =~ ^[0-9]+$ ]] || return 1
  (( ns > 0 )) || return 1
  awk -v c="${count}" -v n="${ns}" 'BEGIN { printf "%.1f\n", c / (n / 1000000000) }'
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

# start_ollama_bg — start `ollama serve` detached, for hosts WITHOUT systemd
# (containers, WSL), with the same environment the systemd drop-in would
# apply. Not boot-persistent — that's the honest cost of having no service
# manager. No-op if the API already answers.
start_ollama_bg() {
  wait_for_ollama 2 && return 0
  have ollama || return 1
  local logf="${REPO_ROOT}/.ollama-serve.log"   # *.log is gitignored
  warn "systemd not available — starting 'ollama serve' in the background (NOT persistent across reboots; use a systemd host for a managed service)."
  OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}" \
  OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}" \
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}" \
  OLLAMA_MAX_LOADED_MODELS=1 \
    nohup ollama serve >"${logf}" 2>&1 &
  wait_for_ollama 30
}

# ensure_ollama_up [TIMEOUT] — guarantee the API is reachable: return 0 if
# already up, else start it (systemd service, or a detached serve on hosts
# without systemd) and wait. Nonzero if it cannot be brought up.
ensure_ollama_up() {
  local timeout="${1:-60}"
  wait_for_ollama 3 && return 0
  have ollama || return 1
  if systemd_available; then
    # Never call as_root unguarded here: with neither root nor sudo it die()s,
    # and that exit kills the CALLER mid-run — '|| true' cannot catch an exit,
    # and the redirect below would swallow the explanation. can_root() returns
    # false instead, so callers (selftest.sh, tune.sh) degrade gracefully.
    if can_root; then
      as_root systemctl start ollama >/dev/null 2>&1 || true
    fi
    wait_for_ollama "${timeout}"
  else
    start_ollama_bg
  fi
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

# ---------------------------------------------------------------------------
# The assistant's voice
# ---------------------------------------------------------------------------

# lca_system_prompt — the system prompt shared by the phone chat and 'lca ask'.
#
# One source of truth on purpose: an answer should not depend on which door you
# came in through. Out of the box Open WebUI sends no system prompt at all, and
# a small local coder model with no instructions tends to answer a plain
# question with a wall of code.
#
# The 'lca' commands listed below are checked against bin/lca by the test
# suite, so this can never quietly start advertising a command that does not
# exist — the one hallucination we can actually prevent.
lca_system_prompt() {
  cat <<'EOF'
You are the assistant for local-code-agent, a private AI stack running entirely
on the user's own Linux server. Nothing the user types leaves that machine.

Lead with the answer, not a preamble. Prefer concrete commands and short,
complete code over long explanations, and put code in fenced blocks with a
language tag. Be brief unless asked to go deeper: replies are often read on a
phone and are generated at a few tokens per second, so length has a real cost.

If you are unsure, say so. Never invent command-line flags, file paths or API
names — a confidently wrong flag costs the user more than "I don't know".

The server manages itself through one command, 'lca':
  lca            start the coding agent (aider) in the current directory
  lca ask "..."  one-shot question in the terminal
  lca check      full health check
  lca logs       recent logs from Ollama, the chat app and the installer
  lca speed      measure tokens/second and what limits it
  lca test       live end-to-end self-test
  lca update     update and re-verify the stack
  lca backup     take a backup now
  lca model      switch the local model
  lca offline    cut internet access (the AI keeps working); lca online undoes it
  lca status     kill-switch status
Only mention these when they are actually relevant to the question.
EOF
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

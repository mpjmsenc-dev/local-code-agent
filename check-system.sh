#!/usr/bin/env bash
# check-system.sh — health check for the whole stack. Runs every check even
# when earlier ones fail, prints a colored summary, and exits 1 only if at
# least one hard FAIL occurred (warnings alone keep exit 0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

# From here on, keep going no matter what individual probes return.
set +e

PASS=0
WARN=0
FAIL=0

p_pass() { ok "$*";   PASS=$((PASS+1)); }
p_warn() { warn "$*"; WARN=$((WARN+1)); }
p_fail() { err "$*";  FAIL=$((FAIL+1)); }

# --- Binaries ---------------------------------------------------------------
step "Binaries"
for bin in git curl jq python3 ollama nft; do
  if have "${bin}"; then
    p_pass "binary: ${bin}"
  else
    p_fail "binary missing: ${bin} (run ./setup.sh)"
  fi
done

# --- Docker -----------------------------------------------------------------
step "Docker"
if [[ "${SKIP_DOCKER}" == "true" ]]; then
  info "SKIP_DOCKER=true — docker checks skipped."
else
  if have docker; then
    p_pass "docker client installed"
    # Never call as_root directly here: without root or sudo it die()s, and
    # that exit would kill the whole health check mid-run even under set +e.
    # can_root() returns false instead, so we degrade to a warning.
    if docker info >/dev/null 2>&1 || { can_root && as_root docker info >/dev/null 2>&1; }; then
      p_pass "docker daemon responding"
    elif ! can_root; then
      p_warn "cannot query the docker daemon as a non-root user without sudo — re-run as root to check it"
    else
      p_fail "docker daemon not responding (sudo systemctl start docker)"
    fi
    check_user="${SUDO_USER:-$(id -un)}"
    if [[ "${check_user}" == "root" ]]; then
      info "running as root — docker group membership not needed."
    elif id -nG "${check_user}" 2>/dev/null | grep -qw docker; then
      p_pass "user '${check_user}' is in the docker group"
    else
      p_warn "user '${check_user}' not in the docker group (log out/in after setup, or re-run scripts/install_docker.sh)"
    fi
  else
    p_fail "docker not installed (run scripts/install_docker.sh, or set SKIP_DOCKER=true)"
  fi
fi

# --- Python + aider ---------------------------------------------------------
step "Python + aider"
if have python3 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  p_pass "python3 >= 3.10 ($(python3 --version 2>&1))"
else
  p_fail "python3 >= 3.10 not available"
fi
VENV_PATH="$(venv_dir)"
AIDER="$(aider_bin)"
if [[ -x "${VENV_PATH}/bin/python" ]]; then
  p_pass "virtualenv exists at ${VENV_PATH}"
else
  p_fail "virtualenv missing at ${VENV_PATH} (run scripts/install_python.sh)"
fi
if [[ -x "${AIDER}" ]]; then
  aider_version="$("${AIDER}" --version 2>/dev/null)"
  if [[ -n "${aider_version}" ]]; then
    p_pass "aider works: ${aider_version}"
  else
    p_fail "aider binary exists but --version failed (re-run scripts/install_python.sh)"
  fi
else
  p_fail "aider not installed in the venv (run scripts/install_python.sh)"
fi

# --- Ollama service + API ---------------------------------------------------
step "Ollama"
if systemd_available; then
  if systemctl is-active --quiet ollama 2>/dev/null; then
    p_pass "ollama systemd service active"
  else
    p_fail "ollama systemd service not active (sudo systemctl start ollama)"
  fi
else
  p_warn "systemd not available — cannot check the ollama service state"
fi
OLLAMA_API_UP=false
ollama_version="$(curl -fsS --max-time 5 "$(ollama_url)/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
if [[ -n "${ollama_version}" ]]; then
  p_pass "ollama API answering at $(ollama_url) (v${ollama_version})"
  OLLAMA_API_UP=true
else
  p_fail "ollama API not answering at $(ollama_url)"
fi
# The Ollama API is unauthenticated — a non-loopback bind is a real exposure
# that the loopback health probe above would otherwise hide.
if ollama_bind_is_public; then
  p_warn "OLLAMA_HOST=${OLLAMA_HOST} binds Ollama beyond loopback — the unauthenticated API may be reachable off-box. Set OLLAMA_HOST=127.0.0.1:11434 in .env unless you intend this."
fi
# The drop-in is the ONLY thing that applies OLLAMA_HOST, OLLAMA_CONTEXT_LENGTH
# and OLLAMA_KEEP_ALIVE to the running service. Editing .env changes nothing on
# its own — and .env.example openly invites editing OLLAMA_KEEP_ALIVE ("set
# this to -1 to keep the model resident"). Saying nothing here means a user
# follows our own documentation, gets no effect, and has nowhere to find out.
if systemd_available && have ollama; then
  if [[ ! -f "${OLLAMA_DROPIN}" ]]; then
    p_warn "no ollama drop-in at ${OLLAMA_DROPIN} — Ollama is running on its own defaults, not your .env. Fix: sudo ${SCRIPT_DIR}/scripts/install_ollama.sh"
  elif ollama_dropin_matches; then
    p_pass "your ollama settings are applied (context ${OLLAMA_CONTEXT_LENGTH}, keep-alive ${OLLAMA_KEEP_ALIVE})"
  else
    p_warn "config drift: your .env differs from what Ollama is actually running — edits to OLLAMA_HOST / OLLAMA_CONTEXT_LENGTH / OLLAMA_KEEP_ALIVE are NOT in effect. Fix: sudo lca apply"
  fi
fi

# --- Model ------------------------------------------------------------------
step "Model (${MODEL_NAME})"
if have ollama && [[ "${OLLAMA_API_UP}" == "true" ]]; then
  if model_present "${MODEL_NAME}"; then
    p_pass "model '${MODEL_NAME}' is downloaded"
    info "asking '${MODEL_NAME}' for a real generation (may take a minute on first load)..."
    if model_responds "${MODEL_NAME}" 240; then
      p_pass "model '${MODEL_NAME}' responds to a real generation"
    else
      p_fail "model '${MODEL_NAME}' did not respond (RAM? see: free -h and journalctl -u ollama)"
    fi
  elif [[ "$(netmode_state)" == "offline" ]]; then
    p_fail "model '${MODEL_NAME}' not downloaded, and netmode is OFFLINE — run 'sudo ./netmode.sh online' then 'ollama pull ${MODEL_NAME}'"
  else
    p_fail "model '${MODEL_NAME}' not downloaded (ollama pull ${MODEL_NAME})"
  fi
else
  p_fail "cannot check the model — ollama binary or API unavailable"
fi

# --- Auto-tune drift --------------------------------------------------------
step "Auto-tune"
RAM_GIB="$(detect_ram_gib)"
# Use tune.sh's OWN ladder rather than a second copy of it. The copy that used
# to live here had already drifted: it hardcoded the qwen2.5-coder family, so
# anyone who set MODEL_FAMILY=qwen3 and ran tune.sh saw this warn about "drift"
# from qwen2.5-coder on every single check — telling them to run the very
# script that had just chosen correctly. A duplicated ladder cannot help but
# rot; sourcing the real one means the two can never disagree again.
# tune.sh recomputes SCRIPT_DIR from its OWN location, so sourcing it silently
# repoints ours at scripts/. Nothing below needs it today, but a variable left
# pointing somewhere unexpected is a trap for whoever edits this next.
# (REPO_ROOT is safe — lib.sh's double-source guard stops it being recomputed.)
CHECK_DIR="${SCRIPT_DIR}"
# shellcheck source=scripts/tune.sh
source "${SCRIPT_DIR}/scripts/tune.sh"
SCRIPT_DIR="${CHECK_DIR}"
unset CHECK_DIR
TUNE_FAMILY="$(model_family)"
read -r TUNE_SMALL TUNE_MID TUNE_BIG <<<"$(family_sizes "${TUNE_FAMILY}")"
if   (( RAM_GIB < 9 ));   then TUNE_MODEL="${TUNE_FAMILY}:${TUNE_SMALL}"
elif (( RAM_GIB <= 15 )); then TUNE_MODEL="${TUNE_FAMILY}:${TUNE_MID}"
else                           TUNE_MODEL="${TUNE_FAMILY}:${TUNE_BIG}"
fi
info "RAM ladder: ${RAM_GIB} GiB detected → recommended model ${TUNE_MODEL}"
if [[ "${AUTO_TUNE}" != "true" ]]; then
  info "AUTO_TUNE=false — model manually pinned to ${MODEL_NAME}; drift check skipped."
elif [[ "${MODEL_NAME}" == "${TUNE_MODEL}" ]]; then
  p_pass "configured model matches the tune recommendation"
else
  p_warn "configured model (${MODEL_NAME}) differs from the recommendation (${TUNE_MODEL}) — run scripts/tune.sh"
fi
# AUTO_TUNE only actually adapts to a resized VM if the boot unit runs it.
# Without this, "resize the droplet and the model follows" is a promise with
# nothing behind it, and the failure is silent — everything keeps working, at
# the old model, forever.
if [[ "${AUTO_TUNE}" == "true" ]] && systemd_available; then
  if systemctl is-enabled --quiet local-code-agent-tune.service 2>/dev/null; then
    p_pass "auto-tune will re-run on boot (local-code-agent-tune.service enabled)"
  else
    p_warn "AUTO_TUNE=true but local-code-agent-tune.service is not enabled — resizing this VM will NOT change the model on reboot. Fix: sudo ./setup.sh (or: sudo systemctl enable local-code-agent-tune.service)"
  fi
fi
# The login banner is the first thing anyone sees on this box, so a broken one
# misinforms every single SSH. Only a warning: a machine without update-motd
# works exactly as well, it just greets you with less.
if [[ -d "$(dirname "${MOTD_FILE}")" ]]; then
  if [[ -x "${MOTD_FILE}" || -L "${MOTD_FILE}" ]]; then
    # Executed, not merely counted: the first version of this passed happily
    # while the banner was printing "lib.sh: No such file or directory" at
    # every login, because run-parts runs the symlink and SCRIPT_DIR then
    # resolved to /etc/update-motd.d.
    if "${MOTD_FILE}" >/dev/null 2>&1; then
      p_pass "login banner installed (${MOTD_FILE}) — SSH reports whether the stack is ready"
    else
      p_warn "the login banner at ${MOTD_FILE} exits with an error — every SSH login shows that error instead of the status. Fix: sudo ${SCRIPT_DIR}/scripts/motd.sh --install"
    fi
  else
    p_warn "no login banner at ${MOTD_FILE} — SSHing in will not tell you whether the stack is ready. Fix: sudo ${SCRIPT_DIR}/scripts/motd.sh --install"
  fi
fi

# --- Open WebUI -------------------------------------------------------------
step "Open WebUI"
if [[ "${ENABLE_WEBUI}" != "true" ]]; then
  info "ENABLE_WEBUI=false — WebUI checks skipped."
elif [[ "${SKIP_DOCKER}" == "true" ]]; then
  info "SKIP_DOCKER=true — WebUI checks skipped."
elif ! have docker; then
  p_fail "WebUI enabled but docker is missing"
elif ! can_root && ! docker info >/dev/null 2>&1; then
  p_warn "cannot inspect the WebUI container as a non-root user without sudo — re-run as root to check it"
else
  webui_status="$(docker inspect -f '{{.State.Status}}' "${WEBUI_CONTAINER}" 2>/dev/null \
    || { can_root && as_root docker inspect -f '{{.State.Status}}' "${WEBUI_CONTAINER}" 2>/dev/null; } || true)"
  case "${webui_status}" in
    running)    p_pass "container '${WEBUI_CONTAINER}' is running" ;;
    restarting) p_fail "container '${WEBUI_CONTAINER}' is CRASH-LOOPING (restarting) — often port ${WEBUI_PORT} taken or a bad .env; see: ./webui.sh logs" ;;
    "")         p_fail "container '${WEBUI_CONTAINER}' does not exist (./webui.sh start)" ;;
    *)          p_fail "container '${WEBUI_CONTAINER}' is '${webui_status}', not running (./webui.sh start)" ;;
  esac
  # Probe /health (Open WebUI-specific) so a different service squatting the
  # port cannot masquerade as a healthy WebUI.
  if webui_responds; then
    p_pass "Open WebUI /health answering on port ${WEBUI_PORT}"
  else
    p_fail "Open WebUI /health not answering on port ${WEBUI_PORT} (./webui.sh logs)"
  fi
  # Open signups are the one setting where the documented happy path ends with
  # a manual step the user has to remember (YOUR-TURN.md step 4.3). Forget it
  # and anyone who reaches the app can register an account on the private AI
  # this whole project exists to keep private. Nothing said so until now.
  if [[ "${WEBUI_ENABLE_SIGNUP}" == "true" ]]; then
    p_warn "signups are OPEN (WEBUI_ENABLE_SIGNUP=true) — anyone who can reach the chat app can create an account. Once you have made yours: set WEBUI_ENABLE_SIGNUP=false in .env and re-run scripts/install_webui.sh"
  else
    p_pass "signups are closed (WEBUI_ENABLE_SIGNUP=false)"
  fi
fi

# --- Tailscale (warn-only) --------------------------------------------------
step "Tailscale"
if have tailscale; then
  if tailscale status >/dev/null 2>&1; then
    p_pass "tailscale is logged in (IPv4: $(tailscale ip -4 2>/dev/null | head -1))"
  else
    p_warn "tailscale installed but not logged in — run: sudo tailscale up"
  fi
elif [[ "${SKIP_TAILSCALE}" == "true" ]]; then
  # Deliberately absent is not a problem. Warning here would nag forever on a
  # healthy machine and point at an installer the user opted out of — the same
  # unfixable-warning trap the auto-tune ladder had.
  info "tailscale skipped by configuration (SKIP_TAILSCALE=true) — phone access is via your own private network."
else
  p_warn "tailscale not installed (run scripts/install_tailscale.sh for phone access)"
fi

# --- Inbound guard ----------------------------------------------------------
step "Inbound guard"
if [[ "${ENABLE_WEBUI}" != "true" ]] && ! ollama_bind_is_public; then
  info "WebUI disabled and Ollama on loopback — no public service ports to guard."
elif ! have nft; then
  p_warn "nft not installed — the inbound guard is not enforced (WebUI/Ollama ports may be publicly reachable)"
elif ! can_root; then
  p_warn "cannot inspect nftables without root/sudo — re-run as root to verify the inbound guard"
elif ! as_root nft list table inet lca_inbound >/dev/null 2>&1; then
  p_fail "inbound guard NOT loaded — WebUI/Ollama ports may be publicly reachable (sudo ./netmode.sh harden)"
else
  # Existence is not enough: confirm the port the WebUI actually binds is in
  # the drop set. A config change without a re-harden, or a parser mismatch,
  # would otherwise show green while the real port stays exposed.
  INBOUND_DUMP="$(as_root nft list table inet lca_inbound 2>/dev/null)"
  # Check the OLLAMA port too, not just the WebUI one. The Ollama API is
  # unauthenticated, and changing OLLAMA_HOST (documented in
  # docs/TROUBLESHOOTING.md) leaves the guard baked with the OLD port — so the
  # asymmetric check used to print a green "covers the configured port(s)"
  # while a public Ollama bind was live. Name the ports so the claim can be
  # checked by eye instead of taken on trust.
  OLLAMA_GUARD_PORT="$(ollama_url)"; OLLAMA_GUARD_PORT="${OLLAMA_GUARD_PORT##*:}"
  GUARD_MISSING=()
  if [[ "${ENABLE_WEBUI}" == "true" ]] \
     && ! grep -qE "dport \{[^}]*\b${WEBUI_PORT}\b" <<<"${INBOUND_DUMP}"; then
    GUARD_MISSING+=("WebUI ${WEBUI_PORT}")
  fi
  if [[ "${OLLAMA_GUARD_PORT}" =~ ^[0-9]+$ ]] && [[ "${OLLAMA_GUARD_PORT}" != "22" ]] \
     && ! grep -qE "dport \{[^}]*\b${OLLAMA_GUARD_PORT}\b" <<<"${INBOUND_DUMP}"; then
    GUARD_MISSING+=("Ollama ${OLLAMA_GUARD_PORT}")
  fi
  if (( ${#GUARD_MISSING[@]} )); then
    p_fail "inbound guard is loaded but does NOT cover: ${GUARD_MISSING[*]} — it went stale after a config change; re-run: sudo ./netmode.sh harden"
  else
    p_pass "inbound guard active and covers WebUI ${WEBUI_PORT} + Ollama ${OLLAMA_GUARD_PORT} — reachable only via loopback and Tailscale"
  fi
  # A guard that is loaded now but will not come back after a reboot is a
  # trap: the ports silently become public at the next restart and nothing
  # says so. The boot unit is the only thing that re-applies it.
  if systemd_available; then
    if systemctl is-enabled --quiet local-code-agent-netmode.service 2>/dev/null; then
      p_pass "inbound guard will be re-applied on boot (local-code-agent-netmode.service enabled)"
    else
      p_warn "the inbound guard is active NOW but its boot service is not enabled — after a reboot the WebUI/Ollama ports would be public. Fix: sudo ./netmode.sh --install-service"
    fi
  fi
fi

# --- Netmode + internet -----------------------------------------------------
step "Netmode + internet"
NETMODE="$(netmode_state)"
info "netmode: ${NETMODE}"
if curl -fsS --max-time 5 https://example.com -o /dev/null 2>/dev/null; then
  if [[ "${NETMODE}" == "offline" ]]; then
    p_fail "internet reachable although netmode is offline — lockdown NOT active (sudo ./netmode.sh offline)"
  else
    p_pass "internet reachable (probe: https://example.com)"
  fi
else
  if [[ "${NETMODE}" == "offline" ]]; then
    p_pass "internet blocked — expected, the kill switch is ON (sudo ./netmode.sh online to restore)"
  else
    p_warn "no internet (warn-only: local inference still works; installs/pulls will fail)"
  fi
fi

# --- Hardware ---------------------------------------------------------------
step "Hardware"
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|aarch64) p_pass "CPU architecture: ${ARCH}" ;;
  *) p_warn "untested CPU architecture: ${ARCH} (supported: x86_64, aarch64)" ;;
esac
info "RAM: ${RAM_GIB} GiB · resizing the VM re-tunes the model on next boot (see scripts/tune.sh)"
# GPU is optional — Ollama uses a supported one automatically; CPU is the
# fully-supported default. Report it so slow CPU inference is never a mystery.
if has_nvidia_gpu; then
  p_pass "NVIDIA GPU detected ($(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1))"
elif gpu_hardware_present; then
  # The worst case to leave unexplained: the card is there, so the user expects
  # speed, but without a driver Ollama silently runs on the CPU.
  p_warn "an NVIDIA card is present but no working driver was found (nvidia-smi missing/failing) — Ollama is running on the CPU. Install the driver (e.g. sudo ubuntu-drivers install) and restart ollama. See docs/GPU.md."
else
  info "no NVIDIA GPU — CPU inference (a reading pace); Ollama auto-uses a GPU if you move to a GPU host (see README 'Performance')"
fi
# Whether a GPU is actually being USED is a separate question from whether one
# exists: a driver can be present and Ollama still fall back to CPU (not enough
# VRAM for this model, runner mismatch). Report what is really happening.
GPU_PROC="$(ollama_processor "${MODEL_NAME}" 2>/dev/null || true)"
if [[ -n "${GPU_PROC}" ]]; then
  case "${GPU_PROC}" in
    *"100% GPU") p_pass "model '${MODEL_NAME}' is running on the GPU (${GPU_PROC})" ;;
    *"100% CPU")
      if has_nvidia_gpu; then
        p_warn "a GPU driver is present but '${MODEL_NAME}' is running 100% on the CPU — usually not enough free VRAM for this model. Try a smaller MODEL_FAMILY size, or check: nvidia-smi"
      else
        info "model '${MODEL_NAME}' is running on the CPU (${GPU_PROC}) — expected without a GPU"
      fi
      ;;
    *)
      # A split is NOT "most of the speed" — the CPU share sets the pace, so
      # this can be slower than a smaller model that fits VRAM entirely. It
      # looks like success, which is exactly why it needs to be a warning.
      VRAM_FIT=""
      if VRAM_MIB="$(gpu_vram_mib)" && VRAM_FIT="$(largest_model_for_vram "${VRAM_MIB}")"; then
        VRAM_FIT=" This card holds a model up to about ${VRAM_FIT}B entirely."
      fi
      p_warn "model '${MODEL_NAME}' is only partially on the GPU (${GPU_PROC}) — a split runs at close to CPU speed.${VRAM_FIT} Pick a model that fits VRAM completely: lca model --list-recommended (see docs/GPU.md)."
      ;;
  esac
else
  info "model '${MODEL_NAME}' is not loaded right now — run a query, then re-check to see CPU/GPU placement"
fi

# Free disk where Ollama keeps its models (>= 15 GB wanted).
MODELS_DIR=/usr/share/ollama/.ollama/models
[[ -d "${MODELS_DIR}" ]] || MODELS_DIR=/
FREE_GB="$(df -BG --output=avail "${MODELS_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [[ -z "${FREE_GB}" ]]; then
  p_warn "could not determine free disk space at ${MODELS_DIR}"
elif (( FREE_GB >= 15 )); then
  p_pass "free disk at ${MODELS_DIR}: ${FREE_GB} GB (>= 15 GB)"
else
  p_fail "only ${FREE_GB} GB free at ${MODELS_DIR} — models need headroom (>= 15 GB); clean up with: ollama rm <model>"
fi

# --- Backups (warn-only: backups are optional) ------------------------------
step "Backups"
if systemd_available && systemctl is-enabled --quiet local-code-agent-backup.timer 2>/dev/null; then
  # Report the REAL schedule the timer runs on (BACKUP_SCHEDULE is configurable),
  # and describe retention honestly — BACKUP_KEEP=0 means "keep everything",
  # not "keep newest 0".
  KEEP_DESC="keeping newest ${BACKUP_KEEP}"
  if ! [[ "${BACKUP_KEEP}" =~ ^[0-9]+$ ]]; then
    KEEP_DESC="retention disabled (BACKUP_KEEP='${BACKUP_KEEP}' is not a number)"
  elif [[ "${BACKUP_KEEP}" == "0" ]]; then
    KEEP_DESC="retention disabled (keeping all)"
  fi
  TIMER_SCHED="$(installed_backup_schedule || true)"
  [[ -n "${TIMER_SCHED}" ]] || TIMER_SCHED="${BACKUP_SCHEDULE}"
  p_pass "scheduled backup timer enabled (${TIMER_SCHED}; ${KEEP_DESC})"
  TIMER_ON=true
  # The timer keeps the schedule it was installed with, so a BACKUP_SCHEDULE
  # edited in .env and never applied leaves backups running on the old cadence
  # while .env claims otherwise — the same class as the WebUI and ollama drift
  # above. Compared through systemd's normaliser so "daily" and
  # "*-*-* 00:00:00" do not read as a difference, and only when BOTH sides
  # normalise: a warning we cannot substantiate is worse than none.
  WANT_SCHED="$(normalized_calendar "${BACKUP_SCHEDULE}" || true)"
  HAVE_SCHED="$(normalized_calendar "${TIMER_SCHED}" || true)"
  if [[ -n "${WANT_SCHED}" && -n "${HAVE_SCHED}" && "${WANT_SCHED}" != "${HAVE_SCHED}" ]]; then
    p_warn "backup schedule drift: the timer runs on '${TIMER_SCHED}' but .env says BACKUP_SCHEDULE='${BACKUP_SCHEDULE}' — your change is not in effect. Fix: sudo lca apply"
  fi
else
  info "scheduled backups off (optional) — enable with: sudo ${REPO_ROOT}/backup.sh --install-timer"
  TIMER_ON=false
  TIMER_SCHED=""
fi
shopt -s nullglob
BKS=( "${REPO_ROOT}"/backups/local-code-agent-backup-*.tar.gz )
shopt -u nullglob
if (( ${#BKS[@]} )); then
  mapfile -t BKS_SORTED < <(printf '%s\n' "${BKS[@]}" | sort)
  NEWEST="${BKS_SORTED[-1]}"
  NEWEST_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "${NEWEST}" 2>/dev/null || echo 0) ) / 86400 ))
  if (( NEWEST_AGE_DAYS <= 7 )); then
    p_pass "${#BKS[@]} backup(s); newest ${NEWEST_AGE_DAYS} day(s) old ($(basename "${NEWEST}"))"
  elif [[ "${TIMER_ON}" == "true" ]]; then
    # A slower-than-weekly OnCalendar is a legitimate choice; systemd owns the
    # cadence, so an older backup is not a fault and "enable the timer" would
    # be wrong advice — it is already enabled.
    info "${#BKS[@]} backup(s); newest ${NEWEST_AGE_DAYS} day(s) old — the timer is enabled (${TIMER_SCHED}), so this follows your schedule"
  else
    p_warn "${#BKS[@]} backup(s) present but the newest is ${NEWEST_AGE_DAYS} days old — run ${REPO_ROOT}/backup.sh or enable the timer"
  fi
else
  info "no backups yet — create one with: ${REPO_ROOT}/backup.sh"
fi

# --- Summary ----------------------------------------------------------------
printf '\n%b\n' "${C_BOLD}=================== SUMMARY ===================${C_RESET}"
printf '%b\n' "  ${C_GREEN}PASS: ${PASS}${C_RESET}   ${C_YELLOW}WARN: ${WARN}${C_RESET}   ${C_RED}FAIL: ${FAIL}${C_RESET}"
if (( FAIL > 0 )); then
  printf '%b\n' "${C_RED}${C_BOLD}Some checks FAILED — see above and docs/TROUBLESHOOTING.md${C_RESET}"
  exit 1
fi
if (( WARN > 0 )); then
  printf '%b\n' "${C_YELLOW}All hard checks passed, with warnings.${C_RESET}"
else
  printf '%b\n' "${C_GREEN}${C_BOLD}All checks passed.${C_RESET}"
fi
exit 0

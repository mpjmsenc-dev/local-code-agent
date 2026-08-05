#!/usr/bin/env bash
# check-system.sh — health check for the whole stack. Runs every check even
# when earlier ones fail, prints a colored summary, and exits 1 only if at
# least one hard FAIL occurred (warnings alone keep exit 0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

# --quick skips the one probe that costs real time: asking the model to
# generate. On a CPU box that is 20 seconds to a minute, which is fine when a
# human is diagnosing something and wasteful when a script has just done the
# same test itself (setup.sh smoke-tests the model seconds before calling us).
QUICK=false
for arg in "$@"; do
  case "${arg}" in
    -q|--quick) QUICK=true ;;
    -h|--help)
      echo "Usage: lca check [--quick]"
      echo
      echo "  --quick   skip the real-generation probe (seconds instead of a minute)"
      exit 0 ;;
    *) err "Unknown option: ${arg}"; echo "Usage: lca check [--quick]" >&2; exit 2 ;;
  esac
done

# From here on, keep going no matter what individual probes return.
set +e

PASS=0
WARN=0
FAIL=0

p_pass() { ok "$*";   PASS=$((PASS+1)); }
p_warn() { warn "$*"; WARN=$((WARN+1)); }
p_fail() { err "$*";  FAIL=$((FAIL+1)); }

# --- Settings that other checks assume are sane ------------------------------
# Checked FIRST, because a bad value here surfaces further down as three
# different confusing failures and never as itself. Measured with
# WEBUI_PORT=abc: netmode guards 3000 (its extractor falls back), the chat app
# container is created with PORT=abc and crash-loops, and the guard-coverage
# check asks for a port that can never be covered — so 'lca check' said the
# guard was stale, 'lca apply' re-applied it and reported success, and the next
# check said it again. A loop with no exit, and the word "abc" appeared
# nowhere.
step "Settings"
for setting in WEBUI_PORT OLLAMA_HOST; do
  case "${setting}" in
    WEBUI_PORT)
      if [[ "${ENABLE_WEBUI}" != "true" ]]; then
        info "WEBUI_PORT not checked — the chat app is disabled in .env."
      elif valid_port "${WEBUI_PORT}"; then
        p_pass "WEBUI_PORT=${WEBUI_PORT} is a usable port"
      else
        p_fail "WEBUI_PORT='${WEBUI_PORT}' is not a port number (1-65535). The chat app cannot bind it and the inbound guard cannot cover it, so nothing below can be right about that port. Fix it in ${ENV_FILE}, then: sudo ${SCRIPT_DIR}/bin/lca apply"
      fi
      ;;
    OLLAMA_HOST)
      OLLAMA_PORT_SEEN="$(ollama_url)"; OLLAMA_PORT_SEEN="${OLLAMA_PORT_SEEN##*:}"
      if valid_port "${OLLAMA_PORT_SEEN}"; then
        p_pass "OLLAMA_HOST resolves to a usable port (${OLLAMA_PORT_SEEN})"
      else
        p_fail "OLLAMA_HOST='${OLLAMA_HOST}' does not give a usable port number. Nothing can reach the model server, and the inbound guard cannot cover it. Fix it in ${ENV_FILE}, then: sudo ${SCRIPT_DIR}/bin/lca apply"
      fi
      ;;
  esac
done

# Switches take exactly two words, and everything here compares against the
# literal "true" — so AUTO_TUNE=yes does not mean "on", it means the headline
# feature is off and nothing says so. The list comes from .env.example, so a
# new switch is covered the day it ships.
BOOLS_OK=0
BOOLS_BAD=0
while read -r setting; do
  [[ -n "${setting}" ]] || continue
  if valid_bool "${!setting}"; then
    BOOLS_OK=$((BOOLS_OK+1))
    continue
  fi
  BOOLS_BAD=$((BOOLS_BAD+1))
  p_warn "${setting}='${!setting}' is not true or false. Every switch here is compared against the word 'true', so this reads as OFF — which is probably not what you meant. Fix it in ${ENV_FILE}, then: sudo ${SCRIPT_DIR}/bin/lca apply"
done < <(boolean_settings 2>/dev/null || true)
# The pass line counts only what passed. Printed unconditionally it said "6
# settings hold true or false" directly under a warning that one of them does
# not — the same summarising-over-a-failure this file takes out everywhere else.
if (( BOOLS_OK + BOOLS_BAD == 0 )); then
  p_warn "could not read the list of on/off settings from .env.example — they were not checked"
elif (( BOOLS_BAD == 0 )); then
  p_pass "${BOOLS_OK} on/off setting(s) hold true or false"
fi

# Numbers, with the consequence of each spelled out. These fail quietly or
# confusingly, never as themselves:
#
#   OLLAMA_CONTEXT_LENGTH=abc  measured: Ollama warns once in its log and runs
#     with 0 (the model's own default) while run-agent tells aider 8192, so
#     prompts are silently truncated — the exact failure the model-metadata
#     file exists to prevent. The drop-in matches .env, so the drift check is
#     happy and nothing else looks.
#   BACKUP_KEEP=abc            retention refuses to act on a value it cannot
#     parse, which is the safe direction and means the disk fills quietly.
#   LCA_ASK_TOKENS=abc         'lca ask' falls back to 512 without a word.
for setting in OLLAMA_CONTEXT_LENGTH LCA_ASK_TOKENS BACKUP_KEEP; do
  value="${!setting}"
  case "${setting}" in
    BACKUP_KEEP) [[ "${value}" =~ ^[0-9]+$ ]] && continue ;;
    *)           [[ "${value}" =~ ^[0-9]+$ ]] && (( 10#${value} > 0 )) && continue ;;
  esac
  case "${setting}" in
    OLLAMA_CONTEXT_LENGTH)
      p_fail "OLLAMA_CONTEXT_LENGTH='${value}' is not a number. Ollama ignores it and runs at the model's own default while aider is told 8192, so long prompts are silently truncated. Fix it in ${ENV_FILE}, then: sudo ${SCRIPT_DIR}/bin/lca apply" ;;
    BACKUP_KEEP)
      p_warn "BACKUP_KEEP='${value}' is not a whole number, so retention never runs and backups accumulate until the disk is full. Set a number (or 0 to keep everything on purpose) in ${ENV_FILE}." ;;
    LCA_ASK_TOKENS)
      p_warn "LCA_ASK_TOKENS='${value}' is not a positive number — 'lca ask' silently uses 512. Fix it in ${ENV_FILE}." ;;
  esac
done

# --- Binaries ---------------------------------------------------------------
step "Binaries"
for bin in git curl jq python3 ollama nft; do
  if have "${bin}"; then
    p_pass "binary: ${bin}"
  else
    p_fail "binary missing: ${bin} (run ${SCRIPT_DIR}/setup.sh)"
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
      p_warn "user '${check_user}' not in the docker group (log out/in after setup, or re-run ${SCRIPT_DIR}/scripts/install_docker.sh)"
    fi
  else
    p_fail "docker not installed (run ${SCRIPT_DIR}/scripts/install_docker.sh, or set SKIP_DOCKER=true)"
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
if [[ -x "$(venv_python)" ]]; then
  p_pass "virtualenv exists at ${VENV_PATH}"
else
  p_fail "virtualenv missing at ${VENV_PATH} (run ${SCRIPT_DIR}/scripts/install_python.sh)"
fi
if [[ -x "${AIDER}" ]]; then
  aider_version="$("${AIDER}" --version 2>/dev/null)"
  if [[ -n "${aider_version}" ]]; then
    p_pass "aider works: ${aider_version}"
  else
    p_fail "aider binary exists but --version failed (re-run ${SCRIPT_DIR}/scripts/install_python.sh)"
  fi
else
  p_fail "aider not installed in the venv (run ${SCRIPT_DIR}/scripts/install_python.sh)"
fi
# aider's product is commits, and a commit needs an author. install_git.sh
# warns about a missing identity — 20-30 minutes into a first-boot log nobody
# scrolls back through — and nothing said it again afterwards, though this is
# the command people run when something looks wrong. Warn, never fail: the
# stack works without it.
if have git; then
  if GIT_IDENTITY="$(git_identity)"; then
    p_pass "git identity for '$(git_identity_user)': ${GIT_IDENTITY}"
  else
    p_warn "no global git identity for '$(git_identity_user)' — aider still commits, but stamps your work 'Your Name <you@example.com>', and a 'git commit' you run yourself in that project refuses outright ('Please tell me who you are'). Fix once: git config --global user.name 'Ada Lovelace' && git config --global user.email 'ada@example.com'"
  fi
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
    if [[ "${QUICK}" == "true" ]]; then
      # Reported as skipped, never counted as a pass: "downloaded" is not
      # "works", and this is the only check that proves inference at all.
      info "--quick: skipping the real-generation probe (run 'lca check' without it to test inference)"
    else
      info "asking '${MODEL_NAME}' for a real generation (may take a minute on first load)..."
      if model_responds "${MODEL_NAME}" 240; then
        p_pass "model '${MODEL_NAME}' responds to a real generation"
      else
        p_fail "model '${MODEL_NAME}' did not respond (RAM? see: free -h and journalctl -u ollama)"
      fi
    fi
  elif [[ "$(netmode_state)" == "offline" ]]; then
    p_fail "model '${MODEL_NAME}' not downloaded, and netmode is OFFLINE — run 'sudo ${SCRIPT_DIR}/netmode.sh online' then 'ollama pull ${MODEL_NAME}'"
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
# tune.sh runs 'set -euo pipefail' at its top level, and sourcing executes
# that in OUR shell — silently undoing the 'set +e' at the top of this file,
# whose whole purpose is that one failing probe must not abort the rest of the
# health check. Everything below happens to survive because its failures are
# inside tested conditions, which is luck, not design.
set +e
SCRIPT_DIR="${CHECK_DIR}"
unset CHECK_DIR
# choose_for_ram, not a re-implementation of it. Sourcing tune.sh shared the
# family TABLE and nothing else: the rung selection was copied inline here and
# the copy dropped choose_for_ram's fallback for a family whose smallest size
# cannot fit this machine. Measured with MODEL_FAMILY=deepseek-coder-v2, which
# ships only 16b:
#
#    8 GiB   tune.sh picks qwen2.5-coder:3b   this said deepseek-coder-v2:16b
#   12 GiB   both agree
#
# — so on a base droplet the health check warned that the model differed from
# the recommendation and told the reader to run the very script that had just
# chosen correctly. Which is precisely the bug the comment above says was
# fixed by sourcing. It was only half fixed; this is the other half.
choose_for_ram "${RAM_GIB}"
info "RAM ladder: ${RAM_GIB} GiB detected → recommended model ${TUNE_MODEL}"
if [[ "${AUTO_TUNE}" != "true" ]]; then
  info "AUTO_TUNE=false — model manually pinned to ${MODEL_NAME}; drift check skipped."
elif [[ "${MODEL_NAME}" == "${TUNE_MODEL}" ]]; then
  p_pass "configured model matches the tune recommendation"
else
  p_warn "configured model (${MODEL_NAME}) differs from the recommendation (${TUNE_MODEL}) — run ${SCRIPT_DIR}/scripts/tune.sh"
fi
# AUTO_TUNE only actually adapts to a resized VM if the boot unit runs it.
# Without this, "resize the droplet and the model follows" is a promise with
# nothing behind it, and the failure is silent — everything keeps working, at
# the old model, forever.
if [[ "${AUTO_TUNE}" == "true" ]] && systemd_available; then
  if systemctl is-enabled --quiet local-code-agent-tune.service 2>/dev/null; then
    if TUNE_GONE="$(stale_boot_program local-code-agent-tune.service)"; then
      p_warn "auto-tune's boot service is enabled but runs ${TUNE_GONE}, which it can no longer execute (was this checkout moved or renamed?) — resizing this VM will NOT change the model. Fix: sudo ${SCRIPT_DIR}/setup.sh"
    else
      p_pass "auto-tune will re-run on boot (local-code-agent-tune.service enabled)"
    fi
  else
    p_warn "AUTO_TUNE=true but local-code-agent-tune.service is not enabled — resizing this VM will NOT change the model on reboot. Fix: $(reenable_hint local-code-agent-tune.service "sudo ${SCRIPT_DIR}/setup.sh")"
  fi
fi
# These two are what setup.sh installs OUTSIDE the checkout, and both are
# symlinks into it. They had been printing under the "Auto-tune" heading,
# which is where the previous check happened to end — a reader scanning
# section headings for "why is lca broken" would never look there.
step "The 'lca' command and the login banner"
# Every doc, message and banner in this project tells you to type 'lca'. That
# is a symlink into this checkout, so moving or renaming the directory breaks
# it — including 'lca check', which is what someone reaches for when the stack
# seems broken. This copy still runs, so it is the one that can explain.
LCA_LINK=/usr/local/bin/lca
case "$(lca_link_state "${LCA_LINK}" "${SCRIPT_DIR}/bin/lca")" in
  ok)      p_pass "'lca' on PATH runs this checkout" ;;
  broken)  p_warn "'lca' on PATH points at $(readlink "${LCA_LINK}" 2>/dev/null || echo 'nothing'), which is not there — the lca command is broken (was this checkout moved or renamed?). Fix: sudo ${SCRIPT_DIR}/setup.sh" ;;
  foreign) p_warn "'lca' on PATH runs $(readlink -f "${LCA_LINK}" 2>/dev/null), a DIFFERENT checkout from this one (${SCRIPT_DIR}) — 'lca check' and this run are not the same code. Fix: sudo ${SCRIPT_DIR}/setup.sh" ;;
  other)   info "${LCA_LINK} exists but is not a link to a local-code-agent checkout — leaving it alone." ;;
  *)       info "no 'lca' command on PATH — use ${SCRIPT_DIR}/bin/lca, or install it with: sudo ${SCRIPT_DIR}/setup.sh" ;;
esac
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
    restarting) p_fail "container '${WEBUI_CONTAINER}' is CRASH-LOOPING (restarting) — often port ${WEBUI_PORT} taken or a bad .env; see: ${SCRIPT_DIR}/webui.sh logs" ;;
    "")         p_fail "container '${WEBUI_CONTAINER}' does not exist (${SCRIPT_DIR}/webui.sh start)" ;;
    *)          p_fail "container '${WEBUI_CONTAINER}' is '${webui_status}', not running (${SCRIPT_DIR}/webui.sh start)" ;;
  esac
  # Probe /health (Open WebUI-specific) so a different service squatting the
  # port cannot masquerade as a healthy WebUI.
  if webui_responds; then
    p_pass "Open WebUI /health answering on port ${WEBUI_PORT}"
  else
    p_fail "Open WebUI /health not answering on port ${WEBUI_PORT} (${SCRIPT_DIR}/webui.sh logs)"
  fi
  # Open signups are the one setting where the documented happy path ends with
  # a manual step the user has to remember (YOUR-TURN.md step 4.3). Forget it
  # and anyone who reaches the app can register an account on the private AI
  # this whole project exists to keep private. Nothing said so until now.
  if [[ "${WEBUI_ENABLE_SIGNUP}" == "true" ]]; then
    p_warn "signups are OPEN (WEBUI_ENABLE_SIGNUP=true) — anyone who can reach the chat app can create an account. Once you have made yours: set WEBUI_ENABLE_SIGNUP=false in .env and run: sudo lca apply"
  else
    p_pass "signups are closed (WEBUI_ENABLE_SIGNUP=false)"
  fi
  # The container keeps a COPY of every setting it was created with, so an
  # .env edit never reaches it on its own. This file already reports exactly
  # that for Ollama's drop-in a few checks above — the chat app's half was
  # only ever reported by './webui.sh status', which is not the command the
  # README, the docs, or the login banner send anyone to. So the half of the
  # applied-settings class that includes the assistant's own system prompt was
  # invisible from 'lca check'.
  #
  # Only when a container exists: with none, every comparison reads "cannot
  # tell", and printing "matches .env" about a thing that is not there is the
  # confidently-wrong line this file works hardest to avoid.
  if [[ -n "${webui_status}" ]]; then
    webui_drifted="$(webui_drift || true)"
    if [[ -n "${webui_drifted}" ]]; then
      p_warn "chat app config drift: ${webui_drifted//$'\n'/, } — edited in .env or the repo but NOT in effect, because the running container still holds what it was created with. Fix: sudo lca apply"
    else
      # Only claim the prompt was checked when it could be. webui_drift skips
      # both prompt comparisons without jq, or when either side is unreadable —
      # and this line named "system prompt" regardless, which is the
      # cannot-tell-reported-as-fine mistake the rest of this file works hardest
      # to avoid. selftest.sh already says "skipped, not passed" for the same
      # check; so does this now.
      if webui_prompt_comparable; then
        p_pass "chat app matches .env (port, model, signups, Ollama address, name, system prompt)"
      else
        p_pass "chat app matches .env (port, model, signups, Ollama address, name)"
        info "the assistant prompt and starter questions could not be compared here (jq missing, or the container's values unreadable) — those were skipped, not passed"
      fi
    fi
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
  p_warn "tailscale not installed (run ${SCRIPT_DIR}/scripts/install_tailscale.sh for phone access)"
fi

# --- Inbound guard ----------------------------------------------------------
step "Inbound guard"
if [[ "${ENABLE_WEBUI}" != "true" ]] && ! ollama_bind_is_public; then
  info "WebUI disabled and Ollama on loopback — no public service ports to guard."
elif ! have nft; then
  p_warn "nft not installed — the inbound guard is not enforced (WebUI/Ollama ports may be publicly reachable)"
elif ! can_root_now; then
  p_warn "cannot inspect nftables from this account — the guard was neither confirmed nor ruled out. Re-run as root (or with a sudo that does not need a password): sudo ${SCRIPT_DIR}/check-system.sh"
elif ! as_root nft list table inet lca_inbound >/dev/null 2>&1; then
  p_fail "inbound guard NOT loaded — WebUI/Ollama ports may be publicly reachable (sudo ${SCRIPT_DIR}/netmode.sh harden)"
else
  # Existence is not enough: confirm the port the WebUI actually binds is in
  # the drop set. A config change without a re-harden, or a parser mismatch,
  # would otherwise show green while the real port stays exposed.
  # Check the OLLAMA port too, not just the WebUI one. The Ollama API is
  # unauthenticated, and changing OLLAMA_HOST (documented in
  # docs/TROUBLESHOOTING.md) leaves the guard baked with the OLD port — so the
  # asymmetric check used to print a green "covers the configured port(s)"
  # while a public Ollama bind was live. Name the ports so the claim can be
  # checked by eye instead of taken on trust. The rule itself lives in lib.sh
  # because 'lca apply' now fixes what this reports, and the two must not be
  # able to disagree about which ports count.
  INBOUND_DUMP="$(as_root nft list table inet lca_inbound 2>/dev/null)"
  GUARD_WANT="$(guarded_ports || true)"
  GUARD_MISSING="$(inbound_guard_uncovered "${INBOUND_DUMP}" || true)"
  if [[ -n "${GUARD_MISSING}" ]]; then
    p_fail "inbound guard is loaded but does NOT cover: ${GUARD_MISSING//$'\n'/, } — it went stale after a config change. Fix: sudo lca apply"
  else
    p_pass "inbound guard active and covers ${GUARD_WANT//$'\n'/ + } — reachable only via loopback and Tailscale"
  fi
  # A guard that is loaded now but will not come back after a reboot is a
  # trap: the ports silently become public at the next restart and nothing
  # says so. The boot unit is the only thing that re-applies it.
  if systemd_available; then
    if systemctl is-enabled --quiet local-code-agent-netmode.service 2>/dev/null; then
      # ...but "enabled" only means the symlink is there. The unit runs an
      # absolute path baked in by whichever checkout installed it, so moving
      # or renaming this directory leaves a green tick on a boot service that
      # cannot start — and the ports it was guarding become public.
      if NETMODE_GONE="$(stale_boot_program local-code-agent-netmode.service)"; then
        p_warn "the inbound guard's boot service is enabled but runs ${NETMODE_GONE}, which it can no longer execute (was this checkout moved or renamed?) — it will fail at the next boot and the WebUI/Ollama ports become public. Fix: sudo ${SCRIPT_DIR}/netmode.sh harden"
      else
        p_pass "inbound guard will be re-applied on boot (local-code-agent-netmode.service enabled)"
      fi
    else
      p_warn "the inbound guard is active NOW but its boot service is not enabled — after a reboot the WebUI/Ollama ports would be public. Fix: sudo ${SCRIPT_DIR}/netmode.sh harden"
    fi
  fi
fi

# --- Netmode + internet -----------------------------------------------------
step "Netmode + internet"
NETMODE="$(netmode_state)"
info "netmode: ${NETMODE}"
if curl -fsS --max-time 5 https://example.com -o /dev/null 2>/dev/null; then
  if [[ "${NETMODE}" == "offline" ]]; then
    p_fail "internet reachable although netmode is offline — lockdown NOT active (sudo ${SCRIPT_DIR}/netmode.sh offline)"
  else
    p_pass "internet reachable (probe: https://example.com)"
  fi
else
  if [[ "${NETMODE}" == "offline" ]]; then
    p_pass "internet blocked — expected, the kill switch is ON (sudo ${SCRIPT_DIR}/netmode.sh online to restore)"
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
info "RAM: ${RAM_GIB} GiB · resizing the VM re-tunes the model on next boot (see ${SCRIPT_DIR}/scripts/tune.sh)"
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
# Through classify_gpu (via gpu_state_for_placement), not off the string.
#
# This used to read 'ollama ps' and decide from its shape: anything that was
# not exactly "100% GPU" or "100% CPU" became "only partially on the GPU". It
# never asked whether this machine HAS a GPU — three lines after printing "no
# NVIDIA GPU — CPU inference" it was telling the reader to pick a model that
# fits their VRAM, on a box with none. Ollama 0.32.5 prints "13%/87% CPU/GPU"
# on a CPU-only host, so that is not hypothetical; it is what this project's
# own target hardware produces.
case "$(gpu_state_for_placement "${GPU_PROC}")" in
  active) p_pass "model '${MODEL_NAME}' is running on the GPU (${GPU_PROC})" ;;
  idle)
    p_warn "a GPU driver is present but '${MODEL_NAME}' is running on the CPU (${GPU_PROC}) — usually not enough free VRAM for this model. Try a smaller MODEL_FAMILY size, or check: nvidia-smi"
    ;;
  split)
    # A split is NOT "most of the speed" — the CPU share sets the pace, so
    # this can be slower than a smaller model that fits VRAM entirely. It
    # looks like success, which is exactly why it needs to be a warning.
    VRAM_FIT=""
    if VRAM_MIB="$(gpu_vram_mib)" && VRAM_FIT="$(largest_model_for_vram "${VRAM_MIB}")"; then
      VRAM_FIT=" This card holds a model up to about ${VRAM_FIT}B entirely."
    fi
    p_warn "model '${MODEL_NAME}' is only partially on the GPU (${GPU_PROC}) — a split runs at close to CPU speed.${VRAM_FIT} Pick a model that fits VRAM completely: lca model --list-recommended (see docs/GPU.md)."
    ;;
  *)
    # none | no-driver | unknown. Which of the first two applies was already
    # said by the card/driver lines above; repeating it here would be noise.
    if [[ -z "${GPU_PROC}" ]]; then
      info "model '${MODEL_NAME}' is not loaded right now — run a query, then re-check to see CPU/GPU placement"
    elif [[ "${GPU_PROC}" == *"/"* ]]; then
      info "model '${MODEL_NAME}' placement reads '${GPU_PROC}', but there is no usable NVIDIA GPU here — this is CPU inference. Ollama reports a split for memory it manages itself; there is no card on this machine to size a model against."
    else
      info "model '${MODEL_NAME}' is running on the CPU (${GPU_PROC}) — expected without a GPU"
    fi
    ;;
esac

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
  # The timer fires local-code-agent-backup.service, and that is where the
  # baked-in path lives. A timer pointing at a script that moved keeps firing
  # on schedule and failing every time — the one drift you find out about by
  # needing a backup that was never taken.
  if BACKUP_GONE="$(stale_boot_program local-code-agent-backup.service)"; then
    p_warn "the backup timer runs ${BACKUP_GONE}, which it can no longer execute (was this checkout moved or renamed?) — every scheduled backup since then has failed. Fix: sudo ${SCRIPT_DIR}/backup.sh --install-timer"
  fi
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

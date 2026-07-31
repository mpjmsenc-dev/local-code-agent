#!/usr/bin/env bash
# scripts/motd.sh — the login banner, installed as /etc/update-motd.d/99-local-code-agent.
#
# Why this exists: a first-boot install takes 20-30 minutes, most of it a
# multi-gigabyte model download. Someone who creates the droplet and SSHs in
# two minutes later gets the stock Ubuntu banner and no hint that anything is
# happening — so they run 'lca chat', get a confusing failure, and conclude it
# is broken. This answers the only question they have on the way in: is it
# ready, is it still working, or did it fail — and what should I type next.
#
# Constraints this script lives under, because it runs as ROOT on EVERY login:
#   - it must never hang (a wedged docker or tailscale would stall every SSH),
#     so every probe is bounded by 'quick'
#   - it must never write anything (hence load_env_readonly, not load_env)
#   - it must never break a login, so probes are individually tolerant
#
# Usage:
#   motd.sh              print the banner
#   motd.sh --install    install it into /etc/update-motd.d (needs root)
set -euo pipefail

# Resolve through the /etc/update-motd.d symlink first, exactly as bin/lca
# does. run-parts executes the symlink, so BASH_SOURCE is the path in
# /etc/update-motd.d and an unresolved SCRIPT_DIR looks for lib.sh there.
SELF="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f "${SELF}" 2>/dev/null || printf '%s' "${SELF}")"
fi
SCRIPT_DIR="$(cd "$(dirname "${SELF}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# pam_motd runs run-parts with a stripped environment, so PATH is not
# guaranteed to include the directories tailscale/docker/systemctl live in.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:${PATH}}"

# quick CMD... — run a probe under a hard time limit, discarding failures.
# Two seconds is far longer than any of these take when healthy and short
# enough that a hung daemon costs a login almost nothing.
quick() {
  if have timeout; then
    timeout 2 "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# strip_ansi — the install log is a tee of coloured terminal output, so its
# lines carry escape sequences that would print as garbage inside a banner.
strip_ansi() {
  LC_ALL=C sed -e 's/\r/\n/g' -e 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# --- state ------------------------------------------------------------------

# current_run_log — the part of the install log belonging to the run in
# progress. The log is appended to across re-runs, so an old verdict line left
# in the tail would otherwise be read as this run's result.
current_run_log() {
  local recent
  recent="$(tail -n 400 "${SETUP_LOG}" 2>/dev/null || true)"
  # Capture-then-here-string, never 'tail | grep -q': under 'set -o pipefail' a
  # grep that exits on its first match SIGPIPEs the producer and the pipeline
  # returns 141, which reads as "not found" precisely when it WAS found.
  if grep -qa 'first-boot install started' <<<"${recent}"; then
    recent="$(awk '/first-boot install started/ {buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"${recent}")"
  fi
  printf '%s' "${recent}"
}

# How long the install log may go unwritten and still count as "in progress".
# Every phase of a real install — apt, the docker pull, the model download —
# writes continuously, so a quarter hour of total silence means it stopped.
STALE_AFTER=900

# install_state — none | running | stalled | failed | done, from the first-boot
# log alone. The freshness test is the important part: "the log has no verdict"
# is NOT evidence that an install is running. The machine this was written on
# proved it — its first-boot install was interrupted 19 hours earlier while
# validating a model, leaving a verdict-less log on a box where everything
# works. Claiming "still installing, nothing works yet" there would be
# confidently wrong, which is worse than saying nothing.
install_state() {
  local recent age
  [[ -r "${SETUP_LOG}" ]] || { printf 'none'; return 0; }
  recent="$(current_run_log)"
  [[ -n "${recent}" ]] || { printf 'none'; return 0; }
  if grep -qa 'SETUP COMPLETE' <<<"${recent}"; then
    printf 'done'
  elif grep -qa 'SETUP FINISHED WITH ERRORS\|FIRST-BOOT INSTALL FAILED' <<<"${recent}"; then
    printf 'failed'
  elif grep -qa 'first-boot install finished' <<<"${recent}"; then
    # Reached with LCA_RUN_SETUP=false: cloned, setup deliberately not run.
    printf 'done'
  else
    age="$(log_age_seconds || true)"
    if [[ -n "${age}" ]] && (( age > STALE_AFTER )); then
      printf 'stalled'
    else
      printf 'running'
    fi
  fi
}

# last_step — the most recent '==>' heading, which says how far the install
# got. Deliberately not the last line: a model pull's progress bar is one
# enormous carriage-return-laden line that means nothing out of context.
last_step() {
  local line
  line="$(grep -a '==>' <<<"$(current_run_log)" | tail -1 | strip_ansi | tail -1 || true)"
  line="${line#*==> }"
  printf '%s' "${line}"
}

# log_age_seconds — seconds since the install log was last written, which is
# the question behind "is it stuck?". Non-zero when it cannot be determined,
# so callers can tell "no answer" from "zero seconds".
log_age_seconds() {
  local mtime now age
  have stat && have date || return 1
  mtime="$(quick stat -c %Y "${SETUP_LOG}")" || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  [[ "${mtime}" =~ ^[0-9]+$ && "${now}" =~ ^[0-9]+$ ]] || return 1
  age=$(( now - mtime ))
  # A clock that moved backwards (NTP settling on a fresh droplet is the usual
  # cause) must not report a negative age.
  if (( age < 0 )); then age=0; fi
  printf '%s' "${age}"
}

# log_age_human — the same figure, phrased for a banner.
log_age_human() {
  local age
  age="$(log_age_seconds)" || return 1
  if (( age < 90 )); then
    printf '%ss ago' "${age}"
  elif (( age < 5400 )); then
    printf '%s min ago' "$(( age / 60 ))"
  else
    # "1127 min ago" is technically true and reads as noise.
    printf '%s h ago' "$(( age / 3600 ))"
  fi
}

# engine_up — is the model engine actually serving? systemd first because it
# cannot hang on a wedged HTTP listener; the curl fallback covers containers
# and other places without systemd.
engine_up() {
  if have systemctl && quick systemctl is-active --quiet ollama; then
    return 0
  fi
  if have curl && quick curl -fsS "$(ollama_url)/api/version" >/dev/null; then
    return 0
  fi
  return 1
}

# chat_address — where to point a phone, or a hint for how to get there.
# Prints "URL<TAB>hint"; either side may be empty.
chat_address() {
  local ip=""
  if [[ "${ENABLE_WEBUI}" != "true" || "${SKIP_DOCKER}" == "true" ]]; then
    return 1
  fi
  if have tailscale; then
    ip="$(quick tailscale ip -4 || true)"
    ip="${ip%%$'\n'*}"
  fi
  if [[ -n "${ip}" ]]; then
    printf 'http://%s:%s\t' "${ip}" "${WEBUI_PORT}"
  elif have tailscale; then
    printf '\trun: sudo tailscale up\n'
  elif [[ "${SKIP_TAILSCALE}" == "true" ]]; then
    printf '\tport %s, over the private network you provide\n' "${WEBUI_PORT}"
  else
    # Not installed and not skipped: pointing at 'sudo tailscale up' here would
    # hand the user a command that does not exist.
    printf '\tTailscale is not installed — see: lca check\n'
  fi
}

# --- rendering --------------------------------------------------------------

# row LABEL VALUE — one aligned banner line. Alignment is what makes a banner
# scannable in the second someone actually gives it.
row() { printf '   %-20s %s\n' "$1" "$2"; }

headline() { printf '\n %b%s%b  %s\n' "${C_BOLD}" "local-code-agent" "${C_RESET}" "$1"; }

banner_installing() {
  local age step
  age="$(log_age_human || true)"
  step="$(last_step || true)"
  if [[ -n "${age}" ]]; then
    headline "still installing — nothing works yet (log updated ${age})"
  else
    headline "still installing — nothing works yet"
  fi
  if [[ -n "${step}" ]]; then row "Currently" "${step}"; fi
  row "Watch it" "tail -f ${SETUP_LOG}"
  printf '\n'
}

banner_failed() {
  local verdict
  verdict="$(grep -a 'SETUP FINISHED WITH ERRORS\|FIRST-BOOT INSTALL FAILED' <<<"$(current_run_log)" \
    | tail -1 | strip_ansi | tail -1 || true)"
  headline "the install did NOT finish"
  if [[ -n "${verdict}" ]]; then row "Verdict" "${verdict}"; fi
  row "What to do" "lca check   ·   lca logs setup"
  printf '\n'
}

banner_attention() {
  headline "installed, but the model engine is not running"
  row "What to do" "lca check   ·   lca logs ollama"
  offline_row
  printf '\n'
}

# Reached only when the log stopped mid-install AND nothing is serving, so the
# install really did give up partway. Re-running setup is safe (it is
# idempotent) and is the actual fix, which "run lca check" would not have said.
banner_stalled() {
  local age step
  age="$(log_age_human || true)"
  step="$(last_step || true)"
  headline "the install stopped before it finished${age:+ (nothing written to the log for ${age%% ago})}"
  if [[ -n "${step}" ]]; then row "Stopped at" "${step}"; fi
  row "Finish it" "sudo ${REPO_ROOT}/setup.sh"
  row "Or read why" "lca logs setup"
  offline_row
  printf '\n'
}

banner_ready() {
  local addr url hint
  headline "ready   ·   model ${MODEL_NAME}"
  addr="$(chat_address || true)"
  url="${addr%%$'\t'*}"
  hint="${addr#*$'\t'}"
  hint="${hint%$'\n'}"
  if [[ -n "${url}" ]]; then
    row "Chat on your phone" "${url}"
  elif [[ -n "${hint}" ]]; then
    row "Chat on your phone" "${hint}"
  fi
  row "Ask right here" "lca ask \"why is this box slow?\""
  row "All commands" "lca help"
  offline_row
  printf '\n'
}

# offline_row — the kill switch is invisible once engaged, and every download
# failing for no stated reason is a genuinely baffling half hour.
offline_row() {
  if [[ "$(netmode_state 2>/dev/null || echo online)" == "offline" ]]; then
    row "Internet" "OFF (kill switch) — sudo lca online to restore"
  fi
}

main() {
  if [[ "${1:-}" == "--install" ]]; then
    install_motd
    return 0
  fi
  load_env_readonly

  local state
  state="$(install_state)"
  case "${state}" in
    running) banner_installing; return 0 ;;
    failed)  banner_failed;     return 0 ;;
  esac

  # For every other state the live system is the better witness than the log:
  # an interrupted install often leaves a perfectly working stack behind, and a
  # log saying COMPLETE is no comfort if ollama died an hour later.
  if engine_up; then
    banner_ready
  elif [[ "${state}" == "stalled" ]]; then
    banner_stalled
  else
    banner_attention
  fi
}

install_motd() {
  local dir="${MOTD_FILE%/*}"
  if [[ ! -d "${dir}" ]]; then
    warn "${dir} does not exist — this system does not use update-motd, so no login banner was installed."
    return 0
  fi
  # A symlink, like /usr/local/bin/lca: the banner then tracks this checkout
  # instead of becoming a stale copy after 'lca update'. run-parts accepts a
  # symlink, and the name deliberately contains no '.' — run-parts --lsbsysinit
  # (which is how pam_motd invokes it) skips files with dots in the name.
  if as_root ln -sfn "${SCRIPT_DIR}/motd.sh" "${MOTD_FILE}" 2>/dev/null; then
    as_root chmod +x "${SCRIPT_DIR}/motd.sh" 2>/dev/null || true
    ok "Login banner installed — SSH in and it reports whether the stack is ready."
  else
    warn "Could not install the login banner at ${MOTD_FILE} — not fatal, everything else works."
  fi
}

# Run main only when executed, so tests can source this file and drive
# install_state() against a real log — same pattern as scripts/tune.sh.
# run-parts executes the symlink, so $0 and BASH_SOURCE[0] are both that path
# and the banner still prints at login.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

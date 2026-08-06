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

# product_installed — did setup get far enough to leave the coding agent behind?
#
# This is the difference between "the install stopped partway" and "this box
# has worked for days and the engine just died", and install_state cannot tell
# them apart: both are a log with no verdict. Its own header comment describes
# the second case — an interrupted first boot on a machine where everything
# works — and banner_stalled was still chosen for it the moment ollama stopped.
#
# Measured on that machine. With ollama killed, the banner read "the install
# stopped before it finished (nothing written to the log for 144 h)" and
# offered 'sudo setup.sh': a 20-30 minute re-run, for a process that had died a
# minute earlier. banner_attention's "installed, but the model engine is not
# running · lca check · lca logs ollama" is the answer to what actually
# happened.
#
# aider is installed by install_python.sh, near the end of setup.sh, so its
# presence means the install got past everything that matters. A path test, so
# it cannot hang — which this file requires of every probe.
product_installed() { [[ -x "$(aider_bin)" ]]; }

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

headline() {
  printf '\n %b%s%b  %s\n' "${C_BOLD}" "local-code-agent" "${C_RESET}" "$1"
  missing_lca_row
}

# missing_lca_row — every banner below speaks in 'lca'. Say so when it is not
# there.
#
# setup.sh installs /usr/local/bin/lca as a symlink and deliberately does NOT
# die if it cannot: no root, or a read-only /usr/local, and it warns and
# carries on. That is the right call — the stack works, only the short name is
# missing — but it leaves a box where every line of this banner names a command
# that does not exist. Measured on exactly such a box: 'ready', a chat URL, and
# four commands, all of which answer 'lca: command not found'.
#
# chat_address() already refuses to print 'sudo tailscale up' on a machine
# without tailscale, for this reason and in as many words. This is the same
# rule applied to the command this file mentions four times instead of once.
#
# Called from headline() rather than from each banner, so a sixth banner state
# added later cannot forget it — the note has to sit above the rows it is about,
# and every banner starts with exactly one headline.
# Silent in the two banners that are already about setup not having finished.
# There the missing symlink is a symptom rather than a fault — setup.sh
# installs it near the end — and the advice would be actively wrong: "run sudo
# setup.sh" printed underneath "still installing — nothing works yet" invites a
# SECOND concurrent install, and banner_stalled prints that same line already,
# for the real reason.
#
# Keyed on WHICH BANNER is rendering, not on install_state. Written the other
# way first, and it was wrong on the machine it was written on: this box's log
# is verdict-less from an interrupted first boot, so install_state says
# 'stalled' while main() — which trusts the live system over the log — prints
# banner_ready. The row vanished from precisely the box that needed it.
#
# Default is to SHOW, so a future banner that forgets to opt out prints one
# redundant row rather than hiding a needed one.
# full | path | none — how much of the note this banner wants.
#
# 'path' exists because banner_no_model already ends with "Finish it: sudo
# setup.sh", so the full note printed that same command again two lines above
# it. The translation half is still needed there — that banner's last row is
# "Details: lca check" — so suppressing the whole thing would leave its own
# advice unusable. Seen by rendering the no-model banner on a box without the
# symlink.
BANNER_LCA_ROW=full
missing_lca_row() {
  [[ "${BANNER_LCA_ROW}" == "none" ]] && return 0
  have lca && return 0
  row "'lca' NOT on PATH" "run them as ${REPO_ROOT}/bin/lca"
  [[ "${BANNER_LCA_ROW}" == "path" ]] && return 0
  row "Install the name" "sudo ${REPO_ROOT}/setup.sh"
}

banner_installing() {
  BANNER_LCA_ROW=none   # setup is running; it installs the symlink itself
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
  BANNER_LCA_ROW=none   # this banner already says "sudo setup.sh"
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

# model_missing — a POSITIVE answer that the configured model is not on this
# box. Anything else (no curl, no answer, an unparseable body) is "could not
# tell" and returns non-zero.
#
# That asymmetry is deliberate. A banner that cried "not ready" on a slow box,
# at every login, would be worse than one that says nothing — but "ready" is
# the strongest claim this file makes and it currently means only that the API
# answered. An engine with no model answers /api/version perfectly and then
# fails every question the next line invites. That is not hypothetical: setup
# no longer dies when the model pull fails, deliberately, so the rest of the
# stack can finish installing; and on a hand-installed box there is no
# first-boot log for install_state to read, so 'ready' is decided here alone.
model_missing() {
  have curl || return 1
  local tags
  tags="$(quick curl -fsS "$(ollama_url)/api/tags" || true)"
  [[ "${tags}" == *'"models"'* ]] || return 1
  grep -qF "\"${MODEL_NAME}\"" <<<"${tags}" && return 1
  return 0
}

banner_no_model() {
  BANNER_LCA_ROW=path   # this banner ends with "Finish it: sudo setup.sh"
  headline "engine running, but model ${MODEL_NAME} is NOT downloaded"
  row "Nothing can answer" "until it is pulled — this is a download, not a bug"
  row "Finish it" "sudo ${REPO_ROOT}/setup.sh"
  row "Details" "lca check"
  offline_row
  printf '\n'
}

banner_ready() {
  local addr url hint
  if model_missing; then
    banner_no_model
    return 0
  fi
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
  chat_down_row
  chat_stale_row
  coding_row
  row "Ask right here" "lca ask \"why is this box slow?\""
  row "All commands" "lca help"
  offline_row
  printf '\n'
}

# chat_down_row — the chat app is enabled and not answering at all.
#
# The row below this one warns when the chat is up but running an older
# assistant. Not warning when it is simply DOWN covered the milder fault and
# left the louder one silent: the headline still says "ready" and the line
# above hands out a phone URL that answers nothing. Measured by stopping the
# container — 'lca check' reported it twice, with the command to fix it, and
# the one screen you get without asking still said ready and offered the link.
#
# A direct bounded curl rather than webui_responds(), which is the same probe
# with --max-time 3: this file's rule is that every probe goes through quick()
# at 2 seconds, and quick() runs 'timeout', which cannot wrap a shell function.
# 'have curl' first so a box without curl is never told its chat is down on the
# strength of a missing binary.
chat_down_row() {
  [[ "${ENABLE_WEBUI}" == "true" && "${SKIP_DOCKER}" != "true" ]] || return 0
  have curl || return 0
  quick curl -fsS "$(webui_url)/health" >/dev/null 2>&1 && return 0
  # 18 characters: row() pads labels to 20, so a longer one eats its own
  # separator and the value no longer lines up with every other row. "Chat is
  # NOT answering" was 21 and did exactly that.
  row "Chat NOT answering" "sudo lca webui start   ·   then: lca check"
}

# chat_stale_row — the chat app is healthy AND running an older assistant than
# this repo's.
#
# The assistant's instructions are baked into the container when it is created,
# so 'git pull' does not reach a running one and nothing restarts it. Every
# other line of this banner is true on such a box: the engine is up, the model
# is pulled, the URL works. The only real bug report this project has ever had
# was exactly that box, twice — and "ready" plus a phone URL is the last thing
# its owner saw before asking the chat to build an app and getting a JSON blob
# back. 'lca check' knew. 'lca test' knew. The one screen you get without
# asking for it did not.
#
# Two seconds, not the fifteen a health check may take: the banner runs on
# every SSH login, and a probe that hangs here hangs the login itself. A
# missing line costs nothing — webui_prompt_drifted answers "no" whenever it
# could not look.
chat_stale_row() {
  [[ "${ENABLE_WEBUI}" == "true" && "${SKIP_DOCKER}" != "true" ]] || return 0
  if LCA_INSPECT_TIMEOUT=2 webui_prompt_drifted; then
    row "Chat is OUT OF DATE" "it answers with an older assistant — sudo lca apply"
  fi
}

# coding_row — the one command on this box that writes files.
#
# Every other line of the ready banner points at something that cannot. The
# chat URL is a text box with no filesystem. 'lca ask' is one-shot text. Both
# are useful and neither is the product. So the banner named the chat, named
# the one-shot, named 'lca help', and never once named the coding agent — while
# "Ask right here" sat there looking exactly like the thing to try if what you
# want is code.
#
# That is the same bug as chat_stale_row above, one layer earlier: this is the
# screen the one real bug reporter was reading when they picked the wrong door.
# A banner nobody asked for is the only documentation everyone reads, and it
# has to name the thing the box is for.
#
# Placed directly above "Ask right here" so the two sit adjacent: one edits your
# files, one answers a question. Read together the difference is obvious, which
# it is not when only one of them is on screen.
coding_row() {
  # Not installed → say so rather than staying quiet, for the reason
  # model_missing() gives at length: "ready" is the strongest claim this file
  # makes, and a box that cannot run the coding agent has not earned it. The
  # command matches run-agent.sh's own message, so the two cannot drift.
  if [[ -x "$(aider_bin)" ]]; then
    row "Write code here" "cd ~/my-project && lca   (edits real files)"
  else
    row "Coding agent MISSING" "${REPO_ROOT}/scripts/install_python.sh"
  fi
}

# offline_row — the kill switch is invisible once engaged, and every download
# failing for no stated reason is a genuinely baffling half hour.
offline_row() {
  if [[ "$(netmode_state 2>/dev/null || echo online)" == "offline" ]]; then
    row "Internet" "OFF (kill switch) — sudo lca online to restore"
  fi
}

main() {
  case "${1:-}" in
    --install) install_motd; return 0 ;;
    -h|--help)
      # The header block above is the help text, as everywhere else here.
      sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      return 0
      ;;
    "") ;;
    # Anything else printed the banner and said nothing — so a typo'd
    # '--instal' silently did not install the banner and looked like it had.
    # run-parts invokes this with no arguments, so it never reaches here.
    *) printf 'Unknown option: %s (try: %s --help)\n' "$1" "${BASH_SOURCE[0]}" >&2; return 1 ;;
  esac
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
  elif [[ "${state}" == "stalled" ]] && ! product_installed; then
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

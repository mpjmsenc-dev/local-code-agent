#!/usr/bin/env bash
# tests/test-lib.sh — automated unit tests for scripts/lib.sh and the tune
# ladder. Pure-logic tests only: no root, no network, no services touched,
# so they run anywhere (CI, the build VM, a droplet).
#
# Usage: tests/test-lib.sh   (exit 0 = all passed, 1 = something failed)
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"

# Everything bin/lca dispatches to, i.e. every script that runs in the USER's
# directory and speaks to them directly. Several gates below share it, so it
# lives here rather than in whichever section happened to need it first.
# run-agent.sh is absent on purpose: it forwards to aider.
LCA_TARGETS=( check-system.sh backup.sh restore.sh update.sh update-model.sh
              webui.sh netmode.sh scripts/tune.sh scripts/apply.sh
              scripts/ask.sh scripts/logs.sh scripts/speed.sh
              scripts/selftest.sh )

FAILED=0
t_ok()   { printf '%s\n' "ok   - $*"; }
t_fail() { printf '%s\n' "FAIL - $*"; FAILED=$((FAILED+1)); }
check() {
  local desc="$1"; shift
  if "$@"; then t_ok "${desc}"; else t_fail "${desc}"; fi
}

# Work in a throwaway copy so the real .env is never touched.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/scripts"
cp "${REPO}/scripts/lib.sh" "${SANDBOX}/scripts/"
cp "${REPO}/.env.example" "${SANDBOX}/"

# shellcheck source=../scripts/lib.sh
source "${SANDBOX}/scripts/lib.sh"

# Nothing in this suite may ask the REAL docker daemon anything.
#
# Three times on this branch a test has passed on a machine with the chat app
# running and failed in CI, which has no container — or the reverse. Every time
# the cause was the same: a helper stubbed one docker-shaped probe and left
# another reachable, so its answer came from the environment rather than the
# fixture, and 'make gates' green here meant nothing about CI. The most recent
# was a commit whose own message warned about this class.
#
# So the two probes guarded_ports consults are overridden here, immediately
# after lib.sh is sourced, with versions that answer "no" and RECORD the call.
# Every test that needs a real answer stubs them locally, as they already do;
# anything that reaches these is by definition asking the environment, and the
# final gate below fails on it by name. Deterministic first, and loud about the
# thing that used to be silent.
#
# In-process only. Tests that run a script as a subprocess get lib.sh's real
# functions, which is right — those exercise the script, and they carry their
# own stubs.
# ...and nothing in this suite may call a command that does not exist.
#
# A gate whose helper is defined BELOW the 'check' line that runs it compares
# nothing: the function is not yet defined, the call fails, and inside a
# process substitution or a subshell that failure is silent. Measured, with
# exactly that mistake re-introduced:
#
#   tests/test-lib.sh: line 2024: prompt_lca_commands: command not found
#   RESULT: all tests passed
#
# Green suite, green CI, and a gate comparing zero things. I shipped that
# mistake an hour ago and only found it by mutating the code it was supposed
# to watch — which works, and only works if you remember to do it.
#
# bash calls command_not_found_handle for any unqualified name it cannot
# resolve, so this catches the whole class at the moment it happens rather
# than the next time somebody thinks to check. A path that does not exist
# ('/nonexistent/aider', which several fixtures use on purpose) does NOT come
# through here — that is an exec failure, not a lookup failure — so the
# deliberate stubs stay deliberate.
LCA_MISSING_CMD_LOG="${SANDBOX}/commands-that-do-not-exist"
: > "${LCA_MISSING_CMD_LOG}"
command_not_found_handle() {
  printf '%s\n' "${1:-}" >> "${LCA_MISSING_CMD_LOG}"
  printf 'test suite called a command that does not exist: %s\n' "${1:-}" >&2
  return 127
}

LCA_UNSTUBBED_LOG="${SANDBOX}/unstubbed-docker-calls"
: > "${LCA_UNSTUBBED_LOG}"
webui_container_running() {
  printf 'webui_container_running\n' >> "${LCA_UNSTUBBED_LOG}"; return 1
}
webui_container_env() {
  printf 'webui_container_env %s\n' "${1:-}" >> "${LCA_UNSTUBBED_LOG}"; return 1
}

# make_stub_dir DIR — create DIR for PATH stubs, and put a 'sudo' in it.
#
# A test that runs a script as a subprocess stubs commands by putting a fake
# one first on PATH. That works right up to the moment the script escalates,
# and then it silently stops working: sudo REPLACES the caller's PATH with
# sudoers' secure_path, so the fake is not merely deprioritised, it is
# invisible. Measured on this box, with a stub first on PATH:
#
#   $ command -v docker
#   /tmp/.../stub/docker
#   $ sudo -n sh -c 'command -v docker; echo "PATH=$PATH"'
#   /usr/bin/docker
#   PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
#
# So every lib.sh helper of the shape "try it directly, then try it as root"
# — docker_daemon_reachable, webui_container_exists, webui_container_running,
# apt_get — reaches the REAL command on its second attempt, and the test's
# answer comes from the machine instead of the fixture.
#
# Whether that happens depends on who runs the suite, which is why it hid: as
# root, as_root runs the command itself and PATH is honoured, so it passes
# here and on any developer box. CI's runner is a non-root passwordless
# sudoer, takes the sudo branch, and finds a working Docker daemon. That is
# the whole of CI run 31140625333 — 'lca logs webui' was handed a docker that
# fails everything, reported the daemon reachable anyway, and the gate for a
# real fixed defect failed on the one machine that mattered.
#
# The pass-through below makes the two paths agree: sudo's own options are
# consumed, and the command runs with PATH intact so it resolves to the same
# stub the direct call got. It grants no privilege and is not trying to — the
# question these tests ask is "what does the script do when this command
# fails", and that answer must not depend on the account running them.
#
# It also keeps 'sudo -n true' succeeding, so can_root_now stays true and the
# escalating branch is genuinely exercised rather than skipped.
make_stub_dir() {
  local dir="$1"
  mkdir -p "${dir}"
  cat > "${dir}/sudo" <<'STUB'
#!/bin/sh
# Consume sudo's own options, then run the rest with PATH left alone.
while [ $# -gt 0 ]; do
  case "$1" in
    -u|-g|-p|-C|-r|-t|-T) shift 2 ;;         # these take a value
    --) shift; break ;;
    -*) shift ;;                             # -n, -E, -H, -S, -k, ...
    *) break ;;
  esac
done
exec "$@"
STUB
  chmod +x "${dir}/sudo"
}

echo "# load_env creates .env from .env.example and applies defaults"
load_env
check ".env auto-created" test -f "${SANDBOX}/.env"
check "default MODEL_NAME" test "${MODEL_NAME}" = "qwen2.5-coder:7b"
check "default OLLAMA_CONTEXT_LENGTH" test "${OLLAMA_CONTEXT_LENGTH}" = "8192"
check "default AUTO_TUNE" test "${AUTO_TUNE}" = "true"
check "default BACKUP_KEEP" test "${BACKUP_KEEP}" = "7"
check "default AIDER_CONVENTIONS" test "${AIDER_CONVENTIONS}" = "true"
check "default BACKUP_SCHEDULE" test "${BACKUP_SCHEDULE}" = "*-*-* 03:30:00"
check "default SKIP_TAILSCALE" test "${SKIP_TAILSCALE}" = "false"

echo "# a port that is not a port must say so, not become an uncloseable gap"
# Measured with WEBUI_PORT=abc, a plain typo: netmode's own extractor refuses
# it and guards 3000, while guarded_ports asked for "WebUI abc" — so
# inbound_guard_uncovered reported the guard stale, 'lca check' said "run sudo
# lca apply", apply re-applied the same guard and reported success, and the
# next check said it again. A loop with no exit, in which the word "abc" never
# appeared.
port_is() { if valid_port "$2"; then [[ "$1" == valid ]]; else [[ "$1" == bad ]]; fi; }
check "a normal port is valid"            port_is valid 3000
check "1 is valid"                        port_is valid 1
check "65535 is valid"                    port_is valid 65535
check "0 is not a port"                   port_is bad   0
check "65536 is not a port"               port_is bad   65536
check "a word is not a port"              port_is bad   abc
check "empty is not a port"               port_is bad   ""
# ...and guarded_ports must leave out what it cannot guard, rather than asking
# for a gap that can never be closed. The message about the real fault belongs
# to check-system.sh, which names the setting.
guarded_without() {   # WEBUI_PORT value -> the list guarded_ports produces
  bash -c '
    source "$1" >/dev/null 2>&1
    load_env
    ENABLE_WEBUI=true; WEBUI_PORT="$2"; OLLAMA_HOST=127.0.0.1:11434
    webui_container_running() { return 1; }
    webui_container_env() { return 1; }
    guarded_ports || true' _ "${REPO}/scripts/lib.sh" "$2" 2>/dev/null
}
check "a real port is asked for" \
  grep -qF "WebUI 3000" <<<"$(guarded_without _ 3000)"
check "a port that is not a port is not asked for" \
  test -z "$(guarded_without _ abc | grep WebUI)"
check "...while the other service is still guarded" \
  grep -qF "Ollama 11434" <<<"$(guarded_without _ abc)"
# And the health check must name the setting, or the user is left with a
# stack that fails in three places and never says why.
check_names_a_bad_port() {
  local body
  body="$(sed 's/#.*//' "${REPO}/check-system.sh")"
  grep -qE 'valid_port "[$][{]WEBUI_PORT[}]"' <<<"${body}" || {
    echo "check-system.sh does not validate WEBUI_PORT" >&2; return 1; }
  grep -qE 'valid_port "[$][{]OLLAMA_PORT_SEEN[}]"' <<<"${body}" || {
    echo "check-system.sh does not validate the port OLLAMA_HOST resolves to" >&2; return 1; }
  grep -q 'is not a port number' <<<"${body}" || {
    echo "check-system.sh never says a port is not a port number" >&2; return 1; }
}
check "'lca check' names a port that is not a port" check_names_a_bad_port

echo "# 'sudo exists' is not 'I can become root', and one of those is a probe"
# can_root answers "is the sudo binary installed", which is right for a step
# allowed to ask for a password and wrong for a probe. The difference produced
# a false SECURITY alarm: 'lca check' run by a user who is not a sudoer took
# the can_root branch, ran 'sudo nft list table', got nothing, and reported
# "inbound guard NOT loaded — WebUI/Ollama ports may be publicly reachable" on
# a machine whose guard may be perfectly loaded — then advised a sudo command
# that user cannot run either. Measured with a freshly created account.
can_root_now_is_stricter() {
  # Both are true for root, which is the only account this suite can speak for.
  can_root     || { echo "can_root is false as $(id -un)" >&2; return 1; }
  can_root_now || { echo "can_root_now is false as $(id -un)" >&2; return 1; }
  # The distinction has to be in the code, not just in the comment: can_root
  # must not consult sudo -n, and can_root_now must.
  local lib="${REPO}/scripts/lib.sh" body
  body="$(sed 's/#.*//' "${lib}")"
  awk '/^can_root\(\) \{/ { inb = 1 } inb && /sudo -n/ { bad = 1 } inb && /^\}/ { exit }
       END { exit bad }' <<<"${body}" || {
    echo "can_root now depends on sudo -n, which makes it useless for actions" >&2
    return 1
  }
  awk '/^can_root_now\(\) \{/ { inb = 1 } inb && /sudo -n/ { found = 1 } inb && /^\}/ { exit }
       END { exit !found }' <<<"${body}" || {
    echo "can_root_now does not actually test whether sudo works" >&2
    return 1
  }
}
check "can_root_now asks whether root is reachable, not whether sudo exists" \
  can_root_now_is_stricter
# ...and EVERY probe must use it, not just the one that was reported.
#
# The inbound guard was fixed alone, and the same defect was sitting in four
# more places, one of them worse than the original. Under a real terminal an
# interactive sudo does not fail — it WAITS. Measured with an account that is
# not a sudoer: the login banner printed two lines and then sat on "[sudo]
# password for ..." indefinitely, on every SSH login, because the bounding
# 'timeout' runs UNDER sudo and so never gets to start. 'lca check' did the
# same thing twice and then reported a healthy daemon as "not responding" and
# a running chat app as one that "does not exist". Fixed: banner 0.10s.
#
# Extraction is prefix-matching, not regex, so a '{' or '(' in a name cannot
# quietly turn into an interval or a group and match nothing.
probe_region() {  # FILE START_PREFIX END_PREFIX
  sed 's/#.*//' "${REPO}/$1" | awk -v s="$2" -v e="$3" '
    !inb && substr($0, 1, length(s)) == s { inb = 1; print; next }
    inb  && substr($0, 1, length(e)) == e { exit }
    inb'
}
probes_use_the_stricter_test() {
  local bad=0 spec file start end label body
  # Single-caller probes, which therefore know their own answer.
  local -a regions=(
    "netmode.sh|inbound_loaded() {|}|netmode's inbound_loaded"
    "netmode.sh|table_loaded() {|}|netmode's table_loaded"
    "check-system.sh|step \"Docker\"|step \"|'lca check' Docker step"
    "check-system.sh|step \"Open WebUI\"|step \"|'lca check' Open WebUI step"
    "check-system.sh|step \"Inbound guard\"|step \"|'lca check' inbound-guard step"
  )
  for spec in "${regions[@]}"; do
    IFS='|' read -r file start end label <<<"${spec}"
    body="$(probe_region "${file}" "${start}" "${end}")"
    # Anti-vacuity: a renamed or deleted region extracts nothing, and an empty
    # body would sail through the "no bare can_root" test below.
    grep -q 'can_root_now' <<<"${body}" || {
      printf '%s does not escalate with can_root_now (region empty or renamed?)\n' \
        "${label}" >&2
      bad=1
      continue
    }
    # can_root_now CONTAINS can_root, so presence is not enough — a leftover
    # bare call beside a fixed one is exactly how this defect survived the
    # first fix. Match can_root not followed by '_'.
    if grep -qE 'can_root([^_]|$)' <<<"${body}"; then
      printf '%s still has a bare can_root: %s\n' "${label}" \
        "$(grep -nE 'can_root([^_]|$)' <<<"${body}" | head -1)" >&2
      bad=1
    fi
  done
  return "${bad}"
}
check "no probe asks 'is sudo installed' — it would wait on the password" \
  probes_use_the_stricter_test

# The shared docker helpers are the other case: the SAME function is a
# reporter's question inside the login banner and an action's question inside
# 'lca backup', so it must not decide for itself. Deciding inside the helper
# has now shipped wrong in both directions — can_root everywhere hung the
# banner, can_root_now everywhere made 'lca backup' skip the chat history and
# call a healthy daemon "not usable". They delegate to root_for_probe; the
# caller sets LCA_MAY_PROMPT, and silence means the strict answer.
shared_probes_let_the_caller_decide() {
  local bad=0 name body
  for name in webui_container_env docker_daemon_reachable webui_container_exists; do
    body="$(probe_region scripts/lib.sh "${name}() {" "}")"
    grep -q 'root_for_probe' <<<"${body}" || {
      printf '%s does not delegate to root_for_probe (region empty or renamed?)\n' \
        "${name}" >&2
      bad=1
      continue
    }
    # Deciding for itself, in either direction, is the defect.
    if grep -qE 'can_root' <<<"${body}"; then
      printf '%s decides the caller question for itself: %s\n' "${name}" \
        "$(grep -nE 'can_root' <<<"${body}" | head -1)" >&2
      bad=1
    fi
  done
  # ...and the switch itself must offer both answers and default to the strict
  # one. A default of true would make every future reporter hang by omission.
  body="$(probe_region scripts/lib.sh 'root_for_probe() {' '}')"
  grep -qE 'can_root([^_]|$)' <<<"${body}" || {
    echo "root_for_probe has no interactive answer, so no action can opt in" >&2
    bad=1
  }
  grep -q 'can_root_now' <<<"${body}" || {
    echo "root_for_probe has no strict answer, which is the one that matters" >&2
    bad=1
  }
  grep -qE '^: *"\$\{LCA_MAY_PROMPT:=false\}"' "${REPO}/scripts/lib.sh" || {
    echo "LCA_MAY_PROMPT does not default to false — silence must mean strict" >&2
    bad=1
  }
  return "${bad}"
}
check "the shared docker probes let the caller say whether it may ask" \
  shared_probes_let_the_caller_decide

# And the opt-in has to be present where it was measured to matter. backup.sh
# is the one that loses data without it: no LCA_MAY_PROMPT, and a backup taken
# without sudo by an ordinary sudoer contains no accounts and no chat history.
actions_opt_in_to_prompting() {
  local bad=0 f
  for f in backup.sh restore.sh scripts/apply.sh scripts/install_webui.sh scripts/install_docker.sh; do
    grep -qE '^LCA_MAY_PROMPT=true' "${REPO}/${f}" || {
      printf '%s acts but never opts in — its docker probes will refuse instead of asking\n' \
        "${f}" >&2
      bad=1
    }
  done
  # The reporters must NOT: this is the whole point of the default.
  for f in scripts/motd.sh check-system.sh; do
    if grep -qE '^LCA_MAY_PROMPT=true' "${REPO}/${f}"; then
      printf '%s reports, but opted into a password prompt\n' "${f}" >&2
      bad=1
    fi
  done
  return "${bad}"
}
check "scripts that act opt in; scripts that only report do not" \
  actions_opt_in_to_prompting

# The other side of the same rule. select_docker and run_reader serve typed
# commands — 'webui.sh start', 'lca logs' — so they ARE allowed to ask for a
# password; one that refused where it used to work would be the worse trade.
# What they may not do is ask silently. Measured: 'lca webui status' printed
# nothing whatsoever and then sat on "[sudo] password for ...", and 'lca logs'
# did the same under a bare section header. Two properties, both leaving a
# later author free to drop the interactive path entirely if they prefer:
#   - the passwordless attempt comes FIRST, so the common case never prompts;
#   - nothing escalates interactively before saying so.
sudo_asks_out_loud() {
  local bad=0 spec file start label body
  local -a regions=(
    "webui.sh|select_docker() {|select_docker"
    "scripts/lib.sh|run_reader() {|run_reader"
  )
  for spec in "${regions[@]}"; do
    IFS='|' read -r file start label <<<"${spec}"
    body="$(probe_region "${file}" "${start}" "}")"
    grep -q 'can_root_now' <<<"${body}" || {
      printf '%s never tries the passwordless path (renamed?)\n' "${label}" >&2
      bad=1
      continue
    }
    # can_root_now CONTAINS can_root, hence the [^_] in every bare-call match.
    # The announcement is necessarily INSIDE the 'if can_root' branch, so what
    # has to be ordered is the escalation, not the test: once a bare can_root
    # opens the interactive path, no as_root may run before something is said.
    # The announcement must be matched as a CALL to lib.sh's helper, anchored
    # at the start of the statement. A bare /info |warn / also matches
    # "docker info >/dev/null", which is the first line of select_docker — so
    # that version passed with the announcement deleted, for the wrong reason.
    # Caught by mutating it; a gate that has not been made to fail is decoration.
    awk '/can_root_now/            { now = 1; next }
         /can_root([^_]|$)/        { if (!now) early = 1; pending = 1 }
         /^[[:space:]]*(info|warn|ok|err) / { said = 1 }
         /as_root/ && pending && !said { silent = 1 }
         END { exit (early || silent) ? 1 : 0 }' <<<"${body}" || {
      printf '%s escalates interactively before trying sudo -n, or without saying so\n' \
        "${label}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "nothing asks for a password with nothing on screen" sudo_asks_out_loud

echo "# a number that is not a number must be named, not absorbed"
# Each of these fails quietly or confusingly, never as itself. Measured:
#   OLLAMA_CONTEXT_LENGTH=abc  Ollama warns once in its own log and runs at the
#     model default (0) while run-agent tells aider 8192 — silent truncation,
#     and the drop-in matches .env so the drift check is happy.
#   BACKUP_KEEP=abc            backups_to_prune refuses to act, so retention
#     never runs and the disk fills.
#   LCA_EDIT_FORMAT=whole-file 'lca' dies in forty lines of aider usage text.
numeric_settings_are_checked() {
  local body
  body="$(sed 's/#.*//' "${REPO}/check-system.sh")"
  # The LIST it iterates, not just a mention of the name: the first version of
  # this grepped the whole file, and every one of these also appears in the
  # message printed about it — so dropping a setting from the loop left the
  # gate green.
  local k loop
  loop="$(grep -oE 'for setting in [A-Z_ ]+; do' <<<"${body}" \
    | grep OLLAMA_CONTEXT_LENGTH | head -1)"
  [[ -n "${loop}" ]] || {
    echo "check-system.sh no longer loops over the numeric settings" >&2; return 1; }
  for k in OLLAMA_CONTEXT_LENGTH LCA_ASK_TOKENS BACKUP_KEEP; do
    grep -qF "${k}" <<<"${loop}" || {
      printf 'check-system.sh does not check %s\n' "${k}" >&2; return 1; }
  done
  grep -q 'is not a number' <<<"${body}" || {
    echo "check-system.sh never says a number is not a number" >&2; return 1; }
  # The message has to say what actually happens, or it is a scolding rather
  # than a diagnosis.
  grep -q 'silently truncated' <<<"${body}" || {
    echo "the context-length message does not say what goes wrong" >&2; return 1; }
}
check "'lca check' names a setting that should be a number and is not" \
  numeric_settings_are_checked
# ...and the headline command warns about an edit format aider will reject,
# before aider answers with its usage text.
run_agent_warns_on_an_odd_edit_format() {
  local body
  body="$(sed 's/#.*//' "${REPO}/run-agent.sh")"
  grep -q 'LCA_EDIT_FORMAT' <<<"${body}" || {
    echo "run-agent.sh no longer mentions LCA_EDIT_FORMAT" >&2; return 1; }
  grep -qE 'warn "LCA_EDIT_FORMAT' <<<"${body}" || {
    echo "run-agent.sh does not warn about an edit format it does not document" >&2
    return 1
  }
  # Warned about, never refused: aider accepts formats this project does not
  # document, and someone may want one.
  grep -qE 'die "LCA_EDIT_FORMAT' <<<"${body}" && {
    echo "run-agent.sh refuses an edit format instead of warning" >&2; return 1; }
  return 0
}
check "'lca' explains an edit format aider will reject" \
  run_agent_warns_on_an_odd_edit_format

echo "# a switch takes two words, and anything else silently means off"
# Everything in this project compares a switch against the literal string
# "true", so AUTO_TUNE=yes does not mean on — it turns the headline feature off
# and says nothing. Measured before this: 'lca tune --dry-run' on a box whose
# .env said AUTO_TUNE=yes printed "AUTO_TUNE=false — a real run would keep the
# manual pin", asserting a value the file does not contain.
bool_is() { if valid_bool "$2"; then [[ "$1" == valid ]]; else [[ "$1" == bad ]]; fi; }
check "true is a switch value"    bool_is valid true
check "false is a switch value"   bool_is valid false
check "yes is not"                bool_is bad   yes
check "1 is not"                  bool_is bad   1
check "TRUE is not"               bool_is bad   TRUE
check "empty is not"              bool_is bad   ""
# The list of switches comes from .env.example, so a new one is covered the day
# it ships rather than the day someone remembers to add it here.
check "the switch list is read from .env.example" \
  test "$(boolean_settings | wc -l)" -ge 5
check "AUTO_TUNE is one of them" \
  grep -qx AUTO_TUNE <<<"$(boolean_settings)"
check "a port setting is NOT treated as a switch" \
  test -z "$(boolean_settings | grep -x WEBUI_PORT)"
# ...and both reporters must use it. tune.sh must quote what .env actually
# holds rather than asserting 'false' about a file that says something else.
switches_are_reported() {
  grep -q 'valid_bool' "${REPO}/check-system.sh" || {
    echo "check-system.sh does not validate the on/off settings" >&2; return 1; }
  local tune; tune="$(sed 's/#.*//' "${REPO}/scripts/tune.sh")"
  grep -qF 'AUTO_TUNE=false — a real run' <<<"${tune}" && {
    echo "tune.sh still reports AUTO_TUNE=false regardless of what .env says" >&2; return 1; }
  return 0
}
check "a mistyped switch is named by the tools that read it" switches_are_reported

echo "# no probe may reach for sudo without checking it is there first"
# as_root DIES when there is neither root nor sudo. That is right for a step
# that cannot proceed without root, and wrong for a PROBE whose whole job is to
# answer "can I talk to docker?" — there, the honest answer is "no" and the
# caller has a graceful path already written for it.
#
# Two scripts fell through to a bare 'as_root docker info': install_docker.sh,
# in the branch that exists precisely to warn and carry on without Docker, and
# install_webui.sh, one line above the die() that tells the reader what to do.
# On a host with neither root nor sudo both died with "Root privileges needed
# for: docker info" instead. lib.sh's docker_daemon_reachable checks can_root
# first; check-system.sh has carried a comment saying exactly this for a while,
# and it was the only one that did.
sudo_probes_are_guarded() {
  local hits bad=0 line file lno window
  # Comment lines dropped BEFORE the emptiness guard, not after. The
  # paragraphs above explaining this rule quote the idiom, so filtering them
  # out later left the guard counting them: the first version of this passed
  # while every real call site had been renamed away, which is precisely the
  # vacuous pass it is supposed to prevent.
  hits="$(grep -rn --include='*.sh' 'as_root docker info' "${REPO}" \
    | grep -v '/tests/' \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [[ -n "${hits}" ]] || {
    echo "no 'as_root docker info' call site anywhere — this gate stopped watching" >&2
    return 1
  }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    file="${line%%:*}"
    lno="${line#*:}"; lno="${lno%%:*}"
    # The guard used to have to be on the SAME line, which was true only while
    # every call site was a one-liner. Two shapes have since broken that
    # without weakening anything: root_for_probe (the caller decides, see
    # lib.sh) and webui.sh's three-rung ladder, where the guard opens an
    # if/elif and the call sits a line or two inside it. So look at the call
    # line and the four above it — still far too tight for an unguarded
    # as_root, which is the thing that die()s, to hide in.
    window="$(sed -n "$(( lno > 4 ? lno - 4 : 1 )),${lno}p" "${file}" | sed 's/#.*//')"
    grep -qE 'can_root|root_for_probe' <<<"${window}" || {
      printf 'unguarded sudo probe: %s\n' "${line}" >&2
      bad=1
    }
  done <<<"${hits}"
  return "${bad}"
}
check "every 'as_root docker info' probe is guarded against die()" \
  sudo_probes_are_guarded

echo "# git_identity() — aider's product is commits, and a commit needs an author"
# Without a global identity aider still commits, stamping the work with a
# placeholder ('Your Name <you@example.com>' — measured), while a 'git commit'
# the user runs themselves in that same project refuses outright: "Author
# identity unknown ... Please tell me who you are". Measured on a host whose
# hostname carries no domain, which is every fresh droplet. The chat's handover
# drops people into a brand-new git repo, so that is the first thing many of
# them try.
#
# Driven against a sandbox HOME, so it answers for a real 'git config --global'
# rather than for whatever the developer running the suite happens to have.
identity_in() {   # HOME dir -> the identity, or "none"
  bash -c '
    source "$1" >/dev/null 2>&1
    export HOME="$2"
    git_identity 2>/dev/null || echo none' _ "${REPO}/scripts/lib.sh" "$1" 2>/dev/null
}
GIT_ID_SB="${SANDBOX}/gitid"
rm -rf "${GIT_ID_SB}"; mkdir -p "${GIT_ID_SB}/none" "${GIT_ID_SB}/both" "${GIT_ID_SB}/half"
HOME="${GIT_ID_SB}/both" git config --global user.name  "Ada Lovelace"
HOME="${GIT_ID_SB}/both" git config --global user.email "ada@example.com"
# Half-configured is the interesting one: git needs BOTH, and reporting a name
# with no address as "identity: Ada Lovelace <>" would be a pass for a config
# that still cannot commit.
HOME="${GIT_ID_SB}/half" git config --global user.name  "Ada Lovelace"
check "a complete identity is reported" \
  test "$(identity_in "${GIT_ID_SB}/both")" = "Ada Lovelace <ada@example.com>"
check "no identity at all is reported as missing" \
  test "$(identity_in "${GIT_ID_SB}/none")" = "none"
check "a name with no email is still missing" \
  test "$(identity_in "${GIT_ID_SB}/half")" = "none"
# ...and both reporters must ask lib.sh, not re-derive it. install_git.sh looks
# at the SUDO_USER's config rather than root's, and a second copy of that rule
# is how one of them ends up reporting on the wrong account.
both_reporters_ask_lib() {
  local f bad=0
  for f in scripts/install_git.sh check-system.sh; do
    grep -q 'git_identity' "${REPO}/${f}" || {
      printf '%s no longer asks lib.sh for the git identity\n' "${f}" >&2
      bad=1
    }
    # An ASSIGNMENT from a git config substitution, not any mention of the
    # command: both files quote 'git config --global user.name ...' inside the
    # message that tells the reader how to fix it, and the first version of
    # this gate failed on its own advice text.
    if grep -vE '^[[:space:]]*#' "${REPO}/${f}" \
       | grep -qE '=[[:space:]]*"?\$\(.*git config'; then
      printf '%s reads the git config itself instead of asking lib.sh\n' "${f}" >&2
      bad=1
    fi
  done
  return "${bad}"
}
check "'lca check' and the installer share one idea of the git identity" \
  both_reporters_ask_lib

echo "# set_env_var -> load_env round-trip (update + append, no duplicates)"
set_env_var MODEL_NAME "qwen2.5-coder:14b"
set_env_var OLLAMA_CONTEXT_LENGTH 16384
set_env_var BRAND_NEW_KEY hello
load_env
check "updated key read back" test "${MODEL_NAME}" = "qwen2.5-coder:14b"
check "second updated key read back" test "${OLLAMA_CONTEXT_LENGTH}" = "16384"
check "appended key read back" test "${BRAND_NEW_KEY}" = "hello"
check "no duplicate MODEL_NAME lines" \
  test "$(grep -c '^MODEL_NAME=' "${SANDBOX}/.env")" -eq 1
set_env_var MODEL_NAME "qwen2.5-coder:7b"
load_env
check "second update round-trips too" test "${MODEL_NAME}" = "qwen2.5-coder:7b"

echo "# a .env write that FAILS must say why — sed's own error names nothing"
# Every caller outside load_env's back-fill was a bare 'set_env_var', so under
# 'set -e' a failed write ended the script with only
# "sed: couldn't flush <unknown>: No space left on device" to explain it.
# Measured on a full filesystem; the likeliest moment for it, too, since the
# disk fills with gigabyte models and 'lca model' is what you run to fix that.
#
# Driven against a REAL failing write, not a stub. The .env path is given a
# parent that is a regular file, so every write into it fails with ENOTDIR —
# the same shape as ENOSPC and, unlike an unwritable directory, it stops root
# too. A test that quietly skips on the runner it actually runs on is not a
# test, and the first version of this one did exactly that.
WRITE_SB="${SANDBOX}/envwrite"
rm -rf "${WRITE_SB}"; mkdir -p "${WRITE_SB}"
: > "${WRITE_SB}/notadir"
# '|| true' on the assignment, because the whole point is that the inner shell
# exits non-zero — and under errexit a command substitution's status becomes
# the assignment's, which aborted this suite at exactly this line.
WRITE_OUT="$(bash -c '
    set -uo pipefail
    source "$1"
    C_RED=""; C_RESET=""; C_YELLOW=""
    ENV_FILE="$2/notadir/.env"
    write_env_or_die MODEL_NAME new "Extra context."
    echo "REACHED-THE-LINE-AFTER"
  ' _ "${REPO}/scripts/lib.sh" "${WRITE_SB}" 2>&1)" || true
check "a failed .env write names the likely cause" \
  grep -q "full disk" <<<"${WRITE_OUT}"
check "...and promises the file is untouched" \
  grep -q "left exactly as it was" <<<"${WRITE_OUT}"
check "...and passes the caller's extra context through" \
  grep -q "Extra context." <<<"${WRITE_OUT}"
reached_after() { grep -q 'REACHED-THE-LINE-AFTER' <<<"${WRITE_OUT}"; }
not_reached_after() { ! reached_after; }
check "...and stops rather than carrying on" not_reached_after
# The file really is intact after a refusal — which is what the message
# promises, and the only reason it is safe to say "re-run once there is room".
printf 'MODEL_NAME=old\n' > "${WRITE_SB}/.env"
refuse_into() {
  bash -c '
    set -uo pipefail
    source "$1"; C_RED=""; C_RESET=""
    ENV_FILE="$2/.env"
    set_env_var MODEL_NAME "a\$(rm -rf /)b"
  ' _ "${REPO}/scripts/lib.sh" "${WRITE_SB}" >/dev/null 2>&1 || true
}
refuse_into
check "a refused write leaves .env byte for byte" \
  test "$(cat "${WRITE_SB}/.env")" = "MODEL_NAME=old"
# A value set_env_var refuses is already explained by set_env_var itself, so
# write_env_or_die must stop without inventing a second, different reason.
refused_value_is_not_re_explained() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"; C_RED=""; C_RESET=""
    ENV_FILE="$2/.env"
    write_env_or_die MODEL_NAME "a\$(rm -rf /)b"
    echo "REACHED-THE-LINE-AFTER"
  ' _ "${REPO}/scripts/lib.sh" "${WRITE_SB}" 2>&1)"
  grep -q 'Refusing to write' <<<"${out}" || {
    printf 'the refusal was not reported: %s\n' "${out}" >&2; return 1; }
  grep -q 'full disk' <<<"${out}" && {
    echo "a refused value was blamed on the disk" >&2; return 1; }
  grep -q 'REACHED-THE-LINE-AFTER' <<<"${out}" && {
    echo "a refused value did not stop the caller" >&2; return 1; }
  return 0
}
check "a refused value is reported once, not twice, and still stops" \
  refused_value_is_not_re_explained
# ...and nothing may go back to calling set_env_var bare. lib.sh's own
# back-fill is the exception: it tests the result to build its 'added' list.
no_bare_set_env_var() {
  local hits
  hits="$(grep -rn 'set_env_var' "${REPO}"/*.sh "${REPO}"/scripts/*.sh \
            "${REPO}"/deploy/*.sh "${REPO}/bin/lca" 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' \
          | grep -v 'scripts/lib.sh' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these write .env without explaining a failure (use write_env_or_die):\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "no script writes .env through a bare set_env_var" no_bare_set_env_var

echo "# confirm() auto-confirms when stdin is not a tty (unattended installs)"
check "confirm auto-yes on non-tty" confirm "test prompt?" </dev/null

echo "# ollama_url() rewrites listen addresses to connectable ones"
url_for() { OLLAMA_HOST="$1" ollama_url; }
check "plain host:port passes through" \
  test "$(url_for 127.0.0.1:11434)" = "http://127.0.0.1:11434"
check "0.0.0.0 rewritten to loopback" \
  test "$(url_for 0.0.0.0:11434)" = "http://127.0.0.1:11434"
check "http:// prefix stripped then re-added" \
  test "$(url_for http://127.0.0.1:11434)" = "http://127.0.0.1:11434"
check "trailing slash stripped" \
  test "$(url_for 127.0.0.1:11434/)" = "http://127.0.0.1:11434"
check "port-less 0.0.0.0 gets default 11434 (not port 80)" \
  test "$(url_for 0.0.0.0)" = "http://127.0.0.1:11434"
check "port-less host gets default 11434" \
  test "$(url_for 127.0.0.1)" = "http://127.0.0.1:11434"

echo "# ollama_bind_is_public() flags non-loopback binds"
# Subshells inherit the sourced functions, so scope OLLAMA_HOST per check.
is_public()  { ( OLLAMA_HOST="$1" ollama_bind_is_public ); }
not_public() { ! ( OLLAMA_HOST="$1" ollama_bind_is_public ); }
check "0.0.0.0:11434 bind is public"      is_public  "0.0.0.0:11434"
check "0.0.0.0 bare bind is public"       is_public  "0.0.0.0"
check "127.0.0.1:11434 is not public"     not_public "127.0.0.1:11434"
check "localhost:11434 is not public"     not_public "localhost:11434"
check "IPv6 :: wildcard is public"        is_public  "::"
check "IPv6 [::]:11434 is public"         is_public  "[::]:11434"
check "IPv6 [::1] loopback is not public" not_public "[::1]:11434"

echo "# detect_ram_gib() returns a sane positive integer"
RAM="$(detect_ram_gib)"
check "RAM is numeric and > 0" test "${RAM}" -gt 0

echo "# has_nvidia_gpu() runs cleanly and returns a boolean (no crash on CPU-only)"
gpu_ok() { has_nvidia_gpu; rc=$?; [[ "${rc}" -eq 0 || "${rc}" -eq 1 ]]; }
check "has_nvidia_gpu exits 0 or 1" gpu_ok

echo "# venv path helpers build paths inside the repo"
check "venv_dir under REPO_ROOT" test "$(venv_dir)" = "${SANDBOX}/${VENV_NAME}"
check "aider_bin under venv" test "$(aider_bin)" = "${SANDBOX}/${VENV_NAME}/bin/aider"

echo "# aider_token_budget() splits the Ollama window (prompt + reply), reply>=1024"
# Matches each tune-ladder context: reply is a quarter (min 1024), prompt the rest.
check "4096  -> 3072 1024"   test "$(aider_token_budget 4096)"  = "3072 1024"
check "8192  -> 6144 2048"   test "$(aider_token_budget 8192)"  = "6144 2048"
check "16384 -> 12288 4096"  test "$(aider_token_budget 16384)" = "12288 4096"
# input + output must always sum back to the window (no tokens lost/created).
budget_sums_to() { local in out; read -r in out < <(aider_token_budget "$1"); [[ $((in+out)) -eq "$1" ]]; }
check "budget sums to 4096"  budget_sums_to 4096
check "budget sums to 8192"  budget_sums_to 8192
check "budget sums to 16384" budget_sums_to 16384
# Corrupt/empty ctx must fall back to the 8192 default — never a zero budget.
check "empty ctx -> 8192 default"     test "$(aider_token_budget '')"    = "6144 2048"
check "non-numeric ctx -> 8192"       test "$(aider_token_budget abc)"   = "6144 2048"
check "absurdly small ctx -> 8192"    test "$(aider_token_budget 16)"    = "6144 2048"

echo "# load_env's \${VAR:-default} fallbacks apply when .env omits the keys"
# The checks above read a .env copied from .env.example, so they only prove the
# EXAMPLE's literals. These prove the fallbacks in lib.sh itself — load-bearing
# under 'set -u' when a user hand-trims .env (a supported degraded case).
TRIMMED="${SANDBOX}/trimmed"
mkdir -p "${TRIMMED}/scripts"
cp "${REPO}/scripts/lib.sh" "${TRIMMED}/scripts/"
# A .env with none of the newer keys, as an older/hand-edited install would have.
printf 'MODEL_NAME=qwen2.5-coder:7b\n' > "${TRIMMED}/.env"
# This MUST run in a separate bash process, with the keys cleared from the
# environment. lib.sh guards against double-sourcing (LCA_LIB_LOADED), so
# re-sourcing it in a subshell is a no-op and would keep THIS script's load_env
# (bound to a .env that does define the keys) — the assertion would then pass no
# matter what the fallbacks say. load_env also exports .env values (set -a), so
# they must be stripped with 'env -u' or the child would inherit them.
fallbacks_apply() {
  # SC2016 is intentional here: the ${...} must be expanded by the CHILD bash
  # (after it sources lib.sh), not by this script — hence the single quotes.
  # shellcheck disable=SC2016
  env -u BACKUP_KEEP -u BACKUP_SCHEDULE -u AIDER_CONVENTIONS bash -c '
    set -euo pipefail
    source "$1/scripts/lib.sh"
    load_env
    [[ "${BACKUP_KEEP}"      == "7" ]]              || { echo "BACKUP_KEEP=${BACKUP_KEEP}" >&2; exit 1; }
    [[ "${BACKUP_SCHEDULE}"  == "*-*-* 03:30:00" ]] || { echo "BACKUP_SCHEDULE=${BACKUP_SCHEDULE}" >&2; exit 1; }
    [[ "${AIDER_CONVENTIONS}" == "true" ]]          || { echo "AIDER_CONVENTIONS=${AIDER_CONVENTIONS}" >&2; exit 1; }
  ' _ "${TRIMMED}"
}
check "load_env fallbacks apply when .env omits the keys" fallbacks_apply

echo "# ollama_bind_is_public(): a bare ':PORT' binds ALL interfaces, not loopback"
bind_public()  { OLLAMA_HOST="$1" ollama_bind_is_public; }
bind_private() { ! OLLAMA_HOST="$1" ollama_bind_is_public; }
check "bare ':11434' is PUBLIC (all interfaces)" bind_public ":11434"
check "'0.0.0.0:11434' is public"                bind_public "0.0.0.0:11434"
check "'::' is public"                           bind_public "::"
check "'127.0.0.1:11434' stays private"          bind_private "127.0.0.1:11434"
check "'localhost:11434' stays private"          bind_private "localhost:11434"
check "'[::1]:11434' stays private"              bind_private "[::1]:11434"

echo "# env_file_is_inert(): a restored .env is EXECUTED, so it has to be read first"
# load_env sources .env. restore.sh copies one straight out of a tarball named
# on the command line and then calls load_env — as root, because a restore
# recreates docker volumes. docs/MIGRATE.md is built on carrying that tarball
# between machines, so "it is your own backup" is an assumption about a file
# that has been off-box and back. A '$(...)' in it ran with no prompt and no
# trace.
#
# Both directions matter. Too strict is a real cost here (a legitimate .env
# refused during a recovery), so the accepted cases include the shipped
# .env.example itself, a CRLF file — load_env strips CR before sourcing, and a
# validator that did not would reject what it accepts — and a file with no
# trailing newline.
EI_DIR="${SANDBOX}/envinert"
mkdir -p "${EI_DIR}"
ei_write() { printf '%b' "$2" > "${EI_DIR}/$1"; }
ei_inert()  { env_file_is_inert "${EI_DIR}/$1"; }
ei_reject() { ! env_file_is_inert "${EI_DIR}/$1"; }
ei_write plain    'A=1\nB="x y"\n\n# a comment\n'
ei_write crlf     'A=1\r\nB=2\r\n'
ei_write nonl     'A=1\nB=2'
ei_write exported 'export A=1\n'
check "a plain settings file is inert"        ei_inert  plain
check "the shipped .env.example is inert"     env_file_is_inert "${REPO}/.env.example"
check "a CRLF file is inert (load_env strips CR)" ei_inert crlf
check "no trailing newline still reads"       ei_inert  nonl
check "'export KEY=' is inert"                ei_inert  exported
# Assembled from variables rather than written literally: ShellCheck flags a
# '$(' or a backtick inside single quotes (SC2016) and this repo's lint gate is
# not negotiable. The bytes on disk are the same either way — and if one of
# these ever DID expand at write time, the fixture would stop containing a
# rejected construct and its own check below would fail.
ei_d='$'
ei_bt="$(printf '\140')"
ei_write cmdsub   "A=1\nB=${ei_d}(id)\n"
ei_write backtick "A=1\nB=${ei_bt}id${ei_bt}\n"
ei_write brace    "A=1\nB=${ei_d}{HOME}\n"
ei_write bareexp  "A=1\nB=${ei_d}HOME\n"
ei_write bare     'A=1\nid\n'
ei_write semi     'A=1; id\n'
ei_write andand   'A=1\nB=x && id\n'
ei_write pipe     'A=1\nB=x | id\n'
ei_write redirect 'A=1\nB=x > /etc/passwd\n'
ei_write cont     'A=1\\\nid\n'
check "command substitution is refused"       ei_reject cmdsub
check "backticks are refused"                 ei_reject backtick
check "a braced expansion is refused"         ei_reject brace
check "a bare expansion is refused"           ei_reject bareexp
check "a line that is just a command is refused" ei_reject bare
check "a second command after ';' is refused" ei_reject semi
check "a second command after '&&' is refused" ei_reject andand
check "a pipeline is refused"                 ei_reject pipe
check "a redirect is refused"                 ei_reject redirect
check "a continued line is refused"           ei_reject cont
check "a missing file is refused"             ei_reject no-such-file
# ...and restore.sh must actually consult it, BEFORE the load_env that would
# run the file. Order is the whole point: validating afterwards validates
# something that has already executed.
restore_validates_env_first() {
  # '[^#]*' so a future comment naming the helper cannot satisfy this the way
  # three earlier scanners in this file were satisfied by their own prose.
  awk '/^[[:space:]]*[^#]*env_file_is_inert/ { checked = NR }
       /^[[:space:]]*load_env[[:space:]]*$/ { loaded = NR; exit }
       END { exit !(checked > 0 && loaded > checked) }' "${REPO}/restore.sh"
}
check "restore.sh validates the backed-up .env before sourcing it" \
  restore_validates_env_first

# ...and the whole thing driven once, end to end, on a hostile archive. The
# checks above prove the validator and the call order separately; this proves
# what a user actually gets — because the property that matters is not "the
# function returned 1", it is "the payload did not run and the recovery
# continued anyway".
#
# apply.sh and install_webui.sh are stubbed: the real apply would reach
# 'netmode.sh harden' and load a firewall on the machine running the tests.
# Ollama and Docker are shimmed away so this costs no waiting.
RST_SB="${SANDBOX}/hostile"
mkdir -p "${RST_SB}/scripts" "${RST_SB}/backups" "${RST_SB}/stage"
cp "${REPO}/restore.sh" "${RST_SB}/restore.sh"
cp "${REPO}/.env.example" "${RST_SB}/.env.example"
cp "${REPO}/.env.example" "${RST_SB}/.env"
cp "${REPO}/scripts/lib.sh" "${RST_SB}/scripts/lib.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${RST_SB}/scripts/apply.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${RST_SB}/scripts/install_webui.sh"
chmod +x "${RST_SB}/restore.sh" "${RST_SB}"/scripts/*.sh
cat >> "${RST_SB}/scripts/lib.sh" <<'SHIM'
have() { [[ "$1" != docker && "$1" != ollama ]]; }
ensure_ollama_up_announced() { return 1; }
SHIM
RST_PAYLOAD="${RST_SB}/PWNED"
{
  printf 'MODEL_NAME=qwen2.5-coder:7b\n'
  printf 'WEBUI_PORT=3000\n'
  printf 'PWNED=%s(touch %s)\n' '$' "${RST_PAYLOAD}"
} > "${RST_SB}/stage/env"
printf 'NAME\tID\tSIZE\n' > "${RST_SB}/stage/models.txt"
tar czf "${RST_SB}/backups/local-code-agent-backup-20260101-000000.tar.gz" \
  -C "${RST_SB}/stage" . 2>/dev/null
hostile_rc=0
hostile_out="$(cd "${RST_SB}" && ./restore.sh </dev/null 2>&1)" || hostile_rc=$?

# The one that matters.
check "a hostile .env in a backup never executes" test ! -e "${RST_PAYLOAD}"
check "the live .env is left exactly as it was" \
  cmp -s "${RST_SB}/.env" "${REPO}/.env.example"
hostile_kept_a_copy() {
  [[ -f "${RST_SB}/.env.rejected" ]] && grep -qF 'PWNED' "${RST_SB}/.env.rejected"
}
check "the refused file is kept for the user to read" hostile_kept_a_copy
# Refusing is not failing: a recovery has to finish everything it still can.
hostile_restore_continued() {
  [[ "${hostile_rc}" == "0" ]] && grep -qF 'Restore complete' <<<"${hostile_out}"
}
check "the rest of the restore still ran" hostile_restore_continued

echo "# ...and a tarball with none of our parts is not a backup at all"
# Every component of a backup is optional on purpose, so an older or partial
# one restores what it has and skips the rest. With NONE of them present the
# script walked that whole optional path and finished with "Restore complete".
# Measured on a tarball containing one text file:
#
#   [warn] Backup contains no .env — skipping.
#   [warn] Backup contains no WebUI volume archive — skipping.
#   [warn] Backup contains no model list — skipping.
#   [ ok ] Restored settings are in effect.
#   [ ok ] Restore complete.
#   exit 0
#
# Three warnings nobody reads as fatal, two claims that were simply false — the
# "restored" settings were the current ones — and a success exit. Someone who
# points this at the wrong file is told their data came back, and may then
# delete the source it is still sitting in.
NOTB_SB="${SANDBOX}/notabackup"
mkdir -p "${NOTB_SB}/scripts" "${NOTB_SB}/stage"
cp "${REPO}/restore.sh" "${NOTB_SB}/restore.sh"
cp "${REPO}/.env.example" "${NOTB_SB}/.env.example"
cp "${REPO}/.env.example" "${NOTB_SB}/.env"
cp "${REPO}/scripts/lib.sh" "${NOTB_SB}/scripts/lib.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${NOTB_SB}/scripts/apply.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${NOTB_SB}/scripts/install_webui.sh"
chmod +x "${NOTB_SB}/restore.sh" "${NOTB_SB}"/scripts/*.sh
cat >> "${NOTB_SB}/scripts/lib.sh" <<'SHIM'
have() { [[ "$1" != docker && "$1" != ollama ]]; }
ensure_ollama_up_announced() { return 1; }
SHIM
echo 'hello' > "${NOTB_SB}/stage/hello.txt"
tar czf "${NOTB_SB}/other.tar.gz" -C "${NOTB_SB}/stage" . 2>/dev/null
notb_rc=0
notb_out="$(cd "${NOTB_SB}" && ./restore.sh ./other.tar.gz </dev/null 2>&1)" || notb_rc=$?
check "a tarball that is not ours is refused, not 'restored'" \
  test "${notb_rc}" != "0"
notb_said_why() { grep -qiE 'contains none of|is some other tarball' <<<"${notb_out}"; }
check "...and says what it looked for and where real backups live" notb_said_why
notb_claimed_success() { ! grep -qF 'Restore complete' <<<"${notb_out}"; }
check "...and never claims the restore completed" notb_claimed_success
check "...and leaves the live .env untouched" \
  cmp -s "${NOTB_SB}/.env" "${REPO}/.env.example"
# The half a careless fix breaks: a GENUINE backup missing some parts — an old
# one from before model lists existed — must still restore what it does carry.
PART_SB="${SANDBOX}/partialbackup"
mkdir -p "${PART_SB}/scripts" "${PART_SB}/stage"
cp "${REPO}/restore.sh" "${PART_SB}/restore.sh"
cp "${REPO}/.env.example" "${PART_SB}/.env.example"
cp "${REPO}/.env.example" "${PART_SB}/.env"
cp "${REPO}/scripts/lib.sh" "${PART_SB}/scripts/lib.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${PART_SB}/scripts/apply.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${PART_SB}/scripts/install_webui.sh"
chmod +x "${PART_SB}/restore.sh" "${PART_SB}"/scripts/*.sh
cat >> "${PART_SB}/scripts/lib.sh" <<'SHIM'
have() { [[ "$1" != docker && "$1" != ollama ]]; }
ensure_ollama_up_announced() { return 1; }
SHIM
printf 'MODEL_NAME=qwen2.5-coder:7b\nWEBUI_PORT=3000\n' > "${PART_SB}/stage/env"
tar czf "${PART_SB}/envonly.tar.gz" -C "${PART_SB}/stage" . 2>/dev/null
part_rc=0
part_out="$(cd "${PART_SB}" && ./restore.sh ./envonly.tar.gz </dev/null 2>&1)" || part_rc=$?
part_restored() {
  [[ "${part_rc}" == "0" ]] && grep -qF 'Restore complete' <<<"${part_out}"
}
check "a genuine backup missing some parts still restores the parts it has" \
  part_restored
# ...and a SECOND shape of partial backup, carrying a different single part.
# With only the env-only case above, narrowing the accepted list to 'env' alone
# passed the gate — a backup holding just a model list or just the volume would
# have been refused as "not ours" with nothing to notice. Caught by mutation.
printf 'NAME\tID\tSIZE\n' > "${PART_SB}/stage2-models.txt"
mkdir -p "${PART_SB}/stage2" && mv "${PART_SB}/stage2-models.txt" "${PART_SB}/stage2/models.txt"
tar czf "${PART_SB}/modelsonly.tar.gz" -C "${PART_SB}/stage2" . 2>/dev/null
part2_rc=0
part2_out="$(cd "${PART_SB}" && ./restore.sh ./modelsonly.tar.gz </dev/null 2>&1)" || part2_rc=$?
part2_restored() {
  [[ "${part2_rc}" == "0" ]] && grep -qF 'Restore complete' <<<"${part2_out}"
}
check "...and one carrying only a model list is ours too" part2_restored

echo "# verify_backup() rejects corrupt/incomplete archives (a bad backup must never be trusted)"
# backup.sh only runs main() when executed, so sourcing it here just defines
# its functions. Guards the "disk filled up mid-tar" case: the archive must read
# back AND contain every staged file, or retention would delete good backups on
# the strength of a broken one and restore.sh would later pick it (newest wins).
# shellcheck source=../backup.sh
source "${REPO}/backup.sh"
VB_STAGE="${SANDBOX}/vbstage"
mkdir -p "${VB_STAGE}"
printf 'env-contents\n'    > "${VB_STAGE}/env"
printf 'model-list\n'      > "${VB_STAGE}/models.txt"
VB_GOOD="${SANDBOX}/good.tar.gz"
tar czf "${VB_GOOD}" -C "${VB_STAGE}" .
# '!' is a shell keyword, so it cannot be passed through check's "$@" — negate
# inside a real function instead.
vb_rejects() { ! verify_backup "$1" "$2" 2>/dev/null; }
check "intact archive verifies"            verify_backup "${VB_GOOD}" "${VB_STAGE}"
VB_TRUNC="${SANDBOX}/truncated.tar.gz"
head -c 40 "${VB_GOOD}" > "${VB_TRUNC}"
check "truncated archive is rejected"      vb_rejects "${VB_TRUNC}" "${VB_STAGE}"
VB_PARTIAL="${SANDBOX}/partial.tar.gz"
tar czf "${VB_PARTIAL}" -C "${VB_STAGE}" ./env          # models.txt missing
check "archive missing a staged file is rejected" vb_rejects "${VB_PARTIAL}" "${VB_STAGE}"
: > "${SANDBOX}/empty.tar.gz"
check "empty file is rejected"             vb_rejects "${SANDBOX}/empty.tar.gz" "${VB_STAGE}"

echo "# the Open WebUI image is named once, and its pull is never implicit"
# Three scripts use that image and only one owned the string: install_webui.sh
# created the container with it, while backup.sh and restore.sh hardcoded the
# same literal to borrow a tar binary next to the volume. Pin or move the tag
# and two of the three would go on tarring with an image the app no longer
# runs.
image_is_named_once() {
  local hits
  hits="$(grep -rn --include='*.sh' 'ghcr.io/open-webui' "${REPO}" | grep -v '/tests/' || true)"
  [[ -n "${hits}" ]] || {
    echo "the image name is nowhere — this gate stopped watching" >&2
    return 1
  }
  [[ "$(grep -c . <<<"${hits}")" == "1" ]] || {
    printf 'the image literal appears more than once:\n%s\n' "${hits}" >&2
    return 1
  }
  grep -q '/scripts/lib.sh:' <<<"${hits}" || {
    printf 'the one definition is not in lib.sh:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "the Open WebUI image name lives in exactly one place" image_is_named_once
# The README's security model now states two facts about the install that only
# the code can keep true: the vendor installers are piped into a root shell,
# and the chat app runs a floating tag. A security section that describes an
# install nobody performs any more is worse than one that says nothing.
readme_supply_chain_matches_the_code() {
  local f want got
  for f in scripts/install_ollama.sh scripts/install_tailscale.sh; do
    grep -qE 'curl [^|]*[|] *as_root sh' "${REPO}/${f}" || {
      printf '%s no longer pipes its vendor installer into a root shell, which the README says it does\n' "${f}" >&2
      return 1
    }
  done
  want="$(grep -oE 'ghcr[.]io/open-webui/open-webui:[a-zA-Z0-9._-]+' "${REPO}/scripts/lib.sh" | head -1)"
  got="$(grep -oE 'ghcr[.]io/open-webui/open-webui:[a-zA-Z0-9._-]+' "${REPO}/README.md" | head -1)"
  [[ -n "${want}" && -n "${got}" ]] || {
    echo "could not read the chat app image tag from lib.sh or from the README" >&2
    return 1
  }
  [[ "${want}" == "${got}" ]] || {
    printf 'the README names %s; lib.sh uses %s\n' "${got}" "${want}" >&2
    return 1
  }
}
check "the README's supply-chain claims still match the install" \
  readme_supply_chain_matches_the_code
# ...and neither script may reach 'docker run <image>' without having checked
# the image is there. Docker pulls a missing one silently: several gigabytes,
# and in backup.sh's case with the chat app frozen, during a command the user
# expects to take seconds.
image_pulls_are_never_implicit() {
  local f bad=0
  for f in backup.sh restore.sh; do
    grep -qF -- 'docker image inspect' "${REPO}/${f}" || {
      printf '%s runs the image without checking it is cached first\n' "${f}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "no script pulls gigabytes by accident" image_pulls_are_never_implicit

echo "# every archive must be owner-only, not just the directory holding it"
# The umask around tar makes NEW archives 0600. Ones written before that
# existed are still 0644, and the 0700 directory is all that protects them —
# which stops being true the moment one is copied, moved, or the directory's
# mode drifts. Each holds the Open WebUI database (account password hashes and
# the JWT signing key that mints valid sessions) plus a verbatim copy of .env.
TBM="${SANDBOX}/tighten"
rm -rf "${TBM}"; mkdir -p "${TBM}"
: > "${TBM}/local-code-agent-backup-20260101-000000.tar.gz"
: > "${TBM}/local-code-agent-backup-20260102-000000.tar.gz"
: > "${TBM}/notes.txt"
chmod 644 "${TBM}/local-code-agent-backup-20260101-000000.tar.gz"
chmod 600 "${TBM}/local-code-agent-backup-20260102-000000.tar.gz"
chmod 644 "${TBM}/notes.txt"
TBM_OUT="$(tighten_backup_modes "${TBM}")"
mode_of() { stat -c %a "$1" 2>/dev/null; }
check "a world-readable archive is tightened" \
  test "$(mode_of "${TBM}/local-code-agent-backup-20260101-000000.tar.gz")" = "600"
check "an already-tight archive is left alone" \
  test "$(mode_of "${TBM}/local-code-agent-backup-20260102-000000.tar.gz")" = "600"
# Only archives. Something else the user parked in the directory is theirs.
check "an unrelated file is not touched" \
  test "$(mode_of "${TBM}/notes.txt")" = "644"
check "it reports how many it had to change" test "${TBM_OUT}" = "1"
# Idempotent, and silent when there is nothing to do — otherwise every backup
# from here on would announce work it did not do.
check "a second pass says nothing" test -z "$(tighten_backup_modes "${TBM}")"
# A directory that does not exist is not an error: backup.sh calls this before
# it is certain the directory could be created.
check "a missing directory is not an error" test -z "$(tighten_backup_modes "${SANDBOX}/no-such-dir")"

echo "# retention must never prune on the strength of a look nobody took"
# Three states, and the middle one is the whole point: "docker did not answer"
# is not "there is no data". Get it wrong in that direction and BACKUP_KEEP
# unattended nights delete every backup that still holds the accounts and chat
# history — while each run reports success.
#
# webui_data_state USABLE INSTALLED VOLUME. Its own name, not the 'state_is'
# the motd block further down uses — two helpers with one name in one file is
# a test that silently stops testing the moment the second definition loads.
data_state_is() { [[ "$(webui_data_state "$2" "$3" "$4")" == "$1" ]]; }
check "daemon up and the volume is there -> archive it" \
  data_state_is present true true true
check "daemon up and no volume -> nothing to lose" \
  data_state_is none    true true false
# The regression this exists for. The volume outlives ENABLE_WEBUI, so the
# setting was never evidence about the data — but it sat in this condition, and
# with the daemon down and the chat app switched off in .env the old code
# reported "no volume found" and pruned. Nothing had looked.
check "docker installed but the daemon is down -> we cannot tell, keep them" \
  data_state_is unknown false true false
check "...and still cannot tell even if a stale flag says a volume was there" \
  data_state_is unknown false true true
# ...while a machine with no docker at all genuinely has no volume, and must
# still prune. Getting THIS wrong disables retention for ever and fills the
# disk, which is the opposite failure and just as real.
check "no docker on the machine -> nothing to lose" \
  data_state_is none    false false false
# And the decision must not consult .env's chat-app switch again.
retention_ignores_enable_webui() {
  awk '/^webui_data_state\(\) \{/ { inb = 1 }
       inb && /ENABLE_WEBUI/ { bad = 1 }
       inb && /^\}/ { exit }
       END { exit bad }' <<<"$(sed 's/#.*//' "${REPO}/backup.sh")"
}
echo "# a backup that missed the chat data must not prune the ones that have it"
# The note above prune_old_backups says this exists so "an unattended timer run
# with docker down would not, over BACKUP_KEEP nights, silently delete every
# backup that still had the WebUI accounts and chat history". It covered the
# daemon-down case and not the missing-volume one. Measured with docker
# installed, its daemon reachable, and the volume simply absent — which is what
# 'docker volume rm open-webui' leaves behind:
#
#   [warn] No 'open-webui' docker volume on this machine — skipping WebUI data.
#   [ ok ] Backup written and verified: ...tar.gz (4.0K)
#   [info] Retention: keeping the newest 1; removing 2 older backup(s).
#
# A 4 KB backup with no chat history deleted two complete ones, at exactly the
# moment those older copies were the only ones left holding it.
#
# Driven rather than grepped: the property is "the old files still exist
# afterwards", and no amount of reading the source proves that.
backup_retention_case() {  # ENABLE_WEBUI -> "<surviving-old-count> <skipped|ran>"
  local b="${SANDBOX}/retention-$1"
  rm -rf "${b}"; mkdir -p "${b}/scripts" "${b}/backups" "${b}/fakebin"
  cp "${REPO}/backup.sh" "${b}/"; cp "${REPO}/scripts/lib.sh" "${b}/scripts/"
  cp "${REPO}/.env.example" "${b}/.env"
  sed -i "s/^BACKUP_KEEP=.*/BACKUP_KEEP=1/; s/^ENABLE_WEBUI=.*/ENABLE_WEBUI=$1/" "${b}/.env"
  # docker present and its daemon fine; the volume is what is missing.
  # shellcheck disable=SC2016  # $1/$2 belong to the fake docker, not to us
  printf '#!/bin/sh\nif [ "$1" = "info" ]; then exit 0; fi\nif [ "$1" = "volume" ] && [ "$2" = "inspect" ]; then exit 1; fi\nexit 0\n' \
    > "${b}/fakebin/docker"
  chmod +x "${b}/fakebin/docker"
  local d
  for d in 20260101-000000 20260102-000000; do
    echo old > "${b}/backups/local-code-agent-backup-${d}.tar.gz"
  done
  local out old
  out="$(PATH="${b}/fakebin:${PATH}" bash "${b}/backup.sh" 2>&1 || true)"
  old="$(find "${b}/backups" -name 'local-code-agent-backup-2026010*.tar.gz' | wc -l)"
  if grep -q 'skipping retention' <<<"${out}"; then printf '%s skipped\n' "${old}"
  else printf '%s ran\n' "${old}"; fi
}
check "with the chat app configured, an incomplete backup keeps the older ones" \
  test "$(backup_retention_case true)" = "2 skipped"
# ...and the other half: with no chat app there is genuinely nothing to miss,
# so retention must still run or backups accumulate forever.
check "...and with ENABLE_WEBUI=false it still prunes" \
  test "$(backup_retention_case false)" = "0 ran"

check "the retention decision never reads ENABLE_WEBUI" \
  retention_ignores_enable_webui
# ...and do_backup must actually branch on the answer. A pure helper that
# nothing consults is decoration, and the five checks above would all still
# pass while backup.sh went on deciding for itself.
backup_asks_the_state_helper() {
  awk '/^do_backup\(\) \{/ { inb = 1 }
       inb && /webui_data_state/       { called = 1 }
       inb && /data_state.*"present"/  { branched = 1 }
       inb && /^\}/ { exit }
       END { exit !(called && branched) }' <<<"$(sed 's/#.*//' "${REPO}/backup.sh")"
}
check "backup.sh decides retention through that helper, not its own reading" \
  backup_asks_the_state_helper

echo "# backups_to_prune() keeps the newest KEEP; prints the older ones to delete"
# Timestamped names sort chronologically; the helper sorts internally, so the
# order they are fed in must not matter.
B1="backups/local-code-agent-backup-20250101-000000.tar.gz"
B2="backups/local-code-agent-backup-20250102-000000.tar.gz"
B3="backups/local-code-agent-backup-20250103-000000.tar.gz"
B4="backups/local-code-agent-backup-20250104-000000.tar.gz"
B5="backups/local-code-agent-backup-20250105-000000.tar.gz"
prune_sel() { local k="$1"; shift; printf '%s\n' "$@" | backups_to_prune "${k}"; }
check "keep 2 of 5 -> delete the oldest 3 (feed order irrelevant)" \
  test "$(prune_sel 2 "${B3}" "${B1}" "${B5}" "${B2}" "${B4}")" = "$(printf '%s\n%s\n%s' "${B1}" "${B2}" "${B3}")"
check "keep 1 of 3 -> delete the oldest 2" \
  test "$(prune_sel 1 "${B2}" "${B3}" "${B1}")" = "$(printf '%s\n%s' "${B1}" "${B2}")"
check "keep == count -> delete none" test -z "$(prune_sel 3 "${B1}" "${B2}" "${B3}")"
check "keep > count -> delete none"  test -z "$(prune_sel 7 "${B1}" "${B2}" "${B3}")"
check "keep 0 -> retention off, delete none" test -z "$(prune_sel 0 "${B1}" "${B2}")"
check "non-numeric keep -> delete none"      test -z "$(prune_sel abc "${B1}" "${B2}")"
# ...and the sentence describing those two early returns has to mean what they
# do. Printed raw, BACKUP_KEEP=0 became "keeping the newest 0" — not merely
# unclear but backwards and alarming, since it reads as "every backup will be
# deleted" at the moment somebody is switching scheduled backups ON, when in
# fact none of them ever will be. BACKUP_KEEP=abc became "keeping the newest
# abc", which is not a sentence. Both were what 'backup.sh --install-timer'
# said; check-system.sh had worked it out and carried a comment saying exactly
# this, and the other caller never asked.
#
# In-process throughout. Written with 'bash -c' first, these ran in a shell
# that had never sourced lib.sh: three failed as command-not-found, and the
# NEGATIVE one — "never reads as newest-zero" — passed, because its leading '!'
# inverted the missing command into a success. A gate that passes hardest when
# the function does not exist is the shape this file keeps finding.
keep_desc_for() { BACKUP_KEEP="$1" retention_desc; }
check "a normal count is described as a count" \
  test "$(keep_desc_for 7)" = "keeping newest 7"
zero_says_keep_everything() { grep -qi 'keeping all' <<<"$(keep_desc_for 0)"; }
check "0 is 'keep everything', not 'keep none'" zero_says_keep_everything
zero_never_reads_as_none() { ! grep -qE 'newest 0' <<<"$(keep_desc_for 0)"; }
check "...and never reads as newest-zero" zero_never_reads_as_none
junk_says_disabled_and_quotes_it() {
  local out; out="$(keep_desc_for abc)"
  grep -qi 'disabled' <<<"${out}" && grep -qF 'abc' <<<"${out}"
}
check "a value that is not a number says retention is off, and quotes it" \
  junk_says_disabled_and_quotes_it
unset_falls_back_to_the_default() {
  local out; out="$(BACKUP_KEEP="" retention_desc)"
  [[ "${out}" == "keeping newest 7" ]]
}
check "an unset value falls back to the documented default" \
  unset_falls_back_to_the_default
# ...and both readers must go through it, or they will disagree again.
retention_is_described_once() {
  local bad=0 f body
  for f in "${REPO}/backup.sh" "${REPO}/check-system.sh"; do
    body="$(sed 's/^[[:space:]]*#.*//' "${f}")"
    grep -q 'retention_desc' <<<"${body}" || {
      printf '%s does not use retention_desc\n' "${f##*/}" >&2; bad=1; continue; }
    # The raw value, in a sentence about keeping things, is the bug itself.
    grep -qE 'keeping the newest \$\{BACKUP_KEEP' <<<"${body}" && {
      printf '%s prints BACKUP_KEEP raw in a retention sentence again\n' "${f##*/}" >&2
      bad=1; }
  done
  return "${bad}"
}
check "both retention messages come from one rule" retention_is_described_once

echo "# two backups at once shared a filename and both called it a success"
# Nothing serialised backup.sh, and there are three ways to have two running:
# the nightly timer, a manual 'lca backup', and the one 'lca update' takes.
# Measured with two concurrent runs before the fix: two "Backup written and
# verified" lines naming the SAME path, and one file on disk. The stamp is
# second-granular and a backup finishes inside a second whenever there is no
# WebUI volume to archive — ENABLE_WEBUI=false is documented, not a corner.
UBP="${SANDBOX}/ubp"
rm -rf "${UBP}"; mkdir -p "${UBP}"
check "a free stamp keeps the plain name" \
  test "$(unique_backup_path "${UBP}" 20250101-000000)" \
     = "${UBP}/local-code-agent-backup-20250101-000000.tar.gz"
: > "${UBP}/local-code-agent-backup-20250101-000000.tar.gz"
check "a taken stamp does not overwrite it" \
  test "$(unique_backup_path "${UBP}" 20250101-000000)" \
     = "${UBP}/local-code-agent-backup-20250101-000000_2.tar.gz"
: > "${UBP}/local-code-agent-backup-20250101-000000_2.tar.gz"
check "...and keeps counting past the second" \
  test "$(unique_backup_path "${UBP}" 20250101-000000)" \
     = "${UBP}/local-code-agent-backup-20250101-000000_3.tar.gz"
# The suffix character is load-bearing. backups_to_prune sorts lexically and
# calls the tail newest, which holds only because YYYYmmdd-HHMMSS makes lexical
# order chronological. '-' is 0x2D and '.' is 0x2E, so a '-2' suffix sorts
# BEFORE the plain name and retention would delete the NEWER file first. '_' is
# 0x5F, after '.', so the order survives. Pinned, because nothing else would
# notice this being "tidied" back to a dash.
#
# Both names come FROM unique_backup_path rather than being written out here,
# so the two cannot drift: change the suffix and this asserts the ordering for
# whatever it becomes, instead of going on testing a name nothing produces.
# (Hand-written literals passed the '-N' mutation this is here to catch.)
SAME_DIR="${SANDBOX}/ubp-order"
rm -rf "${SAME_DIR}"; mkdir -p "${SAME_DIR}"
SAME_1="$(unique_backup_path "${SAME_DIR}" 20250101-000000)"; : > "${SAME_1}"
SAME_2="$(unique_backup_path "${SAME_DIR}" 20250101-000000)"
check "the collision suffix counts as NEWER, so retention drops the plain one" \
  test "$(prune_sel 1 "${SAME_2}" "${SAME_1}")" = "${SAME_1}"
# ...and the lock itself, which is what stops the two runs interleaving on the
# container pause — the one thing that pause exists to make consistent.
backup_serialises_itself() {
  local body; body="$(sed 's/#.*//' "${REPO}/backup.sh")"
  grep -q 'acquire_backup_lock' <<<"${body}" || {
    echo "backup.sh no longer takes a lock — the timer and a manual run can interleave" >&2
    return 1
  }
  # Scoped to the function, and to the two calls that DO the work rather than
  # to the word "flock" anywhere in the file. The loose version passed a
  # mutation that replaced the acquiring call with 'true' — every mention of
  # flock survived in the comments and the degrade check, so the gate saw a
  # lock that was no longer taken.
  local lockfn; lockfn="$(probe_region backup.sh 'acquire_backup_lock() {' '}')"
  [[ -n "${lockfn}" ]] || {
    echo "acquire_backup_lock is gone (renamed?)" >&2
    return 1
  }
  # flock, not a lockfile someone has to clean up: it releases even on kill -9,
  # so a crashed run cannot wedge every future nightly backup.
  grep -q 'flock -n' <<<"${lockfn}" || {
    echo "backup.sh never actually takes the lock (no 'flock -n')" >&2
    return 1
  }
  # ...and waits rather than giving up, because update.sh depends on the backup
  # really being taken.
  grep -q 'flock -w' <<<"${lockfn}" || {
    echo "backup.sh does not wait for a running backup — update.sh would proceed unbacked" >&2
    return 1
  }
  # A missing flock must not stop the backup happening at all.
  grep -q 'have flock' <<<"${lockfn}" || {
    echo "backup.sh requires flock outright instead of degrading" >&2
    return 1
  }
  # The lock has to be held BEFORE the tarball path is chosen, or two runs can
  # still pick the same one.
  # END decides, and only END. A rule-level 'exit N' in awk still RUNS the END
  # block, so an 'END { exit 1 }' underneath silently overwrites the status —
  # this check reported the ordering as wrong while the code had it right.
  awk '/acquire_backup_lock$/ { locked = 1 }
       /unique_backup_path "/ { if (!seen) { seen = 1; in_order = locked } }
       END { exit (seen && in_order) ? 0 : 1 }' <<<"${body}" || {
    echo "backup.sh picks its tarball name before taking the lock" >&2
    return 1
  }
}
check "backup.sh runs one at a time" backup_serialises_itself

echo "# installed_backup_schedule() — the timer's real OnCalendar, out of systemd"
# Found by 'make coverage': neither suite ran this, and no test named it, while
# 'lca check' and 'lca apply' both compare its answer against .env to decide
# whether the backup schedule has drifted. A parser nothing feeds is a parser
# nobody knows the shape of — and lib.sh's own comment cites it as the example
# of the ' ; ' trap that another function had to learn.
#
# Driven with real 'systemctl show -p TimersCalendar --value' records, stubbing
# systemctl so this needs neither systemd nor a timer.
schedule_from() {   # SYSTEMCTL_OUTPUT -> what the parser makes of it
  SHOWOUT="$1" bash -c '
    set -uo pipefail
    source "$1"
    systemd_available() { return 0; }
    systemctl() { printf "%s\n" "${SHOWOUT}"; }
    installed_backup_schedule || printf "(none)"
  ' _ "${REPO}/scripts/lib.sh" 2>/dev/null
}
check "the ordinary single-entry record yields just the calendar spec" \
  test "$(schedule_from '{ OnCalendar=*-*-* 03:30:00 ; next_elapse=Wed 2026-08-06 03:30:00 UTC }')" \
     = '*-*-* 03:30:00'
# A timer with nothing left to fire still reports its calendar; the capture must
# end at the ' ; ' rather than swallowing whatever follows.
check "a timer that never elapses again still reports its schedule" \
  test "$(schedule_from '{ OnCalendar=*-*-* 03:30:00 ; next_elapse=n/a }')" \
     = '*-*-* 03:30:00'
# Two OnCalendar entries arrive on ONE line, so both greedy '.*' matches race.
# Measured rather than reasoned about — the prediction going in was that this
# returns a mangled span from the first entry to the last separator; the leading
# '.*' is greedy too and wins first, so it is the LAST entry that comes back.
# Pinned because "incomplete" and "corrupt" are different answers, and only one
# of them is safe to compare against .env.
check "two calendars return one whole spec, not a mangled span" \
  test "$(schedule_from '{ OnCalendar=Mon *-*-* 01:00:00 ; next_elapse=Mon 2026-08-10 01:00:00 UTC } { OnCalendar=*-*-* 03:30:00 ; next_elapse=Wed 2026-08-06 03:30:00 UTC }')" \
     = '*-*-* 03:30:00'
# No timer installed: systemd prints nothing, and "no schedule" must not come
# back as an empty string a caller would compare against .env and call drift.
check "no timer reports nothing, and says so by exit status" \
  test "$(schedule_from '')" = '(none)'
check "a record with no OnCalendar at all reports nothing" \
  test "$(schedule_from '{ next_elapse=n/a }')" = '(none)'

echo "# git_identity_user() — WHOSE git config the two reporters read"
# Also untouched by any test. It decides which account 'lca check' and
# install_git.sh ask about user.name/user.email, and under 'sudo lca check' the
# answer must be the human rather than root — root's global config is not where
# anyone put their identity, so getting this wrong reports a missing identity to
# someone who has one.
#
# Both arms are driven here, by stubbing am_root. Without that seam the "we are
# root" arm is reachable only on a machine running the suite as root and the
# other only on one that is not — so each environment would test half of this
# and report ok about the other half, which is how the defect below survived.
identity_user_with() {   # SUDO_USER value ("" = unset), am_root answer
  bash -c '
    set -uo pipefail
    source "$1"
    # Captured out here: inside the function, $3 would be its own argument.
    AMROOT="$3"
    am_root() { [[ "${AMROOT}" == root ]]; }
    if [[ -n "$2" ]]; then export SUDO_USER="$2"; else unset SUDO_USER; fi
    git_identity_user
  ' _ "${REPO}/scripts/lib.sh" "$2" "$3" 2>/dev/null
}
check "under sudo it asks about the human, not root" \
  test "$(identity_user_with _ someone root)" = "someone"
check "without sudo it asks about the current user" \
  test "$(identity_user_with _ '' root)" = "$(id -un)"
# ...and SUDO_USER is only about who invoked sudo, which is not who we ARE when
# sudo dropped privileges instead of raising them. Measured, running
# check-system.sh as 'sudo -u ubuntu' — SUDO_USER=root, process running as
# ubuntu, and 'lca check' said:
#
#   [warn] no global git identity for 'root' — ... Fix once: git config --global ...
#
# naming an account that was neither the one whose config it read nor the one
# the reader was using, and offering a fix that would set a third party's
# identity — after which the warning returns unchanged, for ever.
#
# The stale value is a name no account has, not "root". Written as 'root' first
# — faithful to the measured case — it compared equal to $(id -un) on a suite
# running as root and passed against the unfixed function, which is the whole
# family of bug this file keeps closing.
check "a stale SUDO_USER is ignored when we are not root" \
  test "$(identity_user_with _ nobody-by-this-name notroot)" = "$(id -un)"
check "...and the current user is still right with no SUDO_USER at all" \
  test "$(identity_user_with _ '' notroot)" = "$(id -un)"
# The invariant underneath all four: the account NAMED is the account READ.
# These were two separate conditions and they disagreed. Driven with a stubbed
# git and sudo so it needs no second account on the machine.
identity_label_matches_value() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    git_identity_user() { printf "%s\n" "the-human"; }
    id() { [[ "${1:-}" == -un ]] && printf "somebody-else\n" || command id "$@"; }
    # Whoever is asked, answers with their own name, so the output says which
    # account was actually read.
    sudo() {
      [[ "$1" == -u ]] || { printf "BADSUDO\n"; return 1; }
      printf "%s\n" "$2"
    }
    git() { printf "%s\n" "somebody-else"; }
    git_identity
  ' _ "${REPO}/scripts/lib.sh" 2>/dev/null)"
  grep -q 'the-human' <<<"${out}" || {
    printf 'the label says the-human but the config came from elsewhere: %s\n' "${out}" >&2
    return 1; }
  ! grep -q 'somebody-else' <<<"${out}" || {
    printf 'it read the current account while reporting a different one: %s\n' "${out}" >&2
    return 1; }
}
check "the account named is the account whose config was read" \
  identity_label_matches_value

echo "# 'I found no backups' and 'I could not look' are not the same sentence"
# backup.sh creates backups/ as 0700 root-owned on purpose — an archive holds
# the chat app's session-signing key, and there is a gate above on exactly that.
# So for any other account a glob or a find in it comes back empty in precisely
# the way an empty directory does. Measured as 'ubuntu', with a backup sitting
# in that directory:
#
#   lca check     [info]  no backups yet — create one with: .../backup.sh
#   lca restore   [FAIL]  No tarball given and none found in .../backups.
#
# There was one. The first told someone they had no backups and handed them a
# command that needs root; the second told it to somebody in the middle of
# recovering something. Three checks away, check-system.sh already says
# "neither confirmed nor ruled out" about docker, the container and nftables.
check "a readable directory reads as readable" readable_by_us "${SANDBOX}"
# In-process, not 'bash -c': a fresh shell has not sourced lib.sh, so the call
# fails as "command not found" and the leading '!' turns that into a pass. The
# first version of this line did exactly that and reported ok — caught by the
# command_not_found_handle guard at the top of this file, which is what it is
# for.
missing_path_is_not_readable() { ! readable_by_us "${SANDBOX}/no-such-dir-here"; }
check "...and a path that does not exist does not" missing_path_is_not_readable
# Both bits: a directory with r and no x lists names but cannot stat them, and
# a glob over it comes back empty — the same silence this whole check exists to
# stop being mistaken for an answer.
readable_needs_both_bits() {
  local body
  body="$(sed 's/#.*//' "${REPO}/scripts/lib.sh")"
  grep -qE 'readable_by_us\(\).*-r .*&&.*-x ' <<<"${body}"
}
check "readability means both list and stat" readable_needs_both_bits
# ...and the two readers must ask before they conclude. Ordering, not mere
# presence: a readability check AFTER the search is a check about a result that
# already means nothing.
asks_before_it_concludes() {  # FILE  SEARCH-PATTERN
  awk -v pat="$2" '
    /^[[:space:]]*#/ { next }
    /readable_by_us/ { seen = 1 }
    $0 ~ pat { found = NR; if (!seen) { print "the search at line " NR " runs before anything checks it can be read"; bad = 1 } }
    END {
      if (!found) { print "the backup search is gone from this file — this gate has lost its subject"; bad = 1 }
      exit bad
    }' "$1"
}
check "'lca check' asks whether it can read backups/ before saying there are none" \
  asks_before_it_concludes "${REPO}/check-system.sh" 'local-code-agent-backup-\\*'
check "...and so does 'lca restore' before saying it found none" \
  asks_before_it_concludes "${REPO}/restore.sh" "find .*BACKUP_DIR"
# ...and neither may state the negative it cannot know.
unreadable_is_not_reported_as_empty() {
  local bad=0 f body
  for f in check-system.sh restore.sh; do
    body="$(sed 's/^[[:space:]]*#.*//' "${REPO}/${f}")"
    grep -qE 'readable_by_us "\$\{(BACKUPS_PATH|BACKUP_DIR)\}"' <<<"${body}" || {
      printf '%s does not test the backup directory for readability\n' "${f}" >&2
      bad=1; continue; }
    # The message on that branch has to say the answer is unknown, not absent.
    grep -qE 'neither confirmed nor ruled out|unknown, not answered' <<<"${body}" || {
      printf '%s checks readability but still reports a definite answer\n' "${f}" >&2
      bad=1; }
  done
  return "${bad}"
}
check "an unreadable backups directory is reported as unknown, not as empty" \
  unreadable_is_not_reported_as_empty
# ...and it must NOT escalate when there is nobody to escalate to: a needless
# 'sudo -u me' on a box without passwordless sudo is a health check that stops
# for a password.
identity_does_not_escalate_to_itself() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    git_identity_user() { printf "%s\n" "me"; }
    id() { [[ "${1:-}" == -un ]] && printf "me\n" || command id "$@"; }
    sudo() { printf "ESCALATED\n"; }
    git() { printf "direct\n"; }
    git_identity
  ' _ "${REPO}/scripts/lib.sh" 2>/dev/null)"
  ! grep -q 'ESCALATED' <<<"${out}" || {
    printf 'it ran sudo to read its own config: %s\n' "${out}" >&2; return 1; }
}
check "...and it never sudos to the account it already is" \
  identity_does_not_escalate_to_itself

echo "# .env keys must not collide with aider's own env vars (load_env exports them)"
# load_env sources .env under 'set -a', so every key becomes an environment
# variable. A key named AIDER_* can therefore be consumed by aider itself: our
# sentinel LCA_EDIT_FORMAT=auto, if named AIDER_EDIT_FORMAT, made even
# 'aider --version' fail because "auto" is not a valid aider edit format.
no_aider_collision() {
  local aider_bin_path key
  aider_bin_path="$(aider_bin)"
  [[ -x "${aider_bin_path}" ]] || return 0   # aider not installed here: skip
  local envs; envs="$("${aider_bin_path}" --help 2>/dev/null | grep -oE 'env var: [A-Z_]+' | sed 's/env var: //' | sort -u)"
  [[ -n "${envs}" ]] || return 0
  while read -r key; do
    [[ -n "${key}" ]] || continue
    # AIDER_VERSION is ours and predates this rule; it is not an aider env var.
    if grep -qx "${key}" <<<"${envs}"; then
      echo "collides with aider: ${key}" >&2
      return 1
    fi
  done < <(grep -oE '^[A-Z_]+' "${REPO}/.env.example" | sort -u)
  return 0
}
check "no .env key collides with an aider env var" no_aider_collision

echo "# every setting is BOTH documented and defaulted — the two lists are one list"
# Two failures, one in each direction, and neither shows up until a user hits
# it:
#
#   documented but not defaulted — .env.example is the file people edit, and
#     deleting a line from it is an ordinary thing to do. Every script here
#     runs under 'set -u', so a key load_env does not default is an unbound
#     variable the moment someone removes it: the command dies with a bash
#     error naming a variable, not a setting.
#
#   defaulted but not documented — the setting works and nothing tells anyone
#     it exists. .env.example IS the reference; there is no other.
env_keys_and_defaults_agree() {
  local documented defaulted missing
  documented="$(grep -oE '^[A-Z_]+=' "${REPO}/.env.example" | tr -d '=' | sort -u)"
  defaulted="$(sed -n '/^load_env()/,/^}/p' "${REPO}/scripts/lib.sh" \
    | grep -oE '^  [A-Z_]+=' | tr -d ' =' | sort -u)"
  # Either list coming back empty means the extraction stopped working, and a
  # comparison of two empty lists passes for ever.
  [[ -n "${documented}" && -n "${defaulted}" ]] || {
    echo "could not read the settings out of .env.example or load_env" >&2
    return 1
  }
  missing="$(comm -23 <(printf '%s\n' "${documented}") <(printf '%s\n' "${defaulted}"))"
  [[ -z "${missing}" ]] || {
    printf 'documented in .env.example but not defaulted in load_env: %s\n' \
      "${missing//$'\n'/, }" >&2
    return 1
  }
  missing="$(comm -13 <(printf '%s\n' "${documented}") <(printf '%s\n' "${defaulted}"))"
  [[ -z "${missing}" ]] || {
    printf 'defaulted in load_env but undocumented in .env.example: %s\n' \
      "${missing//$'\n'/, }" >&2
    return 1
  }
}
check "every .env.example key has a default, and every default is documented" \
  env_keys_and_defaults_agree

echo "# processor_from_ps(): is the GPU actually being used? (parsed by pattern, not column)"
PS_GPU="NAME                ID              SIZE      PROCESSOR    CONTEXT    UNTIL
qwen2.5-coder:7b    dae161e27b0e    5.5 GB    100% GPU     4096       4 minutes from now"
PS_CPU="NAME                ID              SIZE      PROCESSOR    CONTEXT    UNTIL
qwen2.5-coder:7b    dae161e27b0e    5.5 GB    100% CPU     4096       4 minutes from now"
PS_SPLIT="NAME                 ID              SIZE     PROCESSOR          CONTEXT   UNTIL
qwen2.5-coder:14b    9ec8897f747e    10 GB    38%/62% CPU/GPU    8192      5 minutes from now"
PS_EMPTY="NAME    ID    SIZE    PROCESSOR    CONTEXT    UNTIL"
pfp() { printf '%s\n' "$1" | processor_from_ps "$2"; }
check "100% GPU parsed"  test "$(pfp "${PS_GPU}" qwen2.5-coder:7b)"    = "100% GPU"
check "100% CPU parsed"  test "$(pfp "${PS_CPU}" qwen2.5-coder:7b)"    = "100% CPU"
# The PROCESSOR field contains a space, so a column-index parser would return
# just "38%/62%" here — this pins the pattern-based behaviour.
check "CPU/GPU split parsed" test "$(pfp "${PS_SPLIT}" qwen2.5-coder:14b)" = "38%/62% CPU/GPU"
not_loaded() { ! printf '%s\n' "${PS_EMPTY}" | processor_from_ps qwen2.5-coder:7b 2>/dev/null; }
check "unloaded model reports nothing" not_loaded
wrong_model() { ! printf '%s\n' "${PS_GPU}" | processor_from_ps some-other-model 2>/dev/null; }
check "a different model is not matched" wrong_model
# ...and a model whose name CONTAINS the one asked about is not matched either.
# Every fixture above has exactly one row, which is why a substring match
# looked correct for as long as it did. 'ollama ps' lists everything resident,
# and two models are resident whenever 'lca ask -m OTHER' has run inside
# OLLAMA_KEEP_ALIVE. Measured before the fix: asked about the 7b sitting at
# 100% GPU, this answered 100% CPU — the ':7b-instruct' row above it.
PS_TWO="NAME                        ID              SIZE      PROCESSOR    CONTEXT   UNTIL
qwen2.5-coder:7b-instruct   9ec8897f747e    8.0 GB    100% CPU     8192      4 minutes from now
qwen2.5-coder:7b            dae161e27b0e    5.5 GB    100% GPU     4096      4 minutes from now"
check "a longer name that contains ours does not steal the answer" \
  test "$(pfp "${PS_TWO}" qwen2.5-coder:7b)" = "100% GPU"
check "...and asking about the longer one still gets its own row" \
  test "$(pfp "${PS_TWO}" qwen2.5-coder:7b-instruct)" = "100% CPU"
# An unknown model must stay unknown rather than borrowing the first row —
# gpu_state passes an empty string whenever MODEL_NAME is unset.
no_model_name() { ! printf '%s\n' "${PS_TWO}" | processor_from_ps "" 2>/dev/null; }
check "no model name reports nothing, not the first row" no_model_name
# The header must never be mistaken for a model, whatever is asked.
header_not_a_model() { ! printf '%s\n' "${PS_TWO}" | processor_from_ps NAME 2>/dev/null; }
check "the header row is not a model" header_not_a_model

echo "# ollama_processor() — the same parser, fed by the real 'ollama ps'"
# 'make coverage' found this untested: the parser had fixtures, the function
# that supplies it did not, and the wrapper is where the pipeline lives.
op_with() {   # MODEL PS_OUTPUT
  PSOUT="$2" bash -c '
    set -uo pipefail
    source "$1"
    # $1 inside a function is the FUNCTION'"'"'s argument, not the script'"'"'s.
    have() { [[ "$1" == "ollama" ]]; }
    ollama() { printf "%s\n" "${PSOUT}"; }
    ollama_processor "$2" || printf "(none)"
  ' _ "${REPO}/scripts/lib.sh" "$1" 2>/dev/null
}
check "the wrapper reports the asked-for model's placement" \
  test "$(op_with qwen2.5-coder:7b "${PS_TWO}")" = "100% GPU"
check "a model that is not resident reports nothing" \
  test "$(op_with qwen2.5-coder:3b "${PS_TWO}")" = "(none)"
# Reading to the END of 'ollama ps' rather than stopping at the first match is
# what keeps this from returning 141 under pipefail, where "model not loaded"
# is the answer a closed pipe fakes. Asserted with a producer that keeps
# writing long after the match, because a small fixture cannot tell the two
# implementations apart — the first version of this gate could not, and an
# 'exit' added to the parser sailed straight through it.
op_slow_producer() {   # match first, then far more than a pipe buffer
  PSOUT="$1" bash -c '
    set -uo pipefail
    source "$1"
    have() { [[ "$1" == "ollama" ]]; }
    ollama() { printf "%s\n" "${PSOUT}"; seq 1 400000; }
    ollama_processor qwen2.5-coder:7b || printf "(none)"
  ' _ "${REPO}/scripts/lib.sh" 2>/dev/null
}
check "a match early in a long listing is still reported (not 141)" \
  test "$(op_slow_producer "${PS_TWO}")" = "100% GPU"
no_ollama() { ! bash -c '
    set -uo pipefail
    source "$1"
    have() { return 1; }
    ollama_processor qwen2.5-coder:7b
  ' _ "${REPO}/scripts/lib.sh" 2>/dev/null; }
check "no ollama binary reports nothing rather than guessing" no_ollama

echo "# aider output quality: edit format per model size, repo map scaled to the window"
ef() { aider_edit_format "$1"; }
check "0.5b -> whole (tiny models cannot do diffs)" test "$(ef qwen2.5-coder:0.5b)" = "whole"
check "3b   -> whole"                               test "$(ef qwen2.5-coder:3b)"   = "whole"
check "4b   -> whole (boundary)"                    test "$(ef qwen3:4b)"           = "whole"
check "7b   -> diff (boundary+1)"                   test "$(ef qwen2.5-coder:7b)"   = "diff"
check "14b  -> diff"                                test "$(ef qwen2.5-coder:14b)"  = "diff"
check "unparseable tag falls back to diff"          test "$(ef weird-model)"        = "diff"
# The repo map must never crowd out the code being edited.
check "ctx 4096  -> 384 map tokens"  test "$(aider_map_tokens 4096)"  = "384"
check "ctx 8192  -> 768 map tokens"  test "$(aider_map_tokens 8192)"  = "768"
check "ctx 16384 -> 1536 map tokens" test "$(aider_map_tokens 16384)" = "1536"
map_under_prompt() { local in out; read -r in out < <(aider_token_budget "$1"); [[ "$(aider_map_tokens "$1")" -lt $(( in / 2 )) ]]; }
check "map stays well under the prompt budget (4096)"  map_under_prompt 4096
check "map stays well under the prompt budget (16384)" map_under_prompt 16384

echo "# MODEL_FAMILY: the ladder follows the configured family, with a safe fallback"
# shellcheck source=../scripts/tune.sh
source "${REPO}/scripts/tune.sh"
fam_pick() { MODEL_FAMILY="$1" choose_for_ram "$2"; printf '%s' "${TUNE_MODEL}"; }
check "default family, 16 GiB -> qwen2.5-coder:14b" test "$(fam_pick qwen2.5-coder 16)" = "qwen2.5-coder:14b"
check "qwen3 family, 12 GiB -> qwen3:8b"            test "$(fam_pick qwen3 12)"         = "qwen3:8b"
check "qwen3 family, 4 GiB -> qwen3:4b"             test "$(fam_pick qwen3 4)"          = "qwen3:4b"
check "codellama family, 24 GiB -> codellama:13b"   test "$(fam_pick codellama 24)"     = "codellama:13b"
# deepseek-coder-v2 ships only 16b, which cannot load on 8 GiB — the ladder
# must fall back rather than pull ~10 GB and then OOM on first use.
check "deepseek-coder-v2 on 8 GiB falls back" test "$(fam_pick deepseek-coder-v2 8 2>/dev/null)" = "qwen2.5-coder:3b"
check "deepseek-coder-v2 on 16 GiB is used"   test "$(fam_pick deepseek-coder-v2 16)" = "deepseek-coder-v2:16b"
# An unknown family must NOT be used verbatim — that would make tune.sh try to
# pull a tag that does not exist and fail every boot.
check "unknown family falls back to the default"    test "$(fam_pick not-a-real-model 16)" = "qwen2.5-coder:14b"
# A model auto-tune picks MUST fit the rung that picked it. At ~0.6 GB per
# billion params (q4) plus context, the 16-23 GiB rung tops out around 20B —
# so a 34b/70b/405b tag here would mean pulling tens of GB and then OOMing.
fits_rung() {
  local ram="$1" fam="$2" tag params
  tag="$(fam_pick "${fam}" "${ram}")"; tag="${tag##*:}"
  params="${tag%[bB]}"
  awk -v p="${params}" -v r="${ram}" 'BEGIN{ exit !(p * 0.6 + 1 <= r) }'
}
for f in qwen2.5-coder qwen3 deepseek-coder-v2 llama3.1 codellama; do
  check "auto-tune pick fits 8 GiB  (${f})"  fits_rung 8  "${f}"
  check "auto-tune pick fits 16 GiB (${f})"  fits_rung 16 "${f}"
done

echo "# tune ladder boundaries (spec: 8, 9, 15, 16, 23, 24 GiB)"
# tune.sh only runs main when executed; sourcing it exposes choose_for_ram().
# shellcheck source=../scripts/tune.sh
source "${REPO}/scripts/tune.sh"
ladder_is() {
  local ram="$1" model="$2" ctx="$3"
  choose_for_ram "${ram}"
  [[ "${TUNE_MODEL}" == "${model}" && "${TUNE_CTX}" == "${ctx}" ]]
}
check " 4 GiB -> 3b/4096"   ladder_is 4  qwen2.5-coder:3b  4096
check " 8 GiB -> 3b/4096"   ladder_is 8  qwen2.5-coder:3b  4096
check " 9 GiB -> 7b/8192"   ladder_is 9  qwen2.5-coder:7b  8192
check "15 GiB -> 7b/8192"   ladder_is 15 qwen2.5-coder:7b  8192
check "16 GiB -> 14b/8192"  ladder_is 16 qwen2.5-coder:14b 8192
check "23 GiB -> 14b/8192"  ladder_is 23 qwen2.5-coder:14b 8192
check "24 GiB -> 14b/16384" ladder_is 24 qwen2.5-coder:14b 16384
check "64 GiB -> 14b/16384" ladder_is 64 qwen2.5-coder:14b 16384

echo "# the boot run must warm the model on the PINNED path too, not just when tuning"
# Nothing else loads a model at boot: OLLAMA_KEEP_ALIVE stops a resident model
# being evicted, it never preloads one. warm_model at the end of main covers
# the auto-tune path — and both exits in the AUTO_TUNE=false branch returned
# before ever reaching it.
#
# That branch is not the unusual one. 'lca model' sets AUTO_TUNE=false for you,
# so it is where everyone who picked their own model ends up, and on a CPU-only
# host the cost is the whole first message: measured 60-90s for a 3B on 4 vCPU
# here, and warm_model's own comment records 228s for a 7B on a cold cache.
tune_pinned_run() {   # RESYNC_RC -> the run's output
  bash -c '
    set -uo pipefail
    source "$1"
    load_env() { :; }
    detect_ram_gib() { echo 16; }
    have() { return 0; }
    systemd_available() { return 1; }
    resync_dropin_if_drifted() { return '"$1"'; }
    warm_model() { printf "WARMED:%s\n" "$1"; }
    AUTO_TUNE=false
    MODEL_NAME=qwen2.5-coder:7b; OLLAMA_CONTEXT_LENGTH=8192; OLLAMA_KEEP_ALIVE=30m
    main
  ' _ "${REPO}/scripts/tune.sh" 2>&1 || true
}
# Both exits: nothing drifted, and the drop-in was re-synced (which restarts
# Ollama, dropping whatever was loaded — so warming after it is the point).
check "a pinned model with nothing to do is still warmed" \
  grep -q 'WARMED:qwen2.5-coder:7b' <<<"$(tune_pinned_run 1)"
check "...and so is one whose drop-in had to be re-synced" \
  grep -q 'WARMED:qwen2.5-coder:7b' <<<"$(tune_pinned_run 0)"
# The warm has to come AFTER the re-sync's restart, or it loads a model the
# restart then drops.
warm_follows_resync() {
  local out; out="$(tune_pinned_run 0)"
  local warm_line resync_line
  warm_line="$(grep -n 'WARMED:' <<<"${out}" | head -1 | cut -d: -f1)"
  resync_line="$(grep -n 'pinned settings' <<<"${out}" | head -1 | cut -d: -f1)"
  [[ -n "${warm_line}" && -n "${resync_line}" ]] || return 1
  (( warm_line > resync_line ))
}
check "the warm comes after the re-sync that restarts Ollama" warm_follows_resync

echo "# largest_present_within() — offline-downgrade fallback picks the largest model <= target"
# Stub model_present against a PRESENT list so we can unit-test the selection
# without a real ollama. (This override is intentional and only affects the
# checks below, which are the last in the file.)
PRESENT=""
model_present() { case " ${PRESENT} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
lpw() { PRESENT="$1" largest_present_within "$2"; }
check "target 14b, only 3b present -> 3b"       test "$(lpw 'qwen2.5-coder:3b' qwen2.5-coder:14b)" = "qwen2.5-coder:3b"
check "target 14b, 7b+3b present -> 7b"         test "$(lpw 'qwen2.5-coder:7b qwen2.5-coder:3b' qwen2.5-coder:14b)" = "qwen2.5-coder:7b"
check "target 14b, all present -> 14b"          test "$(lpw 'qwen2.5-coder:14b qwen2.5-coder:7b qwen2.5-coder:3b' qwen2.5-coder:14b)" = "qwen2.5-coder:14b"
check "target 7b, only 14b present -> none"     test -z "$(lpw 'qwen2.5-coder:14b' qwen2.5-coder:7b)"
check "target 7b, nothing present -> none"      test -z "$(lpw '' qwen2.5-coder:7b)"
lpw_fails() { ! ( PRESENT="$1" largest_present_within "$2" >/dev/null ); }
check "returns nonzero exit when nothing fits"  lpw_fails 'qwen2.5-coder:14b' qwen2.5-coder:7b

echo "# ollama_dropin_matches() — no false drift (else tune restarts Ollama every boot)"
# Render to a temp path (no root needed) and confirm the detector agrees the
# freshly-written drop-in matches, flags a real change, and treats a missing
# file as a mismatch.
dropin_drifted() { ! ollama_dropin_matches; }
DROP="$(mktemp)"
OLLAMA_DROPIN="${DROP}"
OLLAMA_HOST="127.0.0.1:11434"; OLLAMA_CONTEXT_LENGTH="8192"; OLLAMA_KEEP_ALIVE="30m"
render_ollama_dropin_content > "${DROP}"
check "freshly-rendered drop-in matches (no false drift)" ollama_dropin_matches
OLLAMA_CONTEXT_LENGTH="4096"   # simulate a tune decision that changed the context
check "a changed context is detected as drift" dropin_drifted
OLLAMA_CONTEXT_LENGTH="8192"
rm -f "${DROP}"
check "missing drop-in counts as a mismatch" dropin_drifted

echo "# a config file must never be half-replaced by a write that failed"
# 'producer | as_root tee DEST' opens DEST and TRUNCATES it before the producer
# has written a byte. Demonstrated by accident, on the real function: an unbound
# variable inside render_ollama_dropin_content left the drop-in holding its
# header and '[Service]' and nothing else — OLLAMA_HOST and the context length
# simply gone from a file that had been correct a second earlier.
#
# Nine files were written that way, and the systemd units are the ones that
# make it serious: systemd will not load a unit it cannot parse, and one of
# them re-applies the inbound guard at boot. A truncated copy of THAT means the
# WebUI and Ollama ports come back public at the next reboot.
WRF="${SANDBOX}/wrf"
rm -rf "${WRF}"; mkdir -p "${WRF}"
printf 'OLD CONTENT\n' > "${WRF}/f"
# The temp path is occupied by a directory, so tee cannot write it — a failure
# that lands for root as well, unlike an unwritable parent.
mkdir -p "${WRF}/f.lca-new"
wrf_write() { printf 'NEW CONTENT\n' | write_root_file "${WRF}/f"; }
# Its own wrapper rather than the suite's not_ok, which is not defined until
# further down this file.
wrf_write_fails() { ! wrf_write >/dev/null 2>&1; }
check "a write that cannot happen reports failure" wrf_write_fails
check "...and the old file is untouched" \
  test "$(cat "${WRF}/f")" = "OLD CONTENT"
rmdir "${WRF}/f.lca-new"
check "a good write replaces the content" wrf_write
check "...with what was actually sent" test "$(cat "${WRF}/f")" = "NEW CONTENT"
check "...at mode 0644 by default" test "$(stat -c %a "${WRF}/f")" = "644"
check "...honouring an explicit mode" \
  test "$(printf 'x\n' | write_root_file "${WRF}/g" 0600 && stat -c %a "${WRF}/g")" = "600"
wrf_no_leftovers() { ! compgen -G "${WRF}/*.lca-new" >/dev/null; }
check "...and leaving no temp file behind" wrf_no_leftovers
# ...and the renderer's own failure must be caught BEFORE the destination is
# touched, which is the half a pipeline cannot do for itself: nothing
# downstream can tell a producer that died early from one with little to say.
dropin_survives_a_failed_render() {
  local sb="${SANDBOX}/dropinfail" out
  rm -rf "${sb}"; mkdir -p "${sb}"
  printf 'GOOD DROPIN\n' > "${sb}/override.conf"
  out="$(bash -c '
    set -uo pipefail
    source "$1"; C_RED=""; C_RESET=""; C_GREEN=""
    OLLAMA_DROPIN_DIR="$2"; OLLAMA_DROPIN="$2/override.conf"
    render_ollama_dropin_content() { return 1; }   # the renderer fails
    render_ollama_dropin
  ' _ "${REPO}/scripts/lib.sh" "${sb}" 2>&1)" || true
  grep -q 'is unchanged' <<<"${out}" || {
    printf 'a failed render was not reported as leaving the file alone: %s\n' "${out}" >&2
    return 1
  }
  [[ "$(cat "${sb}/override.conf")" == "GOOD DROPIN" ]] || {
    echo "a failed render destroyed the existing drop-in" >&2
    return 1
  }
}
check "a failed render leaves the previous Ollama settings in place" \
  dropin_survives_a_failed_render
# ...and nothing may go back to piping straight at a root-owned file.
no_tee_into_a_root_file() {
  local hits
  hits="$(grep -rn 'as_root tee' "${REPO}"/*.sh "${REPO}"/scripts/*.sh \
            "${REPO}"/deploy/*.sh "${REPO}/bin/lca" 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' \
          | grep -v 'write_root_file() {' || true)"
  # lib.sh's own implementation is the one legitimate use: it tees into the
  # TEMP, which is the whole point.
  # '[$]{tmp}' rather than the literal, so this line is not itself an
  # unexpanded-expression finding — the same bracket idiom used elsewhere here.
  hits="$(grep -v 'as_root tee "[$]{tmp}"' <<<"${hits}" || true)"
  [[ -z "${hits}" ]] || {
    printf 'these truncate a root-owned file before knowing what to put in it:\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "no script tees straight into a root-owned file" no_tee_into_a_root_file

echo "# lib.sh defines HOME when unset (cloud-init / systemd oneshots — else ollama panics)"
home_set_when_unset() {
  (
    # Clear the double-source guard so the HOME logic re-runs, and unset HOME
    # to simulate the cloud-init / root-oneshot environment.
    unset HOME LCA_LIB_LOADED
    # shellcheck disable=SC1090
    source "${REPO}/scripts/lib.sh"
    [[ -n "${HOME:-}" ]]
  )
}
check "HOME is set after sourcing lib.sh with HOME unset" home_set_when_unset

echo "# run_reader() — probe once, then run; never retry a follow under sudo"
reader_ran() { test "$(run_reader true -- printf ran)" = "ran"; }
check "probe succeeds -> the real command runs" reader_ran
# The bug this replaced: 'run it, and on failure retry under sudo' restarts a
# 'logs -f' as root the moment the user presses Ctrl-C, because quitting a
# follow exits non-zero. Probing separately is what makes that impossible.
reader_skips() {
  local out
  out="$(run_reader false -- printf SHOULD-NOT-RUN 2>/dev/null || true)"
  [[ "${out}" != *SHOULD-NOT-RUN* ]]
}
check "probe fails -> the real command never runs" reader_skips
reader_status() { run_reader false -- true; }
not_ok() { ! "$@" >/dev/null 2>&1; }
check "probe fails -> nonzero exit" not_ok reader_status
# A malformed call must be loud, not silently run the wrong half.
check "no '--' separator -> usage error (2)" not_ok run_reader true echo hi
check "nothing after '--' -> usage error (2)" not_ok run_reader true --
# Arguments containing spaces must survive the split intact.
reader_keeps_spaces() { test "$(run_reader true -- printf '%s' 'two words')" = "two words"; }
check "arguments with spaces survive the split" reader_keeps_spaces

echo "# classify_gpu() — every GPU situation, testable on a machine with no GPU"
gpu_is() { test "$(classify_gpu "$2" "$3" "$4")" = "$1"; }
check "no card, no driver -> none"        gpu_is none      false false ""
# The silent case: the card is there, everything works, and it is 10x slower
# with no explanation offered anywhere.
check "card but no driver -> no-driver"   gpu_is no-driver true  false ""
check "driver but model on CPU -> idle"   gpu_is idle      true  true  "100% CPU"
check "partial offload -> split"          gpu_is split     true  true  "38%/62% CPU/GPU"
check "fully offloaded -> active"         gpu_is active    true  true  "100% GPU"
check "model not resident -> unknown"     gpu_is unknown   true  true  ""
# A driver can be present in a VM whose card is passed through and therefore
# invisible to lspci; trusting lspci alone would report 'none' with the GPU
# plainly working.
check "driver works though lspci sees nothing -> classified by placement" \
  gpu_is active false true "100% GPU"
# The case that actually bit. Ollama 0.32.5 prints a CPU/GPU split on a machine
# with NO card: measured on a host with no /dev/dri, no display device and no
# nvidia-smi, 'qwen2.5-coder:7b  5.1 GB  13%/87% CPU/GPU', running at 5.3
# tokens/second — CPU speed for 7b there. classify_gpu has always answered this
# correctly; both reporters decided from the string instead and told the reader
# to size a model to VRAM that does not exist.
check "no card, no driver, but ollama prints a split -> still none" \
  gpu_is none false false "13%/87% CPU/GPU"
check "no card, no driver, and ollama says GPU -> still none" \
  gpu_is none false false "100% GPU"
# ...and both reporters must ASK it rather than reading the string themselves.
# gpu_state_for_placement is classify_gpu plus this machine's card and driver,
# taking a placement the caller has already read — so one 'ollama ps' each, and
# the string a message quotes is the one that was classified.
check_classifies_the_placement() {
  awk '/^[[:space:]]*#/ { next }
       /gpu_state_for_placement/ { seen = NR }
       /only partially on the GPU/ {
         if (seen == 0 || NR - seen > 20) { print "unclassified GPU verdict at line " NR; bad = 1 }
         found = 1
       }
       END { exit (bad || !found || !seen) }' "${REPO}/check-system.sh"
}
check "'lca check' classifies placement instead of matching the string" \
  check_classifies_the_placement
speed_classifies_the_placement() {
  awk '/^[[:space:]]*#/ { next }
       /gpu_state_for_placement/ { seen = NR }
       /where="(split|gpu)"/ {
         if (seen == 0 || NR - seen > 6) { print "unclassified placement at line " NR; bad = 1 }
         found = 1
       }
       END { exit (bad || !found || !seen) }' "${REPO}/scripts/speed.sh"
}
check "'lca speed' classifies placement instead of matching the string" \
  speed_classifies_the_placement

echo "# vram_mib_from_smi() — picks the LARGEST card, not the first"
smi_gives() { test "$(printf '%s\n' "$2" | vram_mib_from_smi)" = "$1"; }
check "single 3090 -> 24576" smi_gives 24576 "24576"
# A small display adapter listed first would otherwise set every recommendation.
check "display adapter first, compute card second -> the big one" \
  smi_gives 24576 "2048
24576"
check "strips units if present" smi_gives 24576 "24576 MiB"
no_vram() { ! printf '%s\n' "$1" | vram_mib_from_smi >/dev/null 2>&1; }
check "no output (no driver) -> nonzero exit" no_vram ""
check "non-numeric output -> nonzero exit" no_vram "N/A"

echo "# largest_model_for_vram() — must fit COMPLETELY, spilling is the trap"
check "24 GB (RTX 3090) -> 37B" test "$(largest_model_for_vram 24576)" = "37"
check "12 GB -> 17B"            test "$(largest_model_for_vram 12288)" = "17"
check "8 GB -> 10B"             test "$(largest_model_for_vram 8192)" = "10"
no_fit() { ! largest_model_for_vram "$1" >/dev/null 2>&1; }
check "a 1 GB adapter fits nothing -> nonzero exit" no_fit 1024
check "non-numeric -> nonzero exit" no_fit abc

echo "# model_params_b() — parameter count read off the Ollama tag"
check "qwen2.5-coder:7b -> 7"   test "$(model_params_b qwen2.5-coder:7b)" = "7"
check "qwen2.5-coder:14b -> 14" test "$(model_params_b qwen2.5-coder:14b)" = "14"
check "deepseek-coder-v2:16b -> 16" test "$(model_params_b deepseek-coder-v2:16b)" = "16"
check "a fractional 1.5b rounds to a usable 2" test "$(model_params_b qwen2.5:1.5b)" = "2"
# A tag with no size must FAIL rather than return a wrong number: speed.sh
# multiplies this by 0.6 GB to report memory bandwidth, so a silent 0 or 1
# would print a confidently wrong figure.
# Negative cases go through a local helper, never 'bash -c': a child shell has
# not sourced lib.sh, so the function would be "command not found" (exit 127)
# and '!' would turn that into a pass — a test that cannot fail.
no_params_b() { ! model_params_b "$1" >/dev/null 2>&1; }
check "':latest' has no size -> nonzero exit" no_params_b qwen2.5-coder:latest
check "a bare name has no size -> nonzero exit" no_params_b mistral
check "'7b' inside the name is not a size tag" no_params_b llama3.1-7bfoo:latest

echo "# tokens_per_second() — rate from Ollama's own nanosecond counters"
check "19 tokens in 3.4987s -> 5.4/s" test "$(tokens_per_second 19 3498679000)" = "5.4"
check "100 tokens in exactly 1s -> 100.0/s" test "$(tokens_per_second 100 1000000000)" = "100.0"
# A zero duration would divide by zero; a divide-by-zero in awk prints 'inf'
# and the verdict would then read "inf tokens/second — working as intended".
no_tps() { ! tokens_per_second "$1" "$2" >/dev/null 2>&1; }
check "zero duration -> nonzero exit" no_tps 10 0
check "non-numeric duration -> nonzero exit" no_tps 10 abc

echo "# ...and the READING rate has to be measured on a prompt Ollama has not seen"
# 'lca speed' reported reading input at 160-213 tokens/second on a machine that
# reads at 20. Two faults, both in the prompt it measured with:
#
#   - it was a fixed 43-token string, so Ollama served the KV prefix out of
#     cache from the second run onward. The same 2,050-token prompt twice in a
#     row here: 104 seconds, then 0.
#   - 43 tokens is small enough that per-request overhead is most of it.
#
# An order of magnitude wrong, on the single number that explains why a code
# edit takes minutes. So the probe must differ every call and be big.
read_probe_is_uncacheable_and_big() {
  local a b
  a="$(read_probe_prompt)"; b="$(read_probe_prompt)"
  [[ "${a}" != "${b}" ]] || {
    echo 'read_probe_prompt is identical between calls — Ollama would serve it from cache' >&2
    return 1; }
  # The differing part must be at the HEAD: a nonce at the end leaves every
  # token before it cacheable, which is most of them.
  [[ "$(head -1 <<<"${a}")" != "$(head -1 <<<"${b}")" ]] || {
    echo 'the probe differs only after its first line, so the prefix is still cacheable' >&2
    return 1; }
  # ~600 tokens measured; bytes are the cheap proxy the test can check.
  (( "$(printf '%s' "${a}" | wc -c)" > 1500 )) || {
    echo 'the read probe is too small to measure anything but per-request overhead' >&2
    return 1; }
}
check "the read probe is uncacheable and big enough to mean something" \
  read_probe_is_uncacheable_and_big

echo "# ...and both rates turn into the one number the user came for"
check "2800 in at 20/s + 113 out at 4.8/s -> 163s" \
  test "$(aider_edit_seconds 20 4.8)" = "163"
check "a faster machine gets a smaller number" \
  test "$(aider_edit_seconds 40 12)" = "79"
no_estimate() { ! aider_edit_seconds "$1" "$2" >/dev/null 2>&1; }
# Same reason as the zero-duration case above: awk would print 'inf' and the
# line would read "one code edit ~inf".
check "a zero reading rate is refused, not divided by" no_estimate 0 4.8
check "a zero generation rate is refused too" no_estimate 20 0
check "seconds stay seconds below 90" test "$(human_duration 45)" = "45s"
check "...and become minutes above it" test "$(human_duration 163)" = "3 min"
check "...rounded, not truncated" test "$(human_duration 100)" = "2 min"
check "...and hours when it comes to that" test "$(human_duration 4000)" = "1 h 7 min"
check "a non-number is refused" test ! "$(human_duration abc 2>/dev/null)"
# ...and speed.sh has to actually use the new probe rather than re-reading the
# generation request's cached prefix, which is the bug this replaces.
speed_measures_reading_separately() {
  local body
  body="$(sed 's/#.*//' "${REPO}/scripts/speed.sh")"
  grep -q 'read_probe_prompt' <<<"${body}" || {
    echo 'speed.sh does not use the uncacheable probe, so its reading rate is a cache hit' >&2
    return 1; }
  # The printed rate must come from the PROBE's counters. Matched as the exact
  # call, with no alternation: the first version of this check allowed
  # 'read_count.*read_ns' too, and an unrelated 'if' line mentioning both
  # satisfied it — so swapping the counters back to the cached ones passed the
  # gate. Caught by mutation, not by reading it.
  # SC2016 is the intent, not a slip: the literal characters ${read_count} are
  # what has to appear in speed.sh's source. Expanding them here would search
  # for this test's own empty variables and match nothing, forever.
  # shellcheck disable=SC2016
  grep -qF 'tokens_per_second "${read_count}" "${read_ns}"' <<<"${body}" || {
    echo 'speed.sh computes its reading rate from something other than the probe' >&2
    return 1; }
  # ...and the cached counters must not be mined off the GENERATION response at
  # all, so there is nothing lying around to be picked up again by accident.
  # Anchored on '<<<"${response}"' specifically: the probe reads
  # prompt_eval_count too, legitimately, from its own reply.
  # shellcheck disable=SC2016  # ...and the same here, for ${response}.
  ! grep -q 'prompt_eval_[a-z]*.*<<<"${response}"' <<<"${body}" || {
    echo "speed.sh still reads the generation request's cached prompt counters" >&2
    return 1; }
  grep -q 'aider_edit_seconds' <<<"${body}" || {
    echo 'speed.sh measures both rates and still never says what an edit costs' >&2
    return 1; }
}
check "lca speed measures reading with the probe, and reports what an edit costs" \
  speed_measures_reading_separately
# ...and the trap has to be written down where someone hand-rolling this with
# curl will meet it. PERFORMANCE.md's own closing line is "a change you cannot
# measure is not an improvement", and it already warns about the cold-model
# direction — a rate 10x too LOW. The cache is the same error in the other
# direction and produced a number 10x too HIGH, which is the more dangerous
# one: it looks like good news.
performance_doc_warns_about_the_prompt_cache() {
  local doc="${REPO}/docs/PERFORMANCE.md" body
  body="$(cat "${doc}")"
  grep -qi 'cache' <<<"${body}" || {
    echo 'PERFORMANCE.md never mentions the prompt cache that made this 10x wrong' >&2
    return 1; }
  # Naming the cache is not enough: the reader has to be told what to DO, which
  # is to send something Ollama has not processed before.
  #
  # The term list is deliberately tight. It first included 'nonce', and a
  # mutation that removed the whole instruction still passed — because the word
  # survived in an explanatory aside about where to PUT one. A gate satisfied
  # by a sentence explaining the fix, rather than by the fix, is not a gate.
  grep -qiE 'not seen before|never seen|fresh prompt|a new prompt|uncacheable' <<<"${body}" || {
    echo 'PERFORMANCE.md names the cache but never says to measure with a prompt it has not seen' >&2
    return 1; }
}
check "PERFORMANCE.md warns that a repeated prompt measures the cache" \
  performance_doc_warns_about_the_prompt_cache

echo "# a hand-edited .env must fail with the file's name, not a file descriptor"
# Every document in this project tells the reader to edit this file — 'sed -i'
# on .env appears in YOUR-TURN.md, PHONE.md and the README — so a typo in it is
# a likely error, not an exotic one. Sourcing it happens through a process
# substitution, so bash reported the damage against /dev/fd/63:
#
#   /dev/fd/63: line 60: unexpected EOF while looking for matching `"'
#   /dev/fd/63: line 14: coder:7b: command not found
#
# ...followed by no banner at all, on every SSH login, with nothing anywhere
# saying the word '.env'.
# SC2031: shellcheck's flow analysis decides LCA_ENV_LINE_RE was "modified in a
# subshell" because load_env assigns inside one; it is a constant set at source
# time and read here, which is the whole point of holding it in a variable.
# shellcheck disable=SC2031
env_line_ok()  { grep -qE "${LCA_ENV_LINE_RE}" <<<"$1"; }
env_line_bad() { ! env_line_ok "$1"; }
check "a plain assignment is fine"        env_line_ok 'MODEL_NAME=qwen2.5-coder:7b'
check "an empty value is fine"            env_line_ok 'AIDER_VERSION='
check "a quoted value with spaces is fine" env_line_ok 'BACKUP_SCHEDULE="*-*-* 03:30:00"'
check "a comment is fine"                 env_line_ok '# this is a comment'
check "a blank line is fine"              env_line_ok ''
check "a trailing comment is fine"        env_line_ok 'WEBUI_PORT=3000   # the port'
check "'export' is tolerated"             env_line_ok 'export WEBUI_PORT=3000'
# ...and the three shapes a hand edit really produces.
check "an unterminated quote is refused"  env_line_bad 'WEBUI_PORT="3000'
check "an unquoted space is refused"      env_line_bad 'MODEL_NAME=qwen2.5 coder:7b'
# shellcheck disable=SC2016  # the backtick is the test data, not an expansion
check "command substitution is refused"   env_line_bad 'WEBUI_PORT=`id -u`'
# The shipped example has to satisfy its own rule, or first-run creates a .env
# that load_env then refuses.
example_env_is_valid() {
  local bad
  # shellcheck disable=SC2031  # same constant, same false positive
  bad="$(grep -nvE "${LCA_ENV_LINE_RE}" "${REPO}/.env.example" || true)"
  [[ -z "${bad}" ]] || {
    printf '.env.example does not satisfy the rule load_env enforces:\n%s\n' "${bad}" >&2
    return 1; }
}
check ".env.example passes the check load_env applies to it" example_env_is_valid
# ...and load_env must check BEFORE it sources, or the message never arrives.
load_env_validates_before_sourcing() {
  local body check_at source_at
  body="$(awk '/^load_env\(\) \{/ { inb = 1; next } inb && /^\}/ { exit } inb' \
            "${REPO}/scripts/lib.sh" | sed 's/#.*//')"
  check_at="$(grep -n 'LCA_ENV_LINE_RE' <<<"${body}" | head -1 | cut -d: -f1)"
  source_at="$(grep -n '^ *source ' <<<"${body}" | head -1 | cut -d: -f1)"
  [[ -n "${check_at}" ]] || {
    echo 'load_env sources .env without checking it is assignments only' >&2
    return 1; }
  [[ -n "${source_at}" ]] || {
    echo 'load_env no longer sources .env at all — this gate stopped watching' >&2
    return 1; }
  (( check_at < source_at )) || {
    echo 'load_env checks .env only after sourcing it, which is after the damage' >&2
    return 1; }
}
check "...and it checks before sourcing, not after" \
  load_env_validates_before_sourcing
# The two validators must stay different, and this pins the difference so
# nobody tidies them into one. env_file_is_inert() guards a .env that arrived
# in a tarball and is about to be sourced as ROOT, so it refuses '$' outright.
# LCA_ENV_LINE_RE guards the file the user typed, where an expansion is their
# business and has always worked — applying the tarball rule there would reject
# a config that is valid today.
the_two_env_rules_disagree_on_purpose() {
  local f="${SANDBOX}/expansion-env"
  # An expansion with no path in it: an earlier fixture used
  # PYTHON_BIN=$HOME/bin/python3, which is a real expansion and also exactly
  # the shape venv_python_is_the_only_source() forbids — that gate caught this
  # file, correctly, and the fixture was the thing that was wrong.
  # shellcheck disable=SC2016  # $USER must reach the file unexpanded
  printf 'WEBUI_NAME=$USER-box\n' > "${f}"
  # shellcheck disable=SC2016  # ...and unexpanded here too, for the same reason
  env_line_ok 'WEBUI_NAME=$USER-box' || {
    echo "load_env's rule now rejects an expansion in the user's own .env, which used to work" >&2
    return 1; }
  ! env_file_is_inert "${f}" || {
    echo 'env_file_is_inert now accepts an expansion — it guards a file from a tarball, sourced as root' >&2
    return 1; }
}
check "the hand-edit rule and the tarball rule are not the same rule" \
  the_two_env_rules_disagree_on_purpose

echo "# ...and a .env it cannot create is a warning, not a raw 'cp:' abort"
# setup.sh installs to /opt/local-code-agent as root and 'lca' is meant to run
# as an ordinary user, so a missing .env there hit an unguarded cp:
#
#   cp: cannot create regular file '/opt/local-code-agent/.env': Permission denied
#
# ...and the command then aborted under errexit, mid-load_env, having said
# nothing about what .env is or what to do. Measured as the 'ubuntu' user
# against a root-owned checkout.
#
# Continuing is the right answer, not dying: the branch beside it already
# treats a missing config as "use the built-in defaults", and every default is
# set a few lines further down the same function.
load_env_survives_an_uncreatable_env() {
  local body
  body="$(awk '/^load_env\(\) \{/ { inb = 1; next } inb && /^\}/ { exit } inb' \
            "${REPO}/scripts/lib.sh" | sed 's/#.*//')"
  # No 'grep ... | head -1' here: head leaves after its line and the grep takes
  # SIGPIPE, which is the same 141-under-pipefail trap this suite bans
  # elsewhere. grep -q answers the question without a pipe at all.
  # shellcheck disable=SC2016  # the literal ${ENV_EXAMPLE} is what we search for
  grep -q 'cp "${ENV_EXAMPLE}"' <<<"${body}" || {
    echo 'load_env no longer creates .env from the example — this gate stopped watching' >&2
    return 1; }
  # The copy must be a tested condition, not a bare statement that errexit
  # turns into an abort.
  grep -qE '(if|elif|\|\||&&|!) *cp "\$\{ENV_EXAMPLE\}"' <<<"${body}" || {
    echo "load_env runs the copy unguarded, so a read-only checkout aborts on a raw 'cp:' line" >&2
    return 1; }
  # ...and the failure arm must say what to do rather than only that it failed.
  grep -q 'chown' <<<"${body}" || {
    echo 'load_env reports it could not write .env without naming the fix' >&2
    return 1; }
  # ...and must not be fatal.
  ! grep -qE 'die .*ENV_FILE.*cannot write|die .*Could not create' <<<"${body}" || {
    echo 'a .env that cannot be created should fall back to defaults, not stop the command' >&2
    return 1; }
}
check "load_env warns and keeps going when it cannot write .env" \
  load_env_survives_an_uncreatable_env

echo "# the shared system prompt (phone chat + 'lca ask' must agree)"
check "system prompt is non-empty" test -n "$(lca_system_prompt)"
# Run greps through a helper: 'bash -c' would start a child shell that has
# never sourced lib.sh, so lca_system_prompt would be missing there.
prompt_says() { lca_system_prompt | grep -qi -- "$1"; }
check "system prompt tells the model it is private" prompt_says "leaves that machine"
check "system prompt forbids inventing flags" prompt_says "never invent"

# The prompt advertises 'lca' subcommands to the model. If one of them is
# renamed in bin/lca and not here, the assistant confidently teaches a command
# that does not exist — the exact failure the prompt itself warns against.
# Extract every "  lca <word>" line and require bin/lca to actually dispatch it.
# Defined ABOVE its caller, and that is not style. It started below the
# 'check' line that runs prompt_commands_all_real, so at call time the
# function did not exist, the process substitution produced nothing, the loop
# body never ran and the gate passed having compared zero commands. A mutation
# putting a fake command in the prompt came back green — which is how it was
# found, and the reason mutations are run at all.
prompt_lca_commands() {
  lca_system_prompt | grep -oE '\blca [a-z][a-z-]*' | awk '{ print $2 }' | sort -u
}

prompt_commands_all_real() {
  local sub bad=0
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    # bin/lca dispatches via a case statement: 'ask)', 'offline|online|...)' or
    # 'help|-h|--help)'. The character class must allow '-' and '"', or a
    # command sharing a branch with a dashed alias reads as missing and this
    # test fails for a command that is perfectly real.
    grep -qE "^[[:space:]]*[a-z|\"-]*\b${sub}\b[a-z|\"-]*\)" "${REPO}/bin/lca" || {
      printf 'system prompt advertises unknown command: lca %s\n' "${sub}" >&2
      bad=1
    }
  done < <(prompt_lca_commands)
  return "${bad}"
}
check "every 'lca' command named in the system prompt exists in bin/lca" prompt_commands_all_real
# ...and the scanner has to SEE the whole prompt, which it did not.
#
# It was 's/^  lca \(...\)/' — only a line beginning with exactly two spaces
# and 'lca '. The prompt names twelve commands and that pattern found ten:
#
#   'lca ask'                          quoted, mid-sentence, line 17
#   lca offline ... ; lca online ...   second one mid-line, line 41
#
# Both are real commands, so nothing was broken — but rename either and the
# prompt would go on advertising it with this gate green, which is the exact
# failure it exists to prevent, on the command its handover rule leans on
# hardest. Same class as the baked-settings scanner's blind spot: a gate whose
# reach is invisible is worse than no gate.
#
# Deliberately broad now — every 'lca <word>' anywhere. If prose ever says
# something like "lca writes files", this fails, and that is right: a MODEL
# reads this prompt, and an unquoted verb after 'lca' is exactly how it learns
# to tell someone a command that does not exist.
prompt_scanner_sees_the_whole_prompt() {
  local found bad=0 want
  found="$(prompt_lca_commands)"
  # The two the old pattern could not reach, asserted by name so a future
  # narrowing is caught rather than silently shrinking the gate above.
  for want in ask online; do
    grep -qx "${want}" <<<"${found}" || {
      printf "the prompt scanner cannot see 'lca %s' — it is named in the prompt\n" "${want}" >&2
      bad=1
    }
  done
  # ...and it must not invent commands either: everything it yields has to
  # appear in the prompt after the word 'lca'.
  local sub
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    lca_system_prompt | grep -qE "\blca ${sub}\b" || {
      printf "the scanner produced '%s', which the prompt never names\n" "${sub}" >&2
      bad=1
    }
  done <<<"${found}"
  return "${bad}"
}
check "...and the prompt scanner reads quoted and mid-line mentions too" \
  prompt_scanner_sees_the_whole_prompt
# A real deployment asked the phone chat to "build the whole functioning
# project". The 3b model emitted a fabricated tool call —
# {"name": "build_expense_tracker", "arguments": {...}} — then refused with
# "I'm limited ... due to the constraints of my design and training", then
# drifted into NLP complexity and WCAG for what was a local expense tracker.
# Nothing in the prompt had told it what it is, so it invented tools it does
# not have and gave a vague excuse instead of the true, actionable answer.
prompt_forbids_tool_calls() {
  local p; p="$(lca_system_prompt)"
  grep -qi 'no tools' <<<"${p}" && grep -qi 'never emit a function' <<<"${p}"
}
check "system prompt tells the model it has no tools" prompt_forbids_tool_calls
# The prompt is not free. It is re-read on EVERY message, out of the 4096-token
# window the 3b rung runs with, so each paragraph is rent charged per turn for
# the life of the install — and it is the one cost that never shows up in a
# test, a log or a benchmark.
#
# It doubled once already, 328 -> 656 tokens, before anyone noticed: 16% of
# that window handed to instructions on every single turn. The fix then was to
# cut what measurement showed did not work, which is only possible if someone
# is watching the number. Nobody was.
#
# ~4 characters per token is rough but stable for English prose, and the point
# is a ceiling, not an estimate. 15% of 4096 leaves real headroom while making
# a doubling impossible to land quietly.
#
# The heuristic has since been checked against the real tokenizer rather than
# left as an assertion: the shipped prompt is 2,255 characters, this estimates
# 563 tokens, and ollama reports prompt_eval_count=559 for it on the 3b model.
# Within one percent, in the safe direction.
prompt_fits_its_budget() {
  local chars tokens cap
  chars="$(lca_system_prompt | wc -c)"
  tokens=$(( chars / 4 ))
  cap=$(( 4096 * 15 / 100 ))
  (( tokens <= cap )) || {
    printf 'the system prompt is ~%s tokens (%s chars) — over the %s-token budget, which is 15%%%% of the 4096 context the 3b rung runs with\n' \
      "${tokens}" "${chars}" "${cap}" >&2
    return 1
  }
}
check "the system prompt stays inside its share of a 4096-token context" \
  prompt_fits_its_budget
# ...and sends project work to the ONE command that can write files. The first
# version of this fix said only "the terminal agent", and the model duly
# suggested 'lca ask' — which is also text-only. Caught by running it.
# Asserted on meaning, not on a phrase. The first version keyed off the
# literal "NOT " that happened to be in draft one, and went red the moment the
# wording was strengthened — a test that guards a sentence rather than a
# contract. What must remain true: the prompt names bare 'lca' as the thing
# that writes files, and explicitly rules 'lca ask' out for that job.
# The shape of the copy-pasteable handover line, defined ONCE because both
# gates below match on it. Written out twice they promptly drifted together in
# the wrong direction: both anchored the line on STARTING with 'cd', and both
# went red the moment the recipe grew a 'mkdir -p' in front of it. That prefix
# was not cosmetic — a user whose first message is "build me an app" has no
# ~/my-project, so the command the chat now gives them every time died on
# "cd: No such file or directory" before aider ever ran.
#
# So the contract is not the first word. It is: ONE copy-pasteable line that
# enters a project directory and ends in the BARE word 'lca'. Anything may
# precede the cd; nothing may follow the lca.
HANDOVER_LINE='^[[:space:]]*(.*&&[[:space:]]*)?cd [^&]*&&[[:space:]]*lca[[:space:]]*$'
prompt_names_the_file_writing_command() {
  local p mentions negated
  p="$(lca_system_prompt)"
  grep -qE "${HANDOVER_LINE}" <<<"${p}" || return 1
  # And 'lca ask' may never appear un-negated. The model reads every line; one
  # neutral mention next to a file-writing request is all it took last time.
  mentions="$(grep -c 'lca ask' <<<"${p}")"
  (( mentions > 0 )) || return 1
  negated="$(grep 'lca ask' <<<"${p}" \
    | grep -ciE "never|nothing|not |no file|text only|touches no")"
  [[ "${mentions}" == "${negated}" ]]
}
check "system prompt distinguishes 'lca' from 'lca ask' for file work" \
  prompt_names_the_file_writing_command
# That pattern IS the gate now, and loosening it to admit a new recipe shape is
# precisely how a gate quietly stops gating. So assert what it accepts and what
# it refuses, against the forms this has actually taken and gone wrong as.
handover_pattern_discriminates() {
  local s
  # Named 'accepts'/'rejects', not 'good'/'bad': other functions in this file
  # use a scalar 'bad' as an error flag, and ShellCheck tracks a name's type
  # across the whole file — an array called 'bad' here turns those into
  # SC2178/SC2128 warnings pages away.
  local -a accepts=(
    "  cd ~/my-project && lca"
    "  mkdir -p ~/my-project && cd ~/my-project && lca"
  )
  local -a rejects=(
    "  cd ~/my-project && lca ask"      # the bug this gate was born for
    "  mkdir -p ~/my-project && lca"    # never entered the project directory
    "  cd ~/my-project"                 # never reached aider
    "  lca"                             # no directory at all
  )
  for s in "${accepts[@]}"; do
    grep -qE "${HANDOVER_LINE}" <<<"${s}" || {
      printf 'the handover pattern rejects a valid recipe: %s\n' "${s}" >&2
      return 1
    }
  done
  for s in "${rejects[@]}"; do
    if grep -qE "${HANDOVER_LINE}" <<<"${s}"; then
      printf 'the handover pattern accepts a broken recipe: %s\n' "${s}" >&2
      return 1
    fi
  done
}
check "the handover pattern accepts the real recipe and refuses the broken ones" \
  handover_pattern_discriminates
# And the recipe must work for someone who does not have the directory yet —
# which is most of the people who trigger it, since the trigger is "build me
# something". Run the line the prompt actually gives, in a throwaway HOME.
handover_recipe_actually_runs() {
  local line home rc
  line="$(lca_system_prompt | grep -E "${HANDOVER_LINE}" | head -1)"
  [[ -n "${line}" ]] || return 1
  home="${SANDBOX}/fakehome"
  rm -rf "${home}"; mkdir -p "${home}"
  # 'lca' itself needs Ollama and aider, so stub it: what is under test is
  # everything BEFORE it — the part that used to die on "cd: No such file or
  # directory" before aider was ever reached.
  HOME="${home}" bash -c "lca() { :; }; ${line}" >/dev/null 2>&1
  rc=$?
  (( rc == 0 )) || {
    printf 'the recipe the chat hands out fails in a fresh HOME (exit %s): %s\n' \
      "${rc}" "${line}" >&2
    return 1
  }
}
check "the handover recipe runs in a home that has no project directory yet" \
  handover_recipe_actually_runs
# The reader is on a PHONE, inside a chat app with no terminal in it, so a bash
# block is only actionable once they know where it goes. Measured on 3b: only
# 1 answer in 6 mentioned a terminal, SSH or the server at all.
#
# Telling the model to SAY so barely helped — 0/6 to 1/6. Putting the same
# words INSIDE the block it copies took it to 5/6, at no cost to how faithfully
# the command itself came through. That is the rule this asserts: for a small
# model, the payload travels in what it copies, not in an instruction about
# what to narrate.
#
# A '#' line, so it stays paste-safe: it is a valid shell comment.
handover_block_says_where_it_runs() {
  lca_system_prompt | awk -v pat="${HANDOVER_LINE}" '
    { hist[NR] = tolower($0) }
    $0 ~ pat {
      # The line immediately above must be a comment naming where it runs.
      if (hist[NR-1] ~ /^[[:space:]]*#/ &&
          (hist[NR-1] ~ /terminal|ssh|server|shell/)) found = 1
    }
    END { exit !found }'
}
check "the handover block says where to run it, inside the block" \
  handover_block_says_where_it_runs

echo "# a flag a script accepts but 'lca' never mentions is a hidden feature"
# update-model.sh takes --list-recommended, which answers "what model fits this
# machine's RAM?" — the question auto-tune exists for. It appeared in its own
# usage text and in docs/PERFORMANCE.md, and nowhere a user of 'lca' would look:
# 'lca model' mentioned only --list. Same shape as 'lca harden', which was
# dispatched and undocumented; the front door has to name what the tools behind
# it can do, or it is not a front door.
model_flags_are_discoverable() {
  local flag helptext
  helptext="$("${REPO}/bin/lca" help 2>/dev/null)"
  while read -r flag; do
    [[ -n "${flag}" ]] || continue
    grep -qF -- "${flag}" <<<"${helptext}" || {
      printf "update-model.sh accepts %s but 'lca help' never mentions it\\n" "${flag}" >&2
      return 1
    }
  done < <(grep -oE '^\s+--[a-z-]+\)' "${REPO}/update-model.sh" | tr -d ' )' | sort -u)
}
check "'lca help' names every flag update-model.sh accepts" \
  model_flags_are_discoverable

echo "# every example in 'lca help' must actually work"
# The help has advertised "lca --no-auto-commits (arguments for aider)" since
# it was written, and it did not work: a leading dash matched no branch in the
# dispatcher and fell through to "Unknown command". Nobody noticed because the
# gate that keeps help honest checks the COMMANDS in the list, and this lives
# in the examples underneath it.
#
# Asserted on the dispatcher, not by running aider: starting it needs a model.
help_examples_are_dispatched() {
  local src="${REPO}/bin/lca"
  # A dashed argument must route somewhere real...
  grep -qE '^\s*-\*\)\s*exec .*run-agent\.sh' "${src}" || {
    echo "bin/lca has no branch for a leading-dash argument, but 'lca help' shows one" >&2
    return 1
  }
  # ...after the help branch, or -h and --help would start aider instead.
  awk '/help\|-h\|--help\)/ { helpline = NR }
       /^  -\*\)/           { dashline = NR }
       END { exit !(helpline && dashline && helpline < dashline) }' "${src}" || {
    echo "the dash branch precedes the help branch — 'lca --help' would start aider" >&2
    return 1
  }
  # And an unknown NON-dashed command must still be refused.
  grep -qE 'Unknown command' "${src}" || {
    echo "bin/lca no longer refuses unknown commands" >&2
    return 1
  }
}
check "'lca <aider-flag>' reaches aider, as 'lca help' promises" \
  help_examples_are_dispatched

echo "# docs/INSTALL.md's numbered list is a claim about the ORDER"
# "What setup.sh does, in order" is the only place a reader can find out what
# the twenty minutes are spent on, and the order is the content. Guarding
# install_docker.sh moved it two places without meaning to, and nothing
# noticed — the list said Docker third while setup ran it fifth.
#
# Both sides derived. setup.sh names a guarded installer twice, once in the
# 'if !' and once in the retry advice beside it, so adjacent repeats collapse.
install_doc_order_matches_setup() {
  local doc code
  doc="$(sed -n '/^### What setup.sh does, in order/,/^Re-running/p' "${REPO}/docs/INSTALL.md" \
    | grep -oE 'scripts/install_[a-z_]+\.sh' | paste -sd' ' -)"
  code="$(sed 's/#.*//' "${REPO}/setup.sh" \
    | grep -oE 'scripts/install_[a-z_]+\.sh' | uniq | paste -sd' ' -)"
  [[ -n "${doc}" ]] || { echo 'could not find the ordered list in docs/INSTALL.md' >&2; return 1; }
  [[ -n "${code}" ]] || { echo 'could not find the installer calls in setup.sh' >&2; return 1; }
  [[ "${doc}" == "${code}" ]] || {
    printf 'INSTALL.md documents: %s\nsetup.sh actually runs: %s\n' "${doc}" "${code}" >&2
    return 1
  }
}
check "docs/INSTALL.md lists the installers in the order setup.sh runs them" \
  install_doc_order_matches_setup

echo "# an optional component may not abort the whole install"
# setup.sh already said this about the chat app: "A WebUI failure must NOT
# abort the rest of setup — the terminal stack still works". Tailscale and
# Docker were bare, and both are optional by the same argument — .env has a
# switch for each, and neither is needed by aider, 'lca ask', the boot
# services or the inbound guard. So a transient network blip during the
# Tailscale installer, or a Docker repo hiccup, ended the install before the
# 'lca' command, the login banner, the boot services and 'netmode.sh harden'
# were in place. Setup still reports failure at the end; it just finishes
# everything it can first.
#
# The list is derived from .env.example's own off-switches — SKIP_X / ENABLE_X
# become install_x.sh — so a future SKIP_FOO is covered without editing this.
optional_installers_are_not_fatal() {
  local key name script bad=0 line found=0
  while read -r key; do
    [[ -n "${key}" ]] || continue
    name="$(printf '%s' "${key#*_}" | tr '[:upper:]' '[:lower:]')"
    script="install_${name}.sh"
    [[ -f "${REPO}/scripts/${script}" ]] || continue
    found=$(( found + 1 ))
    # The call has to be a tested one: 'if ! .../install_x.sh' or '|| warn'.
    line="$(sed 's/#.*//' "${REPO}/setup.sh" | grep -F "scripts/${script}" | head -1)"
    [[ -n "${line}" ]] || {
      printf 'setup.sh never runs %s, though .env has a %s switch for it\n' "${script}" "${key}" >&2
      bad=1; continue
    }
    if [[ "${line}" != *'if !'* && "${line}" != *'||'* ]]; then
      printf '%s aborts the whole install on failure, but %s makes it optional:\n  %s\n' \
        "${script}" "${key}" "${line}" >&2
      bad=1
    fi
  done < <(grep -oE '^(SKIP|ENABLE)_[A-Z_]+' "${REPO}/.env.example" | sort -u)
  # An extractor that matched nothing passes every gate built on it. Measured:
  # stripping the SKIP_/ENABLE_ keys out of .env.example left this reporting ok.
  (( found > 0 )) || {
    echo 'no SKIP_/ENABLE_ switch in .env.example resolves to an installer — this stopped watching anything' >&2
    return 1
  }
  return "${bad}"
}
check "an optional component's installer cannot abort setup" \
  optional_installers_are_not_fatal

# ...and no remote installer may be streamed into a shell without a retry.
# install_ollama.sh has retried since a CDN reset cost a whole run; the note
# beside it says so. install_tailscale.sh ran the identical 'curl | sh' bare,
# under 'set -o pipefail', so one blip exited the script with no message and,
# until the change above, took the rest of setup with it. Two copies of a
# pattern, one of them carrying the lesson.
remote_installers_retry() {
  local f hits bad=0
  for f in "${REPO}"/scripts/*.sh "${REPO}"/*.sh; do
    hits="$(sed 's/#.*//' "${f}" | awk '
      /for attempt in/ { loop = NR }
      /curl .*\| *(as_root )?sh$/ {
        if (loop == 0 || NR - loop > 8) printf "  %d: %s\n", NR, $0 }')"
    [[ -z "${hits}" ]] || {
      printf '%s streams a remote installer into a shell with no retry:\n%s\n' \
        "${f##*/}" "${hits}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "every remote installer piped into a shell is retried" remote_installers_retry

echo "# the four places that make a checkout runnable must agree on what to chmod"
# setup.sh, update.sh, install.sh and deploy/do-user-data.sh each re-apply the
# executable bit after obtaining the code. install.sh was the only one that
# left out bin/ — where the 'lca' command lives — and it is the one whose
# LCA_RUN_SETUP=false path hands over to a setup.sh the user runs by hand, so
# nothing else was going to re-apply it. Derived and compared, because four
# copies of a glob list is four chances to fix three of them.
#
# The docs are in the list too, and they are where it bit twice more:
# README.md's manual-install recipe said bin/*, INSTALL.md's and MIGRATE.md's
# did not — the same instruction, typed by a human, in three places, two of
# them short. Seven copies now, all compared.
chmod_lists_agree() {
  local f line first="" first_file="" list bad=0
  for f in setup.sh update.sh install.sh deploy/do-user-data.sh \
           README.md docs/INSTALL.md docs/MIGRATE.md; do
    line="$(grep -hE 'chmod \+x .*\.sh' "${REPO}/${f}" | head -1)"
    [[ -n "${line}" ]] || { printf '%s no longer re-applies the executable bit\n' "${f}" >&2; return 1; }
    # Normalise away the variable prefix and any sudo/redirect noise; what is
    # compared is WHICH directories get the bit. Written so a shell line
    # ("${SCRIPT_DIR}"/scripts/*.sh) and a doc line (scripts/*.sh) reduce to
    # the same thing.
    list="$(printf '%s\n' "${line}" | sed 's/"\${[A-Za-z_]*}"//g' \
      | grep -oE '(scripts/\*\.sh|bin/\*|\*\.sh)' | sort -u | paste -sd' ' -)"
    if [[ -z "${first}" ]]; then first="${list}"; first_file="${f}"
    elif [[ "${list}" != "${first}" ]]; then
      printf '%s chmods {%s}, but %s chmods {%s}\n' "${f}" "${list}" "${first_file}" "${first}" >&2
      bad=1
    fi
  done
  return "${bad}"
}
check "every installer makes the same files executable" chmod_lists_agree

# ...and only ONE of them may teach what to do next. install.sh printed four
# lines of its own after setup.sh returned — "Health check :
# <dir>/check-system.sh", "Code with it : cd <your-project> &&
# <dir>/run-agent.sh" — directly below setup.sh's nine numbered steps, which
# say 'lca check' and 'cd <your-project> && lca'. Two vocabularies for the same
# commands, side by side, in the first thing a new user ever reads. The last of
# them also contradicted the handover recipe the assistant is gated to emit.
installer_does_not_reteach_next_steps() {
  local after t
  after="$(awk '/setup\.sh" <\/dev\/null/ { inb = 1; next } inb' "${REPO}/install.sh" \
    | sed 's/#.*//')"
  [[ -n "${after}" ]] || {
    echo 'install.sh no longer hands over to setup.sh' >&2; return 1; }
  for t in "${LCA_TARGETS[@]}" run-agent.sh; do
    if grep -qF "${t}" <<<"${after}"; then
      printf 'install.sh names %s after setup.sh has already printed its next steps\n' \
        "${t}" >&2
      return 1
    fi
  done
  return 0
}
check "only setup.sh teaches the next steps" installer_does_not_reteach_next_steps

echo "# saving state may not kill the command that already did its work"
# ~/.cache/local-code-agent is created by whichever of 'lca ask' and 'lca speed'
# runs first, and becomes root-owned the moment either is run once under sudo.
# Every non-root run then died on the write, bare under 'set -e': 'lca ask'
# after printing a perfect answer, 'lca speed' between the numbers and the
# section that says what they mean. Both exited non-zero having apparently just
# worked. The saved state is a nicety; the output is the command.
#
# Three-line window because these writes wrap, and 'if !' can be two lines
# above its redirect. Comments stripped first, as everywhere else here.
#
# The variable names are DERIVED per file, not listed. The first version of
# this carried a hand-typed set of four — and missed run-agent.sh, the headline
# command, which writes aider's model metadata into the very same directory and
# died there for the very same reason. A gate against hand-typed lists that
# itself hand-typed a list.
cache_writes_cannot_abort() {
  local f hits bad=0 roots n more names
  for f in "${REPO}"/scripts/*.sh "${REPO}"/*.sh; do
    # Variables assigned a path under ~/.cache/local-code-agent...
    roots="$(sed 's/#.*//' "${f}" \
      | grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*\.cache/local-code-agent' \
      | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | sort -u || true)"
    [[ -n "${roots}" ]] || continue
    # ...and the ones built out of those (BASELINE from STATE_DIR, and so on).
    for n in ${roots}; do
      more="$(sed 's/#.*//' "${f}" \
        | grep -E "^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?[$]\{${n}\}" \
        | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' || true)"
      roots="${roots}"$'\n'"${more}"
    done
    names="$(printf '%s\n' "${roots}" | sed '/^$/d' | sort -u | paste -sd'|' -)"
    hits="$(sed 's/#.*//' "${f}" | awk -v names="${names}" '{ a = b; b = c; c = $0 }
      c ~ ("(mkdir -p|>)[ ]*\"\\$\\{(" names ")") {
        w = a " " b " " c
        if (w !~ /\|\|/ && w !~ /if !/) printf "  %d: %s\n", NR, c }')"
    [[ -z "${hits}" ]] || {
      printf '%s writes cached state bare under set -e:\n%s\n' "${f##*/}" "${hits}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "cached state is written without risking the run" cache_writes_cannot_abort

# "Not readable" is not "not there", and the two need opposite advice. 'lca
# logs' tested -r on the install log and then called the absence normal — so on
# a box where that root-written log is not world-readable it announced that a
# file sitting right there did not exist, and the reader stopped looking. The
# other two sources have always escalated through run_reader.
logs_setup_tells_the_two_apart() {
  local body
  body="$(awk '/^logs_setup\(\) \{/ { inb = 1; next } inb && /^\}/ { exit } inb' \
            "${REPO}/scripts/logs.sh" | sed 's/#.*//')"
  grep -q 'run_reader' <<<"${body}" || {
    echo 'logs.sh reads the install log without escalating, unlike its two siblings' >&2
    return 1; }
  # The "normal, nothing to see" message belongs to absence alone.
  grep -qE '\[\[ ! -e ' <<<"${body}" || {
    echo 'logs.sh still decides "no install log" from readability rather than existence' >&2
    return 1; }
  ! grep -qE '\[\[ ! -r ' <<<"${body}"
}
check "'lca logs' separates an unreadable install log from a missing one" \
  logs_setup_tells_the_two_apart

echo "# ...and on a host with no systemd it must read the log THIS project wrote"
# start_ollama_bg() is what runs Ollama where there is no service manager —
# containers and WSL, which its own comment names as the reason it exists — and
# it redirects into OLLAMA_BG_LOG under 'nohup ... &'. logs.sh answered "check
# the terminal you started 'ollama serve' in", which is wrong twice over there:
# this project started it, and a nohup'd process has no terminal. Meanwhile the
# log was sitting next to the script. That is the command the login banner and
# TROUBLESHOOTING.md both point at when Ollama misbehaves, so the one host type
# without a journal is the one that most needs an answer.
logs_ollama_reads_the_background_log() {
  local body
  body="$(awk '/^logs_ollama\(\) \{/ { inb = 1; next } inb && /^\}/ { exit } inb' \
            "${REPO}/scripts/logs.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo 'could not find logs_ollama — this gate stopped watching' >&2; return 1; }
  grep -q 'OLLAMA_BG_LOG' <<<"${body}" || {
    echo "'lca logs ollama' never looks at the background log this project writes" >&2
    return 1; }
  # ...and actually prints it, rather than only naming it in a hint.
  grep -qE 'tail .*OLLAMA_BG_LOG' <<<"${body}" || {
    echo "'lca logs ollama' names the background log but never reads it out" >&2
    return 1; }
}
check "'lca logs ollama' reads the background log where there is no journal" \
  logs_ollama_reads_the_background_log
# ...and the path itself must exist in exactly one place. It was written as a
# literal inside start_ollama_bg while logs.sh knew nothing about it, which is
# precisely how the two drifted.
ollama_bg_log_path_is_named_once() {
  local hits
  hits="$(grep -rn '\.ollama-serve\.log' "${REPO}"/scripts/*.sh "${REPO}"/*.sh 2>/dev/null \
            | grep -v 'OLLAMA_BG_LOG=' | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [[ -z "${hits}" ]] || {
    printf 'the background-log path is written out again instead of using OLLAMA_BG_LOG:\n%s\n' "${hits}" >&2
    return 1; }
}
check "...and that path is spelled out in exactly one place" \
  ollama_bg_log_path_is_named_once

# 'lca ask' streams the answer through a pipeline. Bare under 'set -o pipefail'
# that pipeline was the last statement of main, so a curl that died mid-answer
# — the 600s cap, or Ollama being OOM-killed by the model it just loaded — took
# the whole command down silently: half an answer, no error, and a non-zero
# status nothing explained. speed.sh has always said so on the same failure.
ask_reports_a_cut_short_answer() {
  local body
  body="$(sed 's/#.*//' "${REPO}/scripts/ask.sh")"
  # The pipeline's status has to be captured...
  grep -qE 'tee "[$]\{answer_tmp\}" \|\| [a-z_]+=[$]\?' <<<"${body}" || {
    echo 'ask.sh runs the answer pipeline bare — a truncated answer exits silently' >&2
    return 1; }
  # ...and acted on, not just stored.
  grep -qE '\(\( *stream_rc *!= *0 *\)\)' <<<"${body}"
}
check "'lca ask' says so when the answer was cut short" ask_reports_a_cut_short_answer
# ...and it must say something BEFORE the answer starts, when the model has to
# be loaded first.
#
# Streaming solves the second half of the wait — tokens appearing as they are
# generated, which ask.sh's own comment calls "the difference between working
# and hung". It cannot touch the first half: an unloaded model produces no
# token at all until it is in memory. Measured on a 4-vCPU host with no GPU,
# 88s to load a 3B and 64s for a 0.5B, and warm_model records 228s for a 7B on
# a cold page cache. That silence arrives before the stream can start, and it
# is invisible on a GPU box where the first token lands in about a second.
ask_announces_a_cold_load() {
  local body
  body="$(sed 's/#.*//' "${REPO}/scripts/ask.sh")"
  # Asked, so the message appears only when it is true — on a resident model
  # the first token is immediate and this would be noise on every question.
  grep -q 'ollama_processor' <<<"${body}" || {
    echo 'ask.sh never checks whether the model is already resident, so it cannot know if the wait is coming' >&2
    return 1; }
  # stderr, or it lands in the answer. README documents
  # 'lca logs | lca ask "why did this fail?"', and answers get redirected.
  #
  # Continuations joined first: the redirect sits on the line AFTER the printf,
  # so a line-scoped grep sees the two separately and matches with the '>&2'
  # deleted — which is exactly the mutation that walked through the first
  # version of this check.
  local joined
  joined="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' <<<"${body}")"
  grep -qE "printf 'Loading %s.*>&2" <<<"${joined}" || {
    echo 'the cold-load notice is not printed to stderr, so it would contaminate the answer' >&2
    return 1; }
  # And it must come before the request, not after it.
  # END decides, and only END: a rule-level 'exit N' in awk still RUNS the END
  # block, so an 'END { exit 1 }' underneath silently overwrites the status.
  # Second time in this session — see CONTRIBUTING trap #8.
  awk '/ollama_processor/       { seen = 1 }
       /curl .*api\/generate/   { if (!done) { done = 1; in_order = seen } }
       END { exit (done && in_order) ? 0 : 1 }' <<<"${body}" || {
    echo 'the cold-load notice comes after the request it is meant to explain' >&2
    return 1; }
}
check "'lca ask' explains the silence before a cold model answers" \
  ask_announces_a_cold_load

echo "# the chat's filesystem limit must not depend on the model mentioning it"
# The system prompt tells the model it has no filesystem and it usually says
# so — usually. One time in ten on the build question it writes a confident
# tutorial instead, and the user concludes the product cannot code. That is
# what the first real user hit. A banner is served by Open WebUI itself and
# rendered whatever the model does.
banner_json="$(lca_webui_banners 2>/dev/null || true)"
check "the banner is valid JSON Open WebUI can parse" \
  test "$(jq -r 'type' <<<"${banner_json}" 2>/dev/null)" = "array"
# Open WebUI's BannerModel requires every one of these; a missing field makes
# it drop the banner and log an exception, which is silent from outside.
banner_has_every_required_field() {
  local f
  for f in id type title content dismissible timestamp; do
    [[ "$(jq -r --arg f "${f}" '.[0] | has($f)' <<<"${banner_json}" 2>/dev/null)" == "true" ]] || {
      printf 'banner is missing the %s field BannerModel requires\n' "${f}" >&2
      return 1
    }
  done
}
check "...with every field BannerModel requires" banner_has_every_required_field
check "it states the limitation" \
  grep -qi 'cannot read, create or edit files' <<<"${banner_json}"
# A limit with no way out is a complaint. It has to name the thing that works.
check "...and names the command that does write files" \
  grep -q 'lca \[project-dir\]' <<<"${banner_json}"
# Dismissible would let someone hide it on day one and meet the tutorial on
# day thirty. The limitation never goes away, so neither does the banner.
check "...and cannot be dismissed" \
  test "$(jq -r '.[0].dismissible' <<<"${banner_json}" 2>/dev/null)" = "false"
# ...and the installer must actually pass it, or all of the above is a string
# nothing ever reads.
installer_passes_the_banner() {
  local body; body="$(sed 's/#.*//' "${REPO}/scripts/install_webui.sh")"
  grep -q 'WEBUI_BANNERS' <<<"${body}" || {
    echo 'install_webui.sh never passes WEBUI_BANNERS, so no banner is baked in' >&2
    return 1; }
  grep -q 'banners_env\[@\]' <<<"${body}" || {
    echo 'the banner env array is built but never reaches docker run' >&2
    return 1; }
}
check "install_webui.sh bakes the banner into the container" \
  installer_passes_the_banner
# Open WebUI never updates a setting in place, so an install predating the
# banner keeps a container without one. Drift detection is what tells them.
#
# The assertion is on the REPORTING line, not on the name appearing somewhere
# in the function: a first version grepped for 'WEBUI_BANNERS' and passed with
# the comparison replaced by ':', because the two lines that read the wanted
# and live values still mentioned it.
check "a container with no banner is reported as drifted" \
  grep -q 'drifted+=("WEBUI_BANNERS")' \
    <<<"$(sed -n '/^webui_drift() {/,/^}/p' "${REPO}/scripts/lib.sh")"

echo "# AIDER_NO_AUTO_COMMIT — the opt-out from the safety net, off by default"
# aider's auto-commit is what makes an unrequested edit recoverable: one commit
# per change, so 'git diff HEAD~1' shows it and 'git revert <sha>' undoes just
# that one. Turning it off is a legitimate preference and a real tradeoff, so
# it is a setting rather than a rewrite — and it defaults to keeping the net.
aider_no_auto_commit_is_wired() {
  local body; body="$(sed 's/#.*//' "${REPO}/run-agent.sh")"
  grep -q 'AIDER_NO_AUTO_COMMIT' <<<"${body}" || {
    echo 'run-agent.sh never reads AIDER_NO_AUTO_COMMIT, so the setting does nothing' >&2
    return 1; }
  # The flag itself has to be handed to aider, not merely mentioned.
  grep -qE 'aider_args\+=\( --no-auto-commits \)' <<<"${body}" || {
    echo 'AIDER_NO_AUTO_COMMIT is read but --no-auto-commits never reaches aider' >&2
    return 1; }
  # ...and only when asked for. Unconditional would silently remove the net.
  awk '/AIDER_NO_AUTO_COMMIT/           { guard = 1 }
       /aider_args\+=\( --no-auto-commits \)/ { if (!done) { done = 1; ok = guard } }
       END { exit (done && ok) ? 0 : 1 }' <<<"${body}" || {
    echo 'the --no-auto-commits flag is not guarded by the setting' >&2
    return 1; }
  # Default must keep committing: lib.sh applies it, .env.example ships it.
  # '[$]{' rather than the literal, so this line is not itself an
  # unexpanded-expression finding — the bracket idiom used elsewhere here.
  grep -qE 'AIDER_NO_AUTO_COMMIT="[$][{]AIDER_NO_AUTO_COMMIT:-false[}]"' "${REPO}/scripts/lib.sh" || {
    echo 'AIDER_NO_AUTO_COMMIT does not default to false' >&2
    return 1; }
  grep -qx 'AIDER_NO_AUTO_COMMIT=false' "${REPO}/.env.example" || {
    echo '.env.example does not ship AIDER_NO_AUTO_COMMIT=false' >&2
    return 1; }
}
check "AIDER_NO_AUTO_COMMIT maps to --no-auto-commits and defaults off" \
  aider_no_auto_commit_is_wired

echo "# ...and the safety net needs a git repo, which \$HOME will never get"
# Measured in aider's own source (main.py): with no repo it asks "No git repo
# found, create one to track aider's changes (recommended)?" — except when the
# cwd IS the home directory, where it prints one line of advice and returns
# without a repo and without asking.
#
# That exception lands on the likeliest directory there is. SSH puts you in
# $HOME, 'lca help' calls the bare command "start the coding agent here", and
# the login banner now tells people to write code. Typing 'lca' straight after
# logging in is the one path where auto-commit — the whole answer to a small
# model deleting a function nobody mentioned — silently is not there.
csa_in() {  # DIR HOME -> repo | home | norepo
  bash -c 'source "$1" >/dev/null 2>&1; cd "$2" || exit 9; HOME="$3"
           commit_safety_state' _ "${REPO}/scripts/lib.sh" "$1" "$2"
}
commit_safety_state_reads_the_directory() {
  local d="${SANDBOX}/csa" bad=0 got
  rm -rf "${d}"; mkdir -p "${d}/home" "${d}/plain" "${d}/repo"
  ( cd "${d}/repo" && git init -q ) || { echo 'could not make a test repo' >&2; return 1; }
  ln -sfn "${d}/home" "${d}/link"
  # want<TAB>dir<TAB>home
  while IFS=$'\t' read -r want dir home; do
    [[ -n "${want}" ]] || continue
    got="$(csa_in "${dir}" "${home}")"
    [[ "${got}" == "${want}" ]] || {
      printf 'in %s (HOME=%s): wanted %s, got %s\n' \
        "${dir#"${d}/"}" "${home#"${d}/"}" "${want}" "${got}" >&2
      bad=1; }
  done <<EOF
repo	${d}/repo	${d}/home
home	${d}/home	${d}/home
norepo	${d}/plain	${d}/home
home	${d}/home	${d}/link
norepo	${d}/repo/.git	${d}/home
EOF
  return "${bad}"
}
check "commit_safety_state tells a repo, a home dir and a plain dir apart" \
  commit_safety_state_reads_the_directory
# The last two rows above are the ones that were written wrong first and are
# easy to write wrong again:
#   - a symlinked HOME is still HOME. String equality misses it; '-ef' compares
#     device and inode, so it does not.
#   - inside a bare .git, 'rev-parse --is-inside-work-tree' prints false and
#     exits 0, so testing the exit status alone calls it a repo.
#
# ...and run-agent.sh has to act on it, before the model load rather than after
# the twenty seconds that costs even warm.
run_agent_checks_where_it_is_running() {
  local body
  body="$(sed 's/#.*//' "${REPO}/run-agent.sh")"
  grep -q 'commit_safety_state' <<<"${body}" || {
    echo 'run-agent.sh starts aider without ever asking whether edits can be undone' >&2
    return 1; }
  # In $HOME it must STOP and ask, not merely mention it in passing: confirm()
  # auto-yes'es a non-tty, so this costs scripts and CI nothing.
  awk '/home\)/       { inb = 1 }
       inb && /confirm/ { found = 1 }
       inb && /;;/     { exit }
       END { exit !found }' <<<"${body}" || {
    echo 'the home-directory case warns but never gives the user a way out' >&2
    return 1; }
  # Before the model is loaded, not after.
  local check_at load_at
  check_at="$(grep -n 'commit_safety_state' <<<"${body}" | head -1 | cut -d: -f1)"
  load_at="$(grep -n 'ensure_ollama_up_announced' <<<"${body}" | head -1 | cut -d: -f1)"
  [[ -n "${load_at}" ]] || { echo 'run-agent.sh no longer starts Ollama' >&2; return 1; }
  (( check_at < load_at )) || {
    echo 'the directory check happens after the model load, so the wait is paid first' >&2
    return 1; }
}
check "...and run-agent.sh acts on it before making anyone wait" \
  run_agent_checks_where_it_is_running
# The risk it exists for has to be written down where someone will meet it,
# with the recovery beside it. A toggle nobody understands is not a mitigation.
unrequested_edits_are_documented() {
  local f section
  for f in README.md docs/TROUBLESHOOTING.md; do
    # Scoped to the section, not the whole file. A whole-file grep for
    # 'git revert' passed with the recovery block deleted, satisfied by the
    # sentence further down explaining what the opt-out costs you — the
    # recovery has to be beside the risk, where someone meeting it will look.
    section="$(awk '/^#+ Review every edit/ { inb = 1; next }
                    inb && /^#+ / { exit }
                    inb' "${REPO}/${f}")"
    [[ -n "${section}" ]] || {
      printf '%s has no "Review every edit" section warning about unrequested changes\n' "${f}" >&2
      return 1; }
    grep -qi 'unrequested changes' "${REPO}/${f}" || {
      printf '%s does not warn that a local model can edit code you did not ask about\n' "${f}" >&2
      return 1; }
    grep -q 'git diff HEAD~' <<<"${section}" || {
      printf '%s names the risk but not how to see it\n' "${f}" >&2
      return 1; }
    grep -q 'git revert' <<<"${section}" || {
      printf '%s names the risk but not how to undo it\n' "${f}" >&2
      return 1; }
  done
}
check "the unrequested-edit risk is documented with its recovery" \
  unrequested_edits_are_documented

echo "# the first-run walkthrough must not finish at a chat window"
# docs/YOUR-TURN.md is the step-by-step a first-time user follows to the end.
# Every step led to the CHAT — account, phone, signups, kill switch — and the
# finish checklist was satisfied by sending it a message. It never once had
# them run the thing that writes files. A user who follows it to completion
# reasonably concludes the chat IS the product, asks it to build something,
# gets a tutorial, and decides the stack cannot code. That is not hypothetical:
# it is the first real report this project received.
walkthrough_reaches_the_coding_agent() {
  local doc="${REPO}/docs/YOUR-TURN.md" body
  body="$(cat "${doc}")"
  # Bare 'lca' in a project directory — not lca ask/chat/check, which the
  # walkthrough already had and which do not write files.
  grep -qE '^lca( +#.*)?$' <<<"${body}" || {
    echo 'YOUR-TURN.md never has the user run bare "lca" (the coding agent)' >&2
    return 1; }
  # ...and it must send them to look at what happened, since the model edits
  # things it was not asked about.
  grep -q 'git diff HEAD~' <<<"${body}" || {
    echo 'YOUR-TURN.md runs the coding agent but never has the user read the diff' >&2
    return 1; }
  # The finish checklist is the part people actually tick off, so the coding
  # step has to appear THERE, not only in prose above it.
  local checklist
  checklist="$(awk '/^## .*You are finished when/ { inb = 1; next }
                    inb && /^## / { exit }
                    inb' "${doc}")"
  [[ -n "${checklist}" ]] || {
    echo 'YOUR-TURN.md has no "You are finished when" checklist' >&2
    return 1; }
  grep -q 'git diff HEAD~' <<<"${checklist}" || {
    echo 'the finish checklist can be ticked off without ever editing a file' >&2
    return 1; }
}
check "YOUR-TURN.md ends with a real edit, not a chat message" \
  walkthrough_reaches_the_coding_agent
# ...and the count it promises in its first paragraph must be the number of
# steps it actually has. Adding the coding step made it seven while the opening
# line still said six — drift introduced by the very commit above, in the file
# whose whole job is being followed literally by someone with no terminal
# experience. A reader who counts is the reader this document is written for.
walkthrough_step_count_matches_its_own_promise() {
  local doc="${REPO}/docs/YOUR-TURN.md" steps claimed word
  steps="$(grep -c '^## Step [0-9]' "${doc}")"
  # The number is written as a word, which is right for the sentence and means
  # the check has to translate rather than grep for a digit.
  local -a words=(zero one two three four five six seven eight nine ten)
  word="${words[${steps}]:-}"
  [[ -n "${word}" ]] || {
    printf 'YOUR-TURN.md has %s steps, past what this gate can spell\n' "${steps}" >&2
    return 1; }
  claimed="$(grep -oE 'These [a-z]+ steps' "${doc}" | head -1)"
  [[ -n "${claimed}" ]] || {
    echo 'YOUR-TURN.md no longer opens by saying how many steps there are' >&2
    return 1; }
  [[ "${claimed}" == "These ${word} steps" ]] || {
    printf 'YOUR-TURN.md says "%s" but has %s of them\n' "${claimed}" "${steps}" >&2
    return 1; }
}
check "...and it promises the number of steps it actually has" \
  walkthrough_step_count_matches_its_own_promise
# Same class, checked because it was already correct rather than after it broke:
# PHONE.md says the empty-chat screen "offers five starter questions", and the
# questions live in a JSON file anyone can add a sixth to without reading a doc
# two directories away.
if have jq; then
  starter_question_count_matches_the_doc() {
    local n word claimed
    n="$(jq length "${REPO}/config/prompt-suggestions.json" 2>/dev/null || echo 0)"
    (( n > 0 )) || { echo 'config/prompt-suggestions.json is empty or unreadable' >&2; return 1; }
    local -a words=(zero one two three four five six seven eight nine ten)
    word="${words[${n}]:-}"
    [[ -n "${word}" ]] || { printf 'there are now %s starter questions, past what this gate can spell\n' "${n}" >&2; return 1; }
    claimed="$(grep -oE 'offers [a-z]+ starter questions' "${REPO}/docs/PHONE.md" | head -1)"
    [[ -n "${claimed}" ]] || {
      echo 'PHONE.md no longer says how many starter questions the chat offers' >&2
      return 1; }
    [[ "${claimed}" == "offers ${word} starter questions" ]] || {
      printf 'PHONE.md says "%s" but config/prompt-suggestions.json has %s\n' "${claimed}" "${n}" >&2
      return 1; }
  }
  check "PHONE.md counts the starter questions the chat really ships" \
    starter_question_count_matches_the_doc
fi

echo "# ...and the README must not bury the coding agent below the chat either"
# Same failure, third door. The README had two 'Quick start' sections — server,
# then phone — and the coding agent sat 150 lines further down, behind
# auto-tune, the kill switch, updating and the security model. Someone who
# reads the two quick starts has installed a box and opened a chat, and has
# been given no reason to believe anything else exists.
#
# The ordering is not only a statement of priorities, it is the dependency
# order: coding needs nothing beyond setup.sh, while the phone section needs
# Tailscale installed on a second device first.
readme_offers_coding_before_chat() {
  local doc="${REPO}/README.md" code_line chat_line
  # Bare 'lca' on its own line inside a fenced block, optionally with a trailing
  # comment — the same shape YOUR-TURN.md is held to. 'lca ask' and 'lca chat'
  # do not count: neither writes a file.
  code_line="$(grep -nE '^lca( +#.*)?$' "${doc}" | head -1 | cut -d: -f1)"
  [[ -n "${code_line}" ]] || {
    echo 'the README never shows bare "lca", the command that writes files' >&2
    return 1; }
  chat_line="$(grep -n '^## Quick start (phone)' "${doc}" | head -1 | cut -d: -f1)"
  [[ -n "${chat_line}" ]] || {
    echo 'the README has no phone quick start to order against' >&2; return 1; }
  (( code_line < chat_line )) || {
    printf 'the README shows the chat (line %s) before the coding agent (line %s)\n' \
      "${chat_line}" "${code_line}" >&2
    return 1; }
}
check "the README reaches the coding agent before the chat" \
  readme_offers_coding_before_chat

echo "# every in-document link must point at a heading that exists"
# The section above is reached by an anchor link, and an anchor is a string
# nobody ever re-checks: rename the heading and the link still looks fine and
# silently goes nowhere. Both directions are covered — '](#anchor)' within a
# file and '](OTHER.md#anchor)' across two.
#
# Slug rules are GitHub's: lowercase, drop everything that is not a letter,
# digit, space or hyphen (which is what happens to the em dashes this project
# writes headings with), then spaces to hyphens.
md_anchor_links_resolve() {
  local bad=0 src target file anchor line
  local -a docs=()
  # git ls-files, for the reason every_bash_script_is_linted gives further
  # down: it is this project's own documentation, not the thousand markdown
  # files aider vendors into .venv, whose broken links are not our problem.
  # An array rather than a word-split string — the paths are data, and this is
  # the one shape of it that needs no shellcheck exemption.
  mapfile -t docs < <(git -C "${REPO}" ls-files '*.md' 2>/dev/null || true)
  (( ${#docs[@]} > 0 )) || {
    echo "could not list tracked markdown (not a git checkout?)" >&2; return 1; }
  # '[^):]*' below is what skips external URLs: their 'https:' carries the one
  # character a local path never does. Nothing here reaches the network.
  while IFS= read -r line; do
    src="${line%%:*}"; target="${line#*:}"
    file="${target%%#*}"; anchor="${target#*\#}"
    if [[ -z "${file}" ]]; then
      file="${REPO}/${src}"                       # same-document anchor
    elif [[ "${src}" == */* ]]; then
      file="${REPO}/${src%/*}/${file}"            # relative to the linking file
    else
      file="${REPO}/${file}"                      # link from a top-level doc
    fi
    [[ -r "${file}" ]] || {
      printf '%s links to a file that does not exist: %s\n' "${src}" "${file}" >&2
      bad=1; continue; }
    # Build every heading's slug the way GitHub does and look for this anchor.
    if ! grep -E '^#+ ' "${file}" \
      | sed -e 's/^#* *//' \
      | tr '[:upper:]' '[:lower:]' \
      | sed -e 's/[^a-z0-9 -]//g' -e 's/ /-/g' \
      | grep -qxF "${anchor}"; then
      printf '%s links to #%s, which is no heading in %s\n' \
        "${src}" "${anchor}" "${file#"${REPO}/"}" >&2
      bad=1
    fi
  done < <(cd "${REPO}" && grep -nHoE '\]\([^):]*#[a-z0-9-]+\)' -- "${docs[@]}" \
             | sed -e 's/:[0-9]*:\](/:/' -e 's/)$//')
  return "${bad}"
}
check "every anchor link in the docs points at a real heading" \
  md_anchor_links_resolve

echo "# ...and every doc a SCRIPT sends you to must exist too"
# The docs gate above covers markdown pointing at markdown. Shell scripts point
# at markdown constantly — "see docs/TROUBLESHOOTING.md", "docs/GPU.md" — and
# those are the ones a reader meets at the moment something has gone wrong.
# Rename a doc and every message naming it goes quietly nowhere.
#
# All of them resolve today; this went in while it was correct rather than
# after it broke. Two false positives on the first sweep are why the resolution
# below tries three roots: CONVENTIONS.md lives in config/, not docs/, and a
# comment in this very file mentions a made-up 'OTHER.md' when explaining the
# gate above — hence comments are stripped first.
script_doc_references_resolve() {
  local -a scripts=()
  mapfile -t scripts < <(git -C "${REPO}" ls-files '*.sh' 'bin/*' '.githooks/*' 2>/dev/null || true)
  (( ${#scripts[@]} > 0 )) || {
    echo "could not list tracked scripts (not a git checkout?)" >&2; return 1; }
  local f ref bad=0 found root
  for f in "${scripts[@]}"; do
    while IFS= read -r ref; do
      [[ -n "${ref}" ]] || continue
      found=no
      for root in "" docs/ config/; do
        [[ -e "${REPO}/${root}${ref}" ]] && { found=yes; break; }
      done
      [[ "${found}" == yes ]] || {
        printf '%s names %s, which is not a file in the repo, docs/ or config/\n' \
          "${f}" "${ref}" >&2
        bad=1; }
    done < <(sed 's/#.*//' "${REPO}/${f}" \
               | grep -ohE '[A-Za-z][A-Za-z0-9_/-]*\.md' | sort -u)
  done
  return "${bad}"
}
check "every doc a script points at is a file that exists" \
  script_doc_references_resolve

echo "# ...and so must the list setup.sh prints the moment it finishes"
# Fifth door, and the one printed at the exact moment someone is deciding what
# this box is for. Coding was there — at number 4, underneath two chat steps
# and 'lca ask', which cannot write a file and looks more like the thing that
# can than anything else on the list. Somebody who reads three lines and stops
# was pointed away from the product three times out of three.
setup_next_steps_lead_with_code() {
  local block code_at chat_at
  block="$(awk '/^  step "Next steps"/ { inb = 1; next }
                inb && /VERDICT_PRINTED/ { exit }
                inb' "${REPO}/setup.sh")"
  [[ -n "${block}" ]] || {
    echo 'setup.sh no longer prints a "Next steps" list' >&2; return 1; }
  # The coding entry: bare 'lca' at the end of a command, not 'lca ask'/'chat'.
  code_at="$(grep -nE '&& lca( |"|$)' <<<"${block}" | head -1 | cut -d: -f1)"
  [[ -n "${code_at}" ]] || {
    echo 'setup.sh finishes without ever naming the command that writes files' >&2
    return 1; }
  chat_at="$(grep -n 'lca chat' <<<"${block}" | head -1 | cut -d: -f1)"
  [[ -n "${chat_at}" ]] || {
    echo 'setup.sh no longer offers the chat, so there is nothing to order against' >&2
    return 1; }
  (( code_at < chat_at )) || {
    printf 'setup.sh offers the chat (line %s of the list) before coding (line %s)\n' \
      "${chat_at}" "${code_at}" >&2
    return 1; }
}
check "setup.sh's last words offer the coding agent before the chat" \
  setup_next_steps_lead_with_code

echo "# every systemd unit this project installs must also be uninstalled"
# Four units are installed today — tune, netmode, backup service and timer —
# and uninstall.sh removes all four. Nothing holds that together. A fifth unit
# added to an installer and forgotten here would survive 'uninstall.sh',
# keep running at every boot, and reference a directory the user believes they
# deleted. Units are the worst thing to leak because they are the one artefact
# that outlives the reboot.
#
# Same shape as the gate for settings baked into the WebUI container: derive
# the list from what the installers actually create, rather than maintaining a
# second copy of it here.
every_installed_unit_is_removed() {
  local unit leaked=0
  while read -r unit; do
    [[ -n "${unit}" ]] || continue
    grep -qF "${unit}" "${REPO}/uninstall.sh" || {
      printf 'something installs %s but uninstall.sh never removes it\n' "${unit}" >&2
      leaked=1
    }
  done < <(grep -rhoE 'local-code-agent[a-z-]*\.(service|timer)' \
             "${REPO}/setup.sh" "${REPO}"/scripts/*.sh "${REPO}/netmode.sh" \
             "${REPO}/backup.sh" 2>/dev/null | sort -u)
  return "${leaked}"
}
check "uninstall.sh removes every systemd unit the installers create" \
  every_installed_unit_is_removed

echo "# uninstall may not announce a removal it never checked"
# "Ollama removed (including all downloaded models)" printed unconditionally.
# It said that on a machine where Ollama was never installed, and on one where
# it still is: the official installer picks the first WRITABLE directory on
# PATH, so a host where /usr/local/bin was not writable keeps its binary
# somewhere none of uninstall.sh's rm's name. The confirmation prompt the user
# just answered says "incl. ALL models".
#
# Driven, not grepped — uninstall.sh is sourceable for exactly this, the way
# restore.sh is for machine_advice. Each arm runs against a stubbed 'have'.
uninstall_says() {  # want-substring was-installed have-ollama-after
  local out
  out="$(bash -c '
    source "$1" >/dev/null 2>&1
    if [[ "$3" == "yes" ]]; then have() { return 0; }; else have() { [[ "$1" != ollama ]]; }; fi
    command() { printf /usr/bin/ollama; }
    report_ollama_removal "$2" 2>&1' _ "${REPO}/uninstall.sh" "$2" "$3")"
  grep -qF -- "$1" <<<"${out}" || {
    printf 'report_ollama_removal was=%s still=%s printed: %s\n' "$2" "$3" "${out}" >&2
    return 1
  }
}
check "a real removal is announced as one" \
  uninstall_says "Ollama removed (including all downloaded models)" true no
check "a binary that survived is reported, not celebrated" \
  uninstall_says "STILL on PATH" true yes
still_makes_no_removal_claim() { ! uninstall_says "Ollama removed" true yes 2>/dev/null; }
check "...and the removal line is withheld"    still_makes_no_removal_claim
check "nothing installed means nothing removed" \
  uninstall_says "was not installed here" false no

# Models follow the SERVER, not the binary. Under systemd that is the 'ollama'
# system account, whose home went with /usr/share/ollama. Without systemd —
# containers and WSL, where install_ollama.sh deliberately falls back to
# start_ollama_bg — the server runs as the invoking user and every blob lands
# in THEIR home. Nothing removed that, so on the hosts this project supports
# specially the prompt promised "incl. ALL models" and left the gigabytes.
uninstall_clears_user_model_dirs() {
  local body; body="$(sed 's/#.*//' "${REPO}/uninstall.sh")"
  grep -qE 'rm -rf +"\$\{d\}/\.ollama"' <<<"${body}" || {
    echo 'uninstall.sh leaves per-user model blobs (~/.ollama) on disk' >&2
    return 1
  }
  # Both homes, not just the one sudo happens to expose.
  grep -q 'SUDO_USER' <<<"${body}" || {
    echo 'uninstall.sh only cleans the invoking home, not the human who sudo-ed' >&2
    return 1
  }
}
check "uninstall clears models pulled without systemd" uninstall_clears_user_model_dirs

echo "# ...and a chat app it could not even LOOK at is not a chat app it removed"
# The WebUI block asked 'docker container inspect' straight out. With dockerd
# down that returns non-zero for the same reason "there is no container" does,
# so both removals were skipped in silence. Measured with the daemon stopped
# and the container and volume both present — this is everything the run said:
#
#   ==> Uninstall complete
#   [info] Kept on purpose: Docker Engine, Tailscale, git, this repository and .env.
#
# One screen earlier the prompt had asked to remove "the WebUI container and
# its data" and been told yes. lib.sh's docker_daemon_reachable exists to keep
# "cannot ask" apart from "nothing there" — its header says exactly that, and
# backup.sh routes through it. uninstall.sh was the file that did not.
#
# Driven through the stubs rather than grepped, the same way report_ollama_removal
# above is: the fault was a missing DISTINCTION, and no amount of matching the
# word 'docker' in this file would have seen it.
remove_webui_run() {  # CASE [KEEP] -> the output, with "rc=N" as its last line
  bash -c '
    source "$1" >/dev/null 2>&1
    CASE="$2"; KEEP="$3"
    # Stubs AFTER the source: inside a function "$2" is the FUNCTION argument.
    if [[ "${CASE}" == "nodocker" ]]; then have() { [[ "$1" != "docker" ]]; }
    else have() { return 0; }; fi
    if [[ "${CASE}" == "daemondown" ]]; then docker_daemon_reachable() { return 1; }
    else docker_daemon_reachable() { return 0; }; fi
    # Both inspects answer "present", so every case below is a machine that
    # really does still have a container and a volume to lose.
    as_root() {
      case "$*" in
        *"rm -f"*)     [[ "${CASE}" == "rmfails"  ]] && return 1 ;;
        *"volume rm"*) [[ "${CASE}" == "volfails" ]] && return 1 ;;
      esac
      return 0
    }
    rc=0; remove_webui "${KEEP}" 2>&1 || rc=$?
    printf "rc=%s\n" "${rc}"' _ "${REPO}/uninstall.sh" "$1" "${2:-false}"
}
uninstall_reports_the_chat_app_it_left() {
  local out bad=0
  # THE regression. Nothing removed, and the caller must be told so it can stop
  # printing "Uninstall complete" over the top of it.
  out="$(remove_webui_run daemondown)"
  if ! grep -q 'NOT removed' <<<"${out}" || ! grep -q 'rc=1' <<<"${out}"; then
    printf 'a daemon that cannot be reached is reported as a chat app removed: %s\n' "${out}" >&2
    bad=1
  fi
  # ...and it must not claim any of it happened.
  ! grep -qE '\[ ok \].*removed' <<<"${out}" || {
    printf 'the unreachable-daemon path still announces a removal: %s\n' "${out}" >&2
    bad=1; }
  # A working daemon still does the work, and says rc=0 so the run reads as
  # complete. Without this the gate passes with remove_webui gutted to a warn.
  out="$(remove_webui_run live false)"
  if ! grep -q "container 'open-webui' removed" <<<"${out}" \
     || ! grep -q 'data volume removed' <<<"${out}" \
     || ! grep -q 'rc=0' <<<"${out}"; then
    printf 'an ordinary uninstall no longer removes the chat app: %s\n' "${out}" >&2
    bad=1
  fi
  # --keep-data keeps the volume and still removes the container.
  out="$(remove_webui_run live true)"
  if ! grep -q "container 'open-webui' removed" <<<"${out}" \
     || ! grep -q 'Keeping' <<<"${out}" \
     || grep -q 'data volume removed' <<<"${out}"; then
    printf '--keep-data no longer means what it says: %s\n' "${out}" >&2
    bad=1
  fi
  # No docker at all: nothing exists, so nothing is left behind and nothing is
  # said. This is the one silent answer that is honest.
  out="$(remove_webui_run nodocker)"
  grep -q 'rc=0' <<<"${out}" || {
    printf 'a machine with no docker is reported as having a chat app left on it: %s\n' "${out}" >&2
    bad=1; }
  # A removal that FAILS is the third answer, and the reason the removals are
  # reported instead of fatal: a bare 'as_root docker rm -f' under set -e ends
  # the run, and the four steps after it — models, virtualenv, 'lca', the login
  # banner — never happen on a box that has already lost its boot services.
  local case
  for case in rmfails volfails; do
    out="$(remove_webui_run "${case}")"
    if ! grep -q 'could not be removed' <<<"${out}" || ! grep -q 'rc=1' <<<"${out}"; then
      printf 'a %s removal is not reported as one: %s\n' "${case}" "${out}" >&2
      bad=1
    fi
  done
  return "${bad}"
}
check "an uninstall that could not reach docker says the chat app is still here" \
  uninstall_reports_the_chat_app_it_left
# ...and the closing line has to agree with it, because that is the line people
# read. "Uninstall complete" directly above "Kept on purpose: ..." is a full
# accounting of what survived, and it was signed off on a machine still holding
# every account and chat.
closing_banner_run() {  # WEBUI_LEFT -> the closing lines
  bash -c 'source "$1" >/dev/null 2>&1; closing_banner "$2" 2>&1' \
    _ "${REPO}/uninstall.sh" "$1"
}
uninstall_closing_line_matches_what_happened() {
  local out
  out="$(closing_banner_run 0)"
  grep -q 'Uninstall complete' <<<"${out}" || {
    printf 'a clean uninstall no longer reads as complete: %s\n' "${out}" >&2
    return 1; }
  out="$(closing_banner_run 1)"
  ! grep -q 'Uninstall complete' <<<"${out}" || {
    printf 'an uninstall that left the chat app behind still says complete: %s\n' "${out}" >&2
    return 1; }
  grep -q 'chat app' <<<"${out}" || {
    printf 'the closing line does not say what was left behind: %s\n' "${out}" >&2
    return 1; }
}
check "...and the closing line stops saying 'complete' when it is not" \
  uninstall_closing_line_matches_what_happened

echo "# ...and every removal an uninstall makes must be able to make it"
# Step 5 removed the virtualenv with a bare 'rm -rf' while all nine other
# removals in the file went through as_root. setup.sh runs under sudo, so .venv
# is root-owned — measured, drwxr-xr-x root root — which makes that the one step
# a non-root run cannot do. Under set -e it does not skip, it ENDS the run.
# Reproduced as an ordinary user against a root-owned .venv:
#
#   rm: cannot remove '.../.venv/bin/aider': Permission denied
#
# ...with Ollama, the models, the chat app and the boot services already gone,
# and the 'lca' command, the login banner and the cache not yet touched. What
# is left greets every SSH login with a banner for a stack that no longer
# exists. Blanket rather than pinned to that one line: the next removal added
# here will be written by copying a neighbour, and half the neighbours were
# right by accident.
uninstall_removals_can_reach_root() {
  local body bare escalated
  body="$(sed 's/#.*//' "${REPO}/uninstall.sh")"
  # 'as_root' must come BEFORE the rm on the line — 'as_root docker rm -f' is
  # escalated, a trailing '&& as_root something-else' is not.
  escalated="$(grep -cE 'as_root( +[^ ]+)* +rm +-' <<<"${body}" || true)"
  (( escalated >= 8 )) || {
    printf 'only %s escalated removals found in uninstall.sh — this gate stopped watching\n' \
      "${escalated}" >&2
    return 1
  }
  bare="$(grep -nE '(^|[^_[:alnum:]])rm +-' <<<"${body}" \
          | grep -vE 'as_root( +[^ ]+)* +rm +-' || true)"
  [[ -z "${bare}" ]] || {
    printf 'uninstall.sh removes something without as_root (a root-owned target ends the run there, and every later step is skipped):\n%s\n' \
      "${bare}" >&2
    return 1
  }
}
check "uninstall.sh escalates every removal, so one it cannot do does not end it" \
  uninstall_removals_can_reach_root

echo "# install.sh is piped into bash — a partial download must do nothing"
# It is advertised as 'curl -fsSL ... | bash', which streams the file and runs
# each statement as it arrives. A connection dropping part-way would otherwise
# execute a PARTIAL installer: far enough to install git and create the target
# directory, not far enough to clone or hand over to setup.sh, and it would
# leave that half-state behind without an error. Wrapped in main() called on
# the last line, a truncated download never reaches the call.
install_is_truncation_safe() {
  local src="${REPO}/install.sh"
  grep -qE '^main\(\) \{' "${src}" || {
    echo "install.sh has no main() wrapper — a truncated curl|bash would run a partial installer" >&2
    return 1
  }
  # The call must be the LAST statement, or the wrapper buys nothing. The
  # trailing 'exit $?' is part of it — see the self-rewrite gate below — and it
  # costs this one nothing: a truncation landing inside those last few bytes
  # means everything before the call did arrive, so calling main is right.
  [[ "$(grep -vE '^\s*(#|$)' "${src}" | tail -1)" == 'main "$@"; exit $?' ]] || {
    echo "install.sh does not end with main \"\$@\"; exit \$? — the wrapper is not the last thing that runs" >&2
    return 1
  }
  # And nothing may execute at top level between the wrapper and the call.
  awk '/^main\(\) \{/ { seen = 1 }
       seen && /^\}/   { closed = 1; next }
       closed && !/^[[:space:]]*(#|$)/ && !/^main "\$@"; exit \$\?$/ { bad = 1 }
       END { exit bad }' "${src}" || {
    echo "install.sh runs something at top level after main() — a partial download could reach it" >&2
    return 1
  }
}
check "install.sh runs nothing if the curl|bash download is truncated" \
  install_is_truncation_safe
# A clone can exit 0 and still not be this project — wrong fork in
# LCA_REPO_URL, or an LCA_BRANCH predating the code. Observed by accident here
# against a stale local 'main' holding only a README: git succeeded, the
# installer said "Clone complete", and there was no setup.sh to run.
install_verifies_the_clone() {
  # The EXISTENCE TEST, not any mention of setup.sh. The first version grepped
  # for the path and passed with the guard replaced by 'true', because the same
  # path appears in the failure message and in the closing "run it yourself"
  # hint. A grep that matches the thing you are describing rather than the
  # thing you are testing is the recurring way a gate here stops gating.
  grep -qE '\[\[ -f "\$\{INSTALL_DIR\}/setup\.sh" \]\]' "${REPO}/install.sh" || {
    echo "install.sh trusts git's exit status instead of checking it got the project" >&2
    return 1
  }
}
check "install.sh checks the clone actually contains the project" \
  install_verifies_the_clone

echo "# 'lca ask' must bound its TOTAL context, not just each piece of it"
# Every context source in ask.sh is capped, each with a comment saying it is so
# that one source "cannot blow the whole context window". Nothing capped the
# sum, and the caps add up to ~54,000 characters — roughly 13,500 tokens —
# against the 4,096-token window the 3b rung runs with on a base droplet.
# Piped input alone (12,000 chars) already exceeded the usable budget there.
#
# Ollama truncates an over-long prompt from the FRONT, which is where the
# system prompt sits. So the failure mode is the assistant quietly losing its
# own instructions and answering like a stock model — on
# 'lca logs | lca ask "why did this fail?"', which README.md and
# TROUBLESHOOTING.md both recommend as the way to diagnose a broken box.
ask_bounds_the_whole_context() {
  local src="${REPO}/scripts/ask.sh"
  # The budget must derive from the model's window and account for the system
  # prompt, not be a constant someone guessed.
  grep -q 'budget_chars=' "${src}" || {
    echo "ask.sh computes no total context budget" >&2; return 1
  }
  grep -qE 'budget_chars=.*ctx_tokens' "${src}" || {
    echo "ask.sh's context budget ignores the model's context length" >&2; return 1
  }
  grep -qE 'budget_chars=.*\$\{#system\}' "${src}" || {
    echo "ask.sh's context budget ignores the size of the system prompt" >&2; return 1
  }
  # It must actually trim...
  grep -qE 'context="\$\{context: -budget_chars\}"' "${src}" || {
    echo "ask.sh never trims the context to its budget" >&2; return 1
  }
  # ...and never silently: losing context changes the answer.
  awk '/if \(\( \$\{#context\} > budget_chars \)\); then/ { inb = 1 }
       inb && /warn / { found = 1 }
       inb && /^  fi$/ { exit }
       END { exit !found }' "${src}" || {
    echo "ask.sh trims the context without telling anyone" >&2; return 1
  }
}
check "'lca ask' bounds its total context and says when it trims" \
  ask_bounds_the_whole_context

echo "# the venv interpreter's path must come from venv_python(), not be re-typed"
# venv_python() existed, was called by nothing, and two files built the same
# string by hand instead — install_python.sh deciding whether to reuse a venv,
# and check-system.sh deciding whether one exists. Harmless today and exactly
# the shape that has bitten this repo repeatedly: the helper is the single
# source of truth right up until the moment it is not, and then it is updated
# while the hand-rolled copies quietly keep the old layout.
#
# The whole bin/ layout, not the interpreter alone. install_python.sh kept the
# rule for python and broke it for pip — twice, in the two lines that actually
# install anything — while the comment stating the rule sat four lines below.
# And bin/pip is the worse one to hand-build: a pip wrapper is a script whose
# shebang carries the absolute interpreter path, and Linux truncates a shebang
# at 127 characters, so a checkout under a long enough path leaves bin/pip
# reporting "bad interpreter" while the interpreter is fine. '$(venv_python)
# -m pip' has neither problem, and the version check in that same file always
# used it.
venv_python_is_the_only_source() {
  local hits
  # Needles written with a bracketed letter so this line does not match itself.
  # A whole-file scan for a literal always finds the scanner — the same trap
  # that made the ci.yml gate flag its own explanatory comment, and that
  # tests/long-wait.awk hit before either. Excluding this file wholesale would
  # work and would also blind the check to the rest of it.
  #
  # A line that goes THROUGH a helper is fine wherever it appears, which is
  # both the definitions in lib.sh and the assertion about aider_bin above —
  # so the exemption is "mentions the helper", not a list of blessed lines.
  hits="$(grep -rnE '/bin/(pyth[o]n|p[i]p|aid[e]r)' --include='*.sh' --include='lca' \
            "${REPO}" 2>/dev/null \
            | grep -v '/\.venv/' \
            | grep -vE 'venv_python|aider_bin' \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these build a path into the venv by hand instead of calling venv_python()/aider_bin():\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "nothing re-types a path into the venv" venv_python_is_the_only_source

echo "# the README's privacy claim about the inbound guard must stay true"
# README's "How your services are kept private" states the guard is re-applied
# "whenever WebUI is (re)created". That is a security claim, and it rests on a
# single line in install_webui.sh. It matters more now than when it was
# written: 'lca apply' re-creates the container on every settings change, so
# this is the path that keeps ports 3000 and 11434 off the public internet
# after routine use, not just at install time.
#
# Delete that line and nothing fails, nothing logs, and the only symptom is an
# exposed port on someone's droplet.
webui_installer_applies_the_guard() {
  grep -qE 'netmode\.sh" harden' "${REPO}/scripts/install_webui.sh" || {
    echo "install_webui.sh no longer applies the inbound guard — README claims it does" >&2
    return 1
  }
  # And the README must still be making the claim this guards; if the sentence
  # goes, the test should be re-examined rather than silently protecting a
  # promise nobody makes any more.
  grep -qi 'whenever WebUI is' "${REPO}/README.md" || {
    echo "README no longer claims the guard is re-applied when WebUI is re-created" >&2
    return 1
  }
}
check "install_webui.sh re-applies the inbound guard, as the README promises" \
  webui_installer_applies_the_guard

echo "# 'lca update' must re-run setup even when the checkout is already current"
# The delivery chain for any assistant fix is: update -> setup.sh ->
# install_webui.sh rebuilds the container -> selftest checks the live prompt.
# Re-running setup is unconditional, and that is load-bearing rather than
# wasteful: the documented recovery for a stale chat is 'git pull' followed by
# apply/update, so by the time update runs, 'behind' is already 0. Skipping
# setup in that case would read as an obvious optimisation and would silently
# break the exact path the docs send people down.
update_reruns_setup_unconditionally() {
  # Two spaces of indent: at the top level of main(), not nested inside the
  # 'behind != 0' branch (which would put it at four).
  grep -qE '^  step "Re-running setup"' "${REPO}/update.sh" || {
    echo "update.sh only re-runs setup conditionally — a hand-pulled fix would not be applied" >&2
    return 1
  }
  # ...and the verification after it must be the self-test, which since today
  # is what notices a stale assistant prompt.
  awk '/step "Re-running setup"/ { seen = 1 }
       seen && /selftest\.sh/ { found = 1 }
       END { exit !found }' "${REPO}/update.sh" || {
    echo "update.sh does not verify with selftest.sh after re-running setup" >&2
    return 1
  }
}
check "'lca update' re-runs setup unconditionally, then self-tests" \
  update_reruns_setup_unconditionally

echo "# ...and a fetch that failed must name the reason it actually had"
# One line covered every cause: "Could not reach the remote. Check
# connectivity, and whether the kill switch is on". A branch that is simply not
# on the remote fails the same fetch. Measured on a checkout whose branch had
# no upstream:
#
#   $ git fetch --quiet origin no-such-branch-xyz
#   fatal: couldn't find remote ref no-such-branch-xyz
#   exit=128
#
# ...and the reader is sent to test their connection and toggle a kill switch,
# neither of which is involved. net_guard three lines above has ALREADY died if
# netmode is offline, so the kill switch is the one cause that message can be
# certain it is NOT.
#
# Driven end to end through a stubbed git rather than grepped, because the
# whole fault was that one message served three states. Nothing in update.sh
# mutates anything before the fetch — args, 'have git', the .git check, the
# branch name, net_guard — and --check is passed as well, so a future reorder
# that reaches it cannot start a backup out of a unit test.
update_fetch_says() {  # LS_REMOTE_RC -> what 'lca update' prints and dies with
  local stub="${SANDBOX}/gitstub"
  mkdir -p "${stub}" "${SANDBOX}/.git"
  cp "${REPO}/update.sh" "${SANDBOX}/update.sh"
  # The stub answers only what update.sh asks before it dies. 'ls-remote
  # --exit-code' is the classifier under test: git returns 2 for "connected,
  # no matching ref" and 128 for "could not connect" — documented exit codes,
  # so this does not depend on git's messages being in English.
  cat > "${stub}/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --abbrev-ref HEAD"*) echo "a-local-branch"; exit 0 ;;
  *ls-remote*)                     exit "${LS_RC}" ;;
  *fetch*)                         exit 1 ;;
esac
exit 0
STUB
  chmod +x "${stub}/git"
  # shellcheck disable=SC2031  # a one-command env prefix, not a subshell edit
  LS_RC="$1" PATH="${stub}:${PATH}" bash "${SANDBOX}/update.sh" --check 2>&1 || true
}
update_fetch_failure_is_diagnosed() {
  local out bad=0
  # 2 — the remote answered, the branch is not there. THE regression.
  out="$(update_fetch_says 2)"
  if ! grep -q "does not exist on the remote" <<<"${out}" \
     || grep -q 'kill switch' <<<"${out}"; then
    printf 'a branch missing from the remote is still blamed on the network: %s\n' "${out}" >&2
    bad=1
  fi
  # ...and it must name the branch, so the reader knows which one to push.
  grep -q 'a-local-branch' <<<"${out}" || {
    printf 'the message does not say which branch is missing: %s\n' "${out}" >&2
    bad=1; }
  # 128 — could not connect. The original message, still correct here and the
  # only state it was ever right for.
  out="$(update_fetch_says 128)"
  grep -q 'kill switch' <<<"${out}" || {
    printf 'an unreachable remote no longer gets the connectivity advice: %s\n' "${out}" >&2
    bad=1; }
  # 0 — remote up, branch present, fetch failed anyway. Neither of the other
  # two answers is true, and saying either would send the reader nowhere.
  out="$(update_fetch_says 0)"
  if grep -q 'kill switch' <<<"${out}" || grep -q 'does not exist on the remote' <<<"${out}"; then
    printf 'a fetch that failed for a third reason is given one of the other two answers: %s\n' "${out}" >&2
    bad=1
  fi
  grep -q 'reachable' <<<"${out}" || {
    printf 'the third case says nothing useful: %s\n' "${out}" >&2
    bad=1; }
  return "${bad}"
}
check "...and 'branch not on the remote' is not reported as a network fault" \
  update_fetch_failure_is_diagnosed
# ...and a git that will not answer AT ALL is not a detached HEAD either.
#
# '|| echo HEAD' collapsed every refusal into that one diagnosis, and a real
# detached HEAD is not among them: that case SUCCEEDS and prints the word HEAD.
# Measured as an ordinary user against a checkout owned by root — what 'sudo
# setup.sh' leaves behind, on the documented path where you install as root and
# then use 'lca' as yourself:
#
#   fatal: detected dubious ownership in repository at '...'
#   To add an exception for this directory, call:
#       git config --global --add safe.directory /home/user/local-code-agent
#
#   [FAIL] The checkout is in a detached HEAD state. Pick a branch first:
#          git -C /home/user/local-code-agent checkout main
#
# On a branch the whole time, and the suggested command fails the same way.
# git had already printed the fix and this threw it away.
update_branch_says() {  # REVPARSE_RC -> what 'lca update --check' dies with
  local stub="${SANDBOX}/gitstub2"
  mkdir -p "${stub}" "${SANDBOX}/.git"
  cp "${REPO}/update.sh" "${SANDBOX}/update.sh"
  cat > "${stub}/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --abbrev-ref HEAD"*)
    if [[ "${RP_RC}" != "0" ]]; then
      echo "fatal: detected dubious ownership in repository at '/somewhere'" >&2
      echo "  git config --global --add safe.directory /somewhere" >&2
      exit "${RP_RC}"
    fi
    echo "${RP_OUT:-a-branch}"; exit 0 ;;
  *ls-remote*) exit 0 ;;
  *fetch*)     exit 0 ;;
esac
exit 0
STUB
  chmod +x "${stub}/git"
  # shellcheck disable=SC2031  # a one-command env prefix, not a subshell edit
  RP_RC="$1" RP_OUT="${2:-a-branch}" PATH="${stub}:${PATH}" \
    timeout 30 bash "${SANDBOX}/update.sh" --check 2>&1 || true
}
update_reads_the_branch_honestly() {
  local out bad=0
  # git refuses outright: not a detached HEAD, and its own words must survive.
  out="$(update_branch_says 128)"
  grep -qi 'detached HEAD' <<<"${out}" && {
    printf 'a git that would not answer is reported as a detached HEAD: %s\n' "${out}" >&2
    bad=1; }
  grep -q 'dubious ownership' <<<"${out}" || {
    printf "git's own explanation was thrown away: %s\n" "${out}" >&2
    bad=1; }
  grep -q 'safe.directory' <<<"${out}" || {
    printf 'the fix git printed was not passed through: %s\n' "${out}" >&2
    bad=1; }
  # ...and a REAL detached HEAD, which succeeds and prints HEAD, must still be
  # reported as one. Without this the gate passes with that branch deleted.
  out="$(update_branch_says 0 HEAD)"
  grep -qi 'detached HEAD' <<<"${out}" || {
    printf 'a real detached HEAD is no longer reported: %s\n' "${out}" >&2
    bad=1; }
  return "${bad}"
}
check "...and a git that refuses to answer is not called a detached HEAD" \
  update_reads_the_branch_honestly

echo "# CI's e2e must compare the WHOLE prompt, not a substring of it"
# The only end-to-end proof that the assistant's instructions reach a real
# container is a step in ci.yml. It asserted `.system | test("local-code-agent")`
# — satisfied by every version of the prompt that has ever existed, including
# the one that made a real user's chat invent a tool call. It proved the
# container had A prompt, never that it had THIS one, which is the only failure
# that has actually occurred here.
ci_compares_the_whole_prompt() {
  local ci="${REPO}/.github/workflows/ci.yml"
  grep -q 'want_prompt=' "${ci}" || {
    echo "ci.yml no longer builds the expected prompt to compare against" >&2
    return 1
  }
  grep -qF 'lca_system_prompt' "${ci}" || {
    echo "ci.yml does not derive the expectation from lca_system_prompt" >&2
    return 1
  }
  # Comment lines stripped first. The comment ABOVE the fixed assertion quotes
  # the broken one to explain why it was replaced, and a whole-file grep read
  # that as the bug still being present — tests/long-wait.awk had to learn the
  # same lesson about reading its own explanation as evidence.
  local ci_code; ci_code="$(grep -vE '^[[:space:]]*#' "${ci}")"
  if grep -qF 'test("local-code-agent")' <<<"${ci_code}"; then
    echo "ci.yml is back to asserting the prompt by substring — any stale prompt passes that" >&2
    return 1
  fi
}
check "CI compares the container's prompt with this repo's, byte for byte" \
  ci_compares_the_whole_prompt

echo "# 'lca test' must not call a stale assistant 'works end-to-end'"
# The self-test's 4th check was "does the HTTP port answer". The only real bug
# report ever filed against this project was a box where Ollama, the model,
# aider, Tailscale and the WebUI were all fine and the ASSISTANT was wrong —
# so this test would have printed "SELF-TEST PASSED — your stack works
# end-to-end" to the person filing it. That is the worst thing a test can do:
# vouch for the exact thing that is broken.
selftest_checks_the_live_prompt() {
  awk '/step "4\/4 Open WebUI"/ { seen = 1 }
       seen && /DEFAULT_MODEL_PARAMS|webui_drift/ { found = 1 }
       END { exit !found }' "${REPO}/scripts/selftest.sh" || {
    echo "selftest.sh never checks which assistant prompt the chat app is running" >&2
    return 1
  }
  # ...and an unreadable value must not be reported as a pass. "Cannot look"
  # and "fine" are different answers, and this file already learned that the
  # hard way for docker probes.
  grep -q 'skipped, not passed' "${REPO}/scripts/selftest.sh" || {
    echo "selftest.sh does not distinguish 'could not check' from 'passed'" >&2
    return 1
  }
}
# The "wrote no file" advice must not name causes nothing looked at.
# "Check LCA_EDIT_FORMAT in .env and the context window" was a guess: observed
# on qwen2.5-coder:7b — the rung auto-tune picks for 9-15 GiB — at ctx 8192
# with LCA_EDIT_FORMAT unset, the model answers with the right intent and emits
# a block aider rejects, on a 2.8k-token prompt. Neither named setting was
# involved, and the same model on the same box passed this check several times
# the same afternoon.
#
# It must STILL be a FAIL, and it must still be the general branch — the
# too-small-model branch beside it has its own sentence and its own gate.
selftest_edit_failure_says_what_is_known() {
  local body
  # ONE line, selected by a phrase unique to this branch — not a sed RANGE.
  #
  # Two mutations came back NOT CAUGHT here before this line was right, and
  # both were the gate's fault rather than the mutation's:
  #
  #   1. '/aider answered but wrote no file/,/Full log/' anchored on a phrase
  #      that appears TWICE — the too-small-model branch says it first — so it
  #      extracted the wrong message entirely.
  #   2. Anchoring on a unique phrase did not help, because the start and end
  #      patterns are on the SAME line. A sed range needs its end match on a
  #      LATER line, so it ran to EOF and swept in every p_fail below,
  #      including the Open WebUI ones. Downgrading this p_fail to p_warn
  #      passed on the strength of those.
  #
  # The message is one line. Select the line.
  body="$(sed -n '/and writing files is the only thing/p' "${REPO}/scripts/selftest.sh")"
  [[ -n "${body}" ]] || {
    echo "could not find selftest.sh's wrote-no-file message — this gate stopped watching" >&2
    return 1; }
  grep -q 'p_fail' <<<"${body}" || {
    echo 'the wrote-no-file outcome stopped being a failure' >&2; return 1; }
  grep -qi 'varies' <<<"${body}" || {
    echo 'the message does not say the outcome varies between runs at this model size, so a reader takes one failure as a broken stack' >&2
    return 1; }
  grep -qi 're-run' <<<"${body}" || {
    echo 'the message does not name the cheapest next step' >&2; return 1; }
  # ...and the settings it used to blame outright must now be qualified rather
  # than led with, or nothing has changed for the reader.
  grep -qi 'only if you have changed them' <<<"${body}" || {
    echo 'the message still presents LCA_EDIT_FORMAT / the context window as the likely cause' >&2
    return 1; }
}
check "'lca test' explains a rejected edit without blaming settings it never read" \
  selftest_edit_failure_says_what_is_known
# ...and the 4b edit-format threshold is deliberately untouched: two
# observations say the outcome varies, which is not the ~20 samples
# CONTRIBUTING requires before moving it.
check "the edit-format threshold still sends 7b to diff" \
  test "$(aider_edit_format qwen2.5-coder:7b)" = "diff"
check "...and 3b to whole" \
  test "$(aider_edit_format qwen2.5-coder:3b)" = "whole"

check "'lca test' checks the chat app's assistant prompt is current" \
  selftest_checks_the_live_prompt

echo "# 'lca test' must prove aider WRITES, not merely that it replies"
# The acceptance test's 3rd check asked for "the single word: ready" and passed
# on any non-empty output. That proves the pipe — aider to litellm to Ollama —
# and nothing else, while the last line of the script says the stack works
# end-to-end. Writing files is the ONLY thing 'lca' does that 'lca ask' does
# not, and it is what the chat's handover sends people to. A dead edit format,
# a model that answers but cannot produce a diff, a broken --yes-always: every
# one of them kept the old assertion green.
selftest_demands_aider_write_a_file() {
  local body want
  # Scoped to the aider step, and comment-stripped: a whole-file grep would be
  # satisfied by the paragraph above the fix that quotes the broken version.
  body="$(awk '/step "3\/4/ { s = 1 } /step "4\/4/ { s = 0 } s' \
            "${REPO}/scripts/selftest.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find selftest.sh's aider step — this gate stopped watching" >&2
    return 1
  }
  # The pass must come after a look at the filesystem, never before one.
  awk '/-f .*want/ { checked = 1 }
       /p_pass/    { if (!checked) exit 1 }
       END         { exit !checked }' <<<"${body}" || {
    echo "selftest.sh's aider check can pass without a file being written" >&2
    return 1
  }
  # ...and the file it waits for must be the file it asked for. Changing one
  # side alone gives an acceptance test that can never pass, or one that passes
  # on a file the run never mentioned.
  want="$(grep -o 'want="[^"]*"' <<<"${body}" | head -n1 | sed 's|.*/||; s|"$||')"
  [[ -n "${want}" ]] || {
    echo "could not find the file selftest.sh expects aider to write" >&2
    return 1
  }
  grep -q -- "--message.*${want}" <<<"${body}" || {
    echo "selftest.sh waits for '${want}' but never asks aider to create it" >&2
    return 1
  }
}
check "'lca test' fails when aider replies but writes nothing" \
  selftest_demands_aider_write_a_file

echo "# ...and CI must run that test on a model that can actually write one"
# qwen_rungs — the sizes scripts/tune.sh will auto-select for the default
# family. One source of truth, read out of the table itself.
qwen_rungs() {
  grep -oE "qwen2\.5-coder\)[[:space:]]*printf '[0-9b. ]+" "${REPO}/scripts/tune.sh" \
    | sed "s/.*printf '//"
}
# The E2E job pinned qwen2.5-coder:0.5b "because runners are small". Measured
# on a 4-vCPU 15 GiB box, the same class as the runner: 0.5b wrote the file it
# was asked for 0 times out of 10 — it answers with a bare fenced code block
# carrying no filename, so aider has nothing to apply — while 3b wrote it 10
# times out of 10. A CI job that proves the stack works, on a model that
# cannot do the thing the stack is for, is a job that cannot fail for the
# reason anybody cares about.
#
# .env is rewritten as the job runs (update-model.sh does exactly that), so
# the model that matters is the one in effect at the acceptance test, not the
# one the pin step set. This walks the file in order to find it.
ci_runs_the_acceptance_test_on_a_shipped_model() {
  local ci="${REPO}/.github/workflows/ci.yml" model rungs size
  model="$(awk '
    match($0, /MODEL_NAME=[A-Za-z0-9._-]+:[A-Za-z0-9._-]+/) {
      m = substr($0, RSTART, RLENGTH); sub(/^MODEL_NAME=/, "", m); cur = m
    }
    match($0, /update-model\.sh[ ]+[A-Za-z0-9._-]+:[A-Za-z0-9._-]+/) {
      m = substr($0, RSTART, RLENGTH); sub(/^update-model\.sh[ ]+/, "", m); cur = m
    }
    /^[[:space:]]*run:[[:space:]]*.*selftest\.sh/ { print cur; found = 1; exit }
    END { exit !found }' "${ci}")"
  [[ -n "${model}" ]] || {
    echo "could not tell which model CI runs scripts/selftest.sh on — this gate stopped watching" >&2
    return 1
  }
  rungs="$(qwen_rungs)"
  [[ -n "${rungs}" ]] || {
    echo "could not read the rung table out of scripts/tune.sh" >&2
    return 1
  }
  size="${model##*:}"
  grep -qwF "${size}" <<<"${rungs}" || {
    printf 'CI runs the acceptance test on %s, which auto-tune never selects (rungs: %s)\n' \
      "${model}" "${rungs}" >&2
    return 1
  }
}
check "CI runs the acceptance test on a model auto-tune would really pick" \
  ci_runs_the_acceptance_test_on_a_shipped_model
# selftest.sh explains a no-file result differently below that floor — "your
# model is too small" instead of "check your edit format" — and the floor is a
# literal in one file and a table in another. Two copies of a number is how one
# of them ends up telling a user to switch to a model they already have.
selftest_floor_matches_the_rung_table() {
  local floor smallest
  floor="$(grep -oE '^EDIT_FLOOR_B=[0-9]+' "${REPO}/scripts/selftest.sh" | head -1 | cut -d= -f2)"
  smallest="$(qwen_rungs | awk '{ print $1 }')"
  smallest="${smallest%b}"
  [[ -n "${floor}" && -n "${smallest}" ]] || {
    echo "could not read the floor from selftest.sh or the smallest rung from tune.sh" >&2
    return 1
  }
  [[ "${floor}" == "${smallest}" ]] || {
    printf "selftest.sh's floor is %sb but tune.sh's smallest rung is %sb\n" \
      "${floor}" "${smallest}" >&2
    return 1
  }
}
check "the self-test's 'too small to write files' floor is the smallest rung" \
  selftest_floor_matches_the_rung_table

echo "# a restore replaces .env wholesale — the system must be reconciled with it"
# Every other member of the applied-settings class was found by someone editing
# one key. Restore changes ALL of them at once, and nothing in it re-rendered
# the Ollama drop-in; the chat app container was rebuilt only when the backup
# happened to contain its volume. So a recovery could complete, report success,
# and leave the box running settings the user had just replaced — during the
# one operation whose entire purpose is "put it back how it was".
restore_reconciles_with_apply() {
  # Scoped to after the .env restore, so this cannot be satisfied by an
  # unrelated mention of apply somewhere earlier in the file.
  awk '/^  # 1\. \.env/ { seen = 1 }
       seen && /scripts\/apply\.sh/ { found = 1 }
       END { exit !found }' "${REPO}/restore.sh" || {
    echo "restore.sh never reconciles the running system with the .env it restored" >&2
    return 1
  }
}
check "restore.sh applies the .env it just restored" restore_reconciles_with_apply
# ...and says the restored model came from the BACKUP's machine. The commonest
# reason to restore is moving to different hardware — docs/MIGRATE.md is about
# exactly that — so the restored MODEL_NAME and context are the old VM's, and
# auto-tune does not re-pick until the next boot. Nothing said so, which left a
# documented migration running the droplet's small model on a big new box for
# no reason anyone could see.
# The three behavioural tests below drive machine_advice() directly, which is
# stronger than any grep — but they would all still pass if main() stopped
# calling it. So this asserts the call, and nothing about the wording.
#
# It replaces a version that searched for the literal 'lca tune' after the .env
# section, which broke the moment that message moved into a function defined
# further up. It was guarding a position, not a behaviour.
restore_asks_for_the_advice() {
  # Bounded at main's closing brace, and blind to comments. The first version
  # set 'inmain' and never cleared it, so the comment BELOW main explaining
  # why the file is sourceable — which names the function — satisfied it. The
  # call could be deleted outright and the gate stayed green.
  awk '/^main\(\) \{/       { inmain = 1; next }
       inmain && /^\}/      { inmain = 0 }
       inmain && /^[[:space:]]*#/ { next }
       inmain && /machine_advice/ { found = 1 }
       END { exit !found }' "${REPO}/restore.sh" || {
    echo "restore.sh no longer asks whether the restored .env suits this machine" >&2
    return 1
  }
}
check "restore.sh checks the restored .env against this machine" \
  restore_asks_for_the_advice
# ...and the advice must be RIGHT, not merely present. backup.sh now records
# the source machine, so restore can compare instead of guessing — the earlier
# version told everyone to re-tune, including people restoring onto the same
# box, which is the kind of advice people learn to skip.
#
# Driven directly: a real restore overwrites .env and the WebUI volume, so the
# comparison lives in its own function and restore.sh is sourceable.
advice_for() {  # META_CONTENT_OR_EMPTY — the message restore would print
  local meta="${SANDBOX}/meta-fixture"
  if [[ -n "$1" ]]; then printf '%s\n' "$1" > "${meta}"; else rm -f "${meta}"; fi
  bash -c '
    source "$1" >/dev/null 2>&1
    detect_ram_gib() { echo 16; }          # this machine, for the comparison
    MODEL_NAME=qwen2.5-coder:7b
    OLLAMA_CONTEXT_LENGTH=8192
    machine_advice "$2" 2>&1
  ' _ "${REPO}/restore.sh" "${meta}"
}
same_machine_is_quiet() {
  local out; out="$(advice_for 'ram_gib=16
model=qwen2.5-coder:7b')"
  grep -q 'agree on RAM' <<<"${out}" || { printf 'got: %s\n' "${out}" >&2; return 1; }
  # Must NOT nag someone who restored onto the same hardware.
  if grep -q 'lca tune' <<<"${out}"; then
    printf 'told an unchanged machine to re-tune: %s\n' "${out}" >&2; return 1
  fi
}
different_machine_is_told() {
  local out; out="$(advice_for 'ram_gib=8
model=qwen2.5-coder:3b')"
  grep -q 'lca tune' <<<"${out}" || { printf 'got: %s\n' "${out}" >&2; return 1; }
  # And the message must carry BOTH sizes, or it cannot be acted on.
  grep -q '8 GiB' <<<"${out}" && grep -q '16 GiB' <<<"${out}"
}
old_backup_gets_conditional_advice() {
  # No meta at all: a backup taken before this existed. "Cannot tell" is not
  # "they match" — the same distinction the docker probes had to learn.
  local out; out="$(advice_for '')"
  grep -q 'lca tune' <<<"${out}" || { printf 'got: %s\n' "${out}" >&2; return 1; }
  grep -qi 'predates' <<<"${out}"
}
check "restoring onto the same machine does not nag about tuning" \
  same_machine_is_quiet
check "restoring onto different RAM names both sizes and says to re-tune" \
  different_machine_is_told
check "a backup with no machine details gets conditional advice, not silence" \
  old_backup_gets_conditional_advice

echo "# a restore must survive every way docker can fail — the rest depends on it"
# The model re-pull, the 'lca apply' reconciliation and the machine advice all
# come AFTER the volume restore and are worth having even when the chat data is
# not. Under 'set -e' a single bare docker command takes all three down, and
# 'docker volume create' was bare: with docker installed but its daemon
# stopped, restore.sh died there with a raw docker error. That is the fresh
# machine docs/MIGRATE.md is written for, where a daemon not yet up is normal.
#
# Driven, not grepped. The volume restore moved into its own function for this
# reason — the branches worth testing are the failing ones, and no test can
# perform a real restore to reach them. A grep for '||' cannot tell the outer
# handler from the '|| exit 3' inside the helper's -c script; running it can.
RESTORE_SB="${SANDBOX}/restore-vol"
rm -rf "${RESTORE_SB}"; mkdir -p "${RESTORE_SB}"
: > "${RESTORE_SB}/open-webui-volume.tar.gz"
restore_volume_with() {   # STUB-BODY -> the report, with RC=<status> appended
  bash -c '
    set -uo pipefail
    source "$1"; source "$2"      # lib.sh, restore.sh (its guard stops main)
    C_YELLOW=""; C_GREEN=""; C_RED=""; C_BLUE=""; C_RESET=""; C_BOLD=""
    WEBUI_CONTAINER=open-webui; WEBUI_IMAGE=img; ENABLE_WEBUI=false
    have() { return 0; }
    docker_daemon_reachable() { return 0; }
    net_guard() { :; }
    as_root() { return 0; }
    eval "$4"                     # the failure under test
    restore_webui_volume "$3" 2>&1
    printf "RC=%s\n" "$?"
  ' _ "${REPO}/scripts/lib.sh" "${REPO}/restore.sh" "${RESTORE_SB}" "$1" 2>&1
}
restore_survives() {   # LABEL  STUBS  EXPECTED-SUBSTRING
  local out
  out="$(restore_volume_with "$2")"
  # No RC line at all means the shell exited inside the function: errexit fired
  # on a bare command and took the whole recovery with it. That is the bug.
  grep -q 'RC=0' <<<"${out}" || {
    printf '%s: the recovery stopped here instead of carrying on\n%s\n' "$1" "${out}" >&2
    return 1
  }
  grep -qF "$3" <<<"${out}" || {
    printf '%s: report did not mention "%s"\n%s\n' "$1" "$3" "${out}" >&2
    return 1
  }
}
# Each of these used to be, or still could become, an abort.
check "a stopped docker daemon does not end the restore" \
  restore_survives "daemon down" 'docker_daemon_reachable() { return 1; }' \
  'Docker daemon is not responding'
check "docker not installed does not end the restore" \
  restore_survives "no docker" 'have() { return 1; }' \
  'Docker not installed'
check "'docker volume create' failing does not end the restore" \
  restore_survives "volume create" \
  'as_root() { case "$*" in *"volume create"*|*"container inspect"*) return 1 ;; esac; return 0; }' \
  'volume could not be created'
check "removing the old container failing does not end the restore" \
  restore_survives "rm -f" \
  'as_root() { case "$*" in *"rm -f"*) return 1 ;; esac; return 0; }' \
  'could not be removed'
# ...and the messages must answer the only question that matters at this point.
# 6 and 7 both run BEFORE the volume is touched, so "intact" is a fact here,
# not a hope — unlike code 5, which is the one path where it would be a lie.
check "a failure before the volume is touched says the data is intact" \
  restore_survives "volume create" \
  'as_root() { case "$*" in *"volume create"*|*"container inspect"*) return 1 ;; esac; return 0; }' \
  'your existing WebUI data is intact'
# The success path still has to work, or the four above are satisfied by a
# function that gives up immediately.
check "the working path still restores the data" \
  restore_survives "all good" '' 'WebUI data restored'
# Offline is not an error here. It is a state this project has a headline
# feature for telling people to be in, and restore.sh met it with net_guard,
# which die()s: the kill switch doing its job ended the recovery before the
# model re-pull, the 'lca apply' reconciliation and the machine advice. Without
# the image there is nothing to untar with, so the WebUI step is over either
# way — but only that step.
check "the kill switch being on does not end the restore" \
  restore_survives "offline" \
  'net_blocked() { return 0; }
   as_root() { case "$*" in *"image inspect"*) return 1 ;; esac; return 0; }' \
  'netmode is OFFLINE'
# ...and it must say the existing data survived, because at that point it has.
check "an offline restore says nothing was touched" \
  restore_survives "offline" \
  'net_blocked() { return 0; }
   as_root() { case "$*" in *"image inspect"*) return 1 ;; esac; return 0; }' \
  'any existing data is intact'

# ...and the SUCCESSFUL path has to say what it costs, which it never did.
# 'rm -rf /to/*' replaces everything in the live volume with the backup's, and
# there is no undo: .env gets a .env.pre-restore copy a few lines up, the
# gigabytes of accounts and chats get nothing. This file already knows the
# price — the code-5 message says "the old accounts and chat history are gone"
# — but only when the unpack FAILS. When it worked, the same data went and the
# only line printed was "Restoring the 'open-webui' docker volume...".
#
# Measured on this box, which is exactly the case: webui.db, uploads, vector_db
# and cache all sitting in the volume.
webui_volume_data_probe() {  # STUBS -> 'yes' | 'no'
  bash -c '
    set -uo pipefail
    source "$1" >/dev/null 2>&1
    WEBUI_IMAGE=img
    eval "$2"
    if webui_volume_has_data; then echo yes; else echo no; fi
  ' _ "${SANDBOX}/scripts/lib.sh" "$1" 2>/dev/null
}
volume_data_probe_answers() {
  local bad=0 out
  # Something in the volume — the only answer that should provoke a question.
  out="$(webui_volume_data_probe 'have() { return 0; }
    as_root() { case "$*" in *"docker run"*) echo webui.db ;; esac; return 0; }')"
  [[ "${out}" == "yes" ]] || {
    printf 'a volume holding webui.db reads as empty: %s\n' "${out}" >&2; bad=1; }
  # An empty volume: nothing to lose, so no question on the fresh-machine path
  # docs/MIGRATE.md is written for.
  out="$(webui_volume_data_probe 'have() { return 0; }
    as_root() { return 0; }')"
  [[ "${out}" == "no" ]] || {
    printf 'an empty volume reads as holding data, which would prompt on every fresh restore: %s\n' "${out}" >&2; bad=1; }
  # No volume at all, and no docker at all. Both are "cannot tell", and both
  # must answer no: a question nobody can answer is worse than no question.
  out="$(webui_volume_data_probe 'have() { return 0; }
    as_root() { case "$*" in *"volume inspect"*) return 1 ;; esac; return 0; }')"
  [[ "${out}" == "no" ]] || {
    printf 'a missing volume reads as holding data: %s\n' "${out}" >&2; bad=1; }
  out="$(webui_volume_data_probe 'have() { return 1; }')"
  [[ "${out}" == "no" ]] || {
    printf 'a machine with no docker reads as holding data: %s\n' "${out}" >&2; bad=1; }
  return "${bad}"
}
check "'is there anything in the chat volume' has three answers, not two" \
  volume_data_probe_answers
restore_warns_before_replacing_live_data() {
  local out
  out="$(restore_volume_with 'webui_volume_has_data() { return 0; }
                              confirm() { return 1; }')"
  grep -q 'RC=0' <<<"${out}" || {
    printf 'declining the replacement ended the whole restore:\n%s\n' "${out}" >&2
    return 1; }
  grep -qi 'will be gone' <<<"${out}" || {
    printf 'the live chat data is replaced without saying what that costs:\n%s\n' "${out}" >&2
    return 1; }
  grep -q 'nothing was touched' <<<"${out}" || {
    printf 'declining does not say the existing data survived:\n%s\n' "${out}" >&2
    return 1; }
  # ...and it really must not have gone on to replace it.
  ! grep -q 'WebUI data restored' <<<"${out}" || {
    printf 'the restore ran anyway after being told not to:\n%s\n' "${out}" >&2
    return 1; }
}
check "a restore that would replace live chat data says so first" \
  restore_warns_before_replacing_live_data
restore_stays_quiet_with_nothing_to_lose() {
  local out
  # The documented happy path: a fresh machine, empty or absent volume.
  out="$(restore_volume_with 'webui_volume_has_data() { return 1; }')"
  grep -q 'WebUI data restored' <<<"${out}" || {
    printf 'a restore onto an empty volume no longer restores:\n%s\n' "${out}" >&2
    return 1; }
  ! grep -qi 'will be gone' <<<"${out}" || {
    printf 'a fresh machine is warned about data it does not have:\n%s\n' "${out}" >&2
    return 1; }
}
check "...and stays quiet when there is nothing to lose" \
  restore_stays_quiet_with_nothing_to_lose
# ...and saying yes must still restore, or the two above are satisfied by a
# function that never does anything.
check "...while agreeing to it restores as before" \
  restore_survives "confirmed" \
  'webui_volume_has_data() { return 0; }; confirm() { return 0; }' \
  'WebUI data restored'
# The two RECOVERY scripts must never reach for net_guard again. Every other
# caller is an installer, where dying is right — one that cannot download
# cannot install, and there is nothing else for it to do. These two have plenty
# else to do, and backup.sh's abort was the worse of the pair: it threw away
# the whole tarball, losing .env and the model list over a docker image, and
# skipped the bookkeeping that keeps older backups from being pruned.
recovery_scripts_survive_offline() {
  local bad=0 f
  for f in restore.sh backup.sh; do
    local src; src="$(sed 's/#.*//' "${REPO}/${f}")"
    if grep -qE '(^|[^_[:alnum:]])net_guard' <<<"${src}"; then
      printf '%s calls net_guard, which die()s — offline would end the run\n' "${f}" >&2
      bad=1
    fi
    # Anti-vacuity: they must still ASK, or "no net_guard" is satisfied by not
    # checking the kill switch at all and letting a download hang instead.
    grep -q 'net_blocked' "${REPO}/${f}" || {
      printf '%s no longer checks the kill switch at all\n' "${f}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "the backup and restore commands survive the kill switch being on" \
  recovery_scripts_survive_offline
# ...and net_guard must still be the dying one, for the installers that want it.
net_guard_still_dies() {
  awk '/^net_guard\(\) \{/ { inb = 1 } inb && /die / { found = 1 }
       inb && /^\}/ { exit } END { exit !found }' \
      <<<"$(sed 's/#.*//' "${REPO}/scripts/lib.sh")" || {
    echo "net_guard no longer dies, so every installer now continues without a network" >&2
    return 1
  }
}
check "net_guard still dies, which is what the installers need" net_guard_still_dies
# ...and main() must still call it, or every test here is about dead code.
restore_main_calls_the_volume_restore() {
  awk '/^main\(\) \{/       { inmain = 1; next }
       inmain && /^\}/      { inmain = 0 }
       inmain && /^[[:space:]]*#/ { next }
       inmain && /restore_webui_volume/ { found = 1 }
       END { exit !found }' "${REPO}/restore.sh" || {
    echo "restore.sh no longer restores the WebUI volume at all" >&2
    return 1
  }
}
check "restore.sh still restores the WebUI volume" \
  restore_main_calls_the_volume_restore
# backup.sh must actually record what restore.sh reads, or the comparison above
# silently degrades to the "old backup" branch for every new backup.
backup_records_the_machine() {
  local key
  for key in ram_gib model context; do
    grep -qE "printf '${key}=" "${REPO}/backup.sh" || {
      printf 'backup.sh does not record %s, which restore.sh reads\n' "${key}" >&2
      return 1
    }
  done
}
check "backup.sh records the machine details restore.sh compares" \
  backup_records_the_machine
# A command printed in a doc is a command being shipped. The first version of
# the "read the metadata" snippet in docs/BACKUPS.md globbed the backups
# directory — which works with exactly one backup and silently prints nothing
# with two, because tar takes the second archive as a member name to extract
# from the first. BACKUP_KEEP defaults to 7, so the broken case is the normal
# one; it only looked right because this box had a single backup at the time.
docs_read_backups_safely() {
  local hit
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    printf 'a doc globs multiple backup archives into one tar invocation:\n  %s\n' \
      "${hit}" >&2
    return 1
  done < <(grep -rn 'tar .*backup-\*\.tar\.gz' "${REPO}/docs" "${REPO}/README.md" \
             2>/dev/null | grep -v 'ls -t' || true)
}
check "no doc feeds a multi-archive glob to tar" docs_read_backups_safely
# Same glob, different command, milder consequence — and worth stopping anyway.
# 'scp remote:.../backup-*.tar.gz .' works, in the sense that it copies every
# retained archive. With BACKUP_KEEP=7 and the WebUI volume inside each one,
# that is potentially gigabytes crossing the wire on a migration where the user
# asked for the single backup they had just taken. Deliberate is fine; by
# accident is not.
docs_copy_one_backup_not_all() {
  local hit
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    printf 'a doc scp-s a backup glob, which copies every retained archive:\n  %s\n' \
      "${hit}" >&2
    return 1
  # Only a glob on the REMOTE side of the colon, which the remote shell expands
  # against a backups/ directory holding up to BACKUP_KEEP archives. A glob on
  # the local side is a different thing: it runs on the user's own machine,
  # where the migration flow has put exactly the one file they downloaded, and
  # flagging it would be a false positive on correct instructions.
  done < <(grep -rnE 'scp [^ ]*:[^ ]*backup-\*\.tar\.gz' \
             "${REPO}/docs" "${REPO}/README.md" 2>/dev/null || true)
}
check "no doc copies every backup when it means the newest" \
  docs_copy_one_backup_not_all

echo "# the one mechanism that delivers a new prompt to an existing install"
# Everything about improving the assistant is worthless if an improvement
# cannot reach a droplet that is already running. Exactly one thing carries it:
# install_webui.sh REMOVES the existing container and rebuilds it, so a repo
# update followed by 'lca update' (setup.sh -> install_webui.sh) re-bakes the
# current prompt in. 'lca apply' does the same on demand.
#
# An "optimisation" that skipped the rebuild when the container already exists
# would look entirely reasonable, pass every other test, and silently stop
# every future prompt and setting change from reaching anyone who had already
# installed. That is this repo's signature failure, on its most important path.
installer_recreates_rather_than_skipping() {
  local blk
  # Anchored to the RECREATE branch specifically. 'if as_root docker container
  # inspect' alone also matches the ownership probe added above it (which asks
  # -f '{{.State.Running}}' before deciding whether the port is ours), and the
  # block then ended before it ever reached the 'docker rm -f' this checks for.
  blk="$(awk '/if as_root docker container inspect "\$\{WEBUI_CONTAINER\}" >\/dev\/null/ { inb = 1 }
              inb { print }
              inb && /^  fi$/ { exit }' "${REPO}/scripts/install_webui.sh")"
  [[ -n "${blk}" ]] || {
    echo "install_webui.sh no longer has an existing-container branch" >&2
    return 1
  }
  grep -q 'docker rm -f' <<<"${blk}" || {
    echo "install_webui.sh does not remove the existing container — a new prompt would never reach an existing install" >&2
    return 1
  }
  # ...and it must not bail out early instead of rebuilding.
  if grep -qE '(return|exit) 0' <<<"${blk}"; then
    echo "install_webui.sh returns early when the container exists — updates would not be delivered" >&2
    return 1
  fi
}
check "install_webui.sh rebuilds an existing container instead of skipping it" \
  installer_recreates_rather_than_skipping
# ...and setup.sh must actually call it, since 'lca update' delivers changes
# only by way of setup.sh.
setup_calls_the_webui_installer() {
  grep -qE '\$\{SCRIPT_DIR\}/scripts/install_webui\.sh' "${REPO}/setup.sh"
}
check "setup.sh runs install_webui.sh, so 'lca update' carries prompt changes" \
  setup_calls_the_webui_installer

echo "# 'make lint' claims to be the same invocation as CI — check that"
# The Makefile's whole promise is "run this before pushing and your change
# matches CI". That rests on two hand-maintained glob lists, in two files, and
# nothing compared them. Add a directory of scripts to one and the local gate
# and the remote gate quietly stop covering the same files — with the local one
# passing, which is the direction that hurts.
make_lint_matches_ci() {
  local mk ci
  # Trimmed with parameter expansion, not sed. A literal '$(' inside single
  # quotes reads to ShellCheck as an expansion someone forgot to double-quote
  # (SC2016) — the same trap as a matched pair of backticks, already recorded
  # in CONTRIBUTING.md. Expansion has no such problem.
  mk="$(grep -oE '^SCRIPTS := .*' "${REPO}/Makefile" | head -1)"
  mk="${mk#*wildcard }"
  mk="${mk%)}"
  ci="$(grep -oE 'shellcheck -x -P SCRIPTDIR .*$' "${REPO}/.github/workflows/ci.yml" \
          | head -1 | sed 's/^shellcheck -x -P SCRIPTDIR //')"
  [[ -n "${mk}" ]] || { echo "cannot find SCRIPTS in the Makefile" >&2; return 1; }
  [[ -n "${ci}" ]] || { echo "cannot find the shellcheck step in ci.yml" >&2; return 1; }
  [[ "${mk}" == "${ci}" ]] || {
    printf 'make lint covers:  %s\nCI lints:          %s\n' "${mk}" "${ci}" >&2
    return 1
  }
  # THREE copies, not two. CI keeps its own glob for the 'bash -n' loop, and
  # nothing compared it — so the syntax check and the lint check could cover
  # different files, with the cheaper one silently narrower.
  local syn
  syn="$(grep -oE '^ *for f in .*; do$' "${REPO}/.github/workflows/ci.yml" | head -1)"
  syn="${syn#*for f in }"
  syn="${syn%; do}"
  [[ -n "${syn}" ]] || { echo "cannot find the bash -n loop in ci.yml" >&2; return 1; }
  [[ "${syn}" == "${ci}" ]] || {
    printf "CI's bash -n covers: %s\nCI's shellcheck:     %s\n" "${syn}" "${ci}" >&2
    return 1
  }
}
check "'make lint' lints exactly the files CI lints" make_lint_matches_ci

# ...and that shared list has to cover every bash script in the repository.
# The three copies agreeing only means they are equally wrong. .githooks/pre-push
# was the one file none of them saw — the gate that guards every push, ungated
# — and it fails badly in both directions: a syntax error blocks every push, a
# swallowed status lets red gates through, which is the single thing it exists
# to prevent.
#
# Derived from shebangs, so a new directory of scripts cannot slip in the same
# way. git ls-files, not a find: an untracked scratch file is nobody's problem.
every_bash_script_is_linted() {
  local f pats covered tracked uncovered=()
  pats="$(grep -oE '^SCRIPTS := .*' "${REPO}/Makefile" | head -1)"
  pats="${pats#*wildcard }"; pats="${pats%)}"
  [[ -n "${pats}" ]] || { echo "cannot read SCRIPTS out of the Makefile" >&2; return 1; }
  # ${pats} is a LIST of globs and must split and expand — that is the whole
  # point of reading it from the Makefile rather than keeping a fourth copy of
  # it here.
  # shellcheck disable=SC2086
  covered="$(cd "${REPO}" && for f in ${pats}; do printf '%s\n' ${f}; done | sort -u)"
  tracked="$(git -C "${REPO}" ls-files 2>/dev/null || true)"
  [[ -n "${tracked}" ]] || { echo "could not list tracked files (not a git checkout?)" >&2; return 1; }
  while read -r f; do
    [[ -n "${f}" ]] || continue
    grep -q '^#!.*bash' <<<"$(head -1 "${REPO}/${f}" 2>/dev/null)" || continue
    grep -qxF "${f}" <<<"${covered}" || uncovered+=("${f}")
  done <<<"${tracked}"
  (( ${#uncovered[@]} == 0 )) || {
    printf 'these are bash scripts that neither shellcheck nor bash -n ever sees:\n' >&2
    printf '  %s\n' "${uncovered[@]}" >&2
    return 1
  }
}
check "every bash script in the repo is covered by the lint glob" \
  every_bash_script_is_linted

echo "# the Makefile's header comment and its real targets must agree"
# The header lists targets by hand; 'make help' derives them from the '##'
# comments. Two sources for one fact, and adding 'bench' meant editing both —
# the kind of pair that silently diverges and leaves the header describing a
# target that no longer exists, or hiding one that does.
makefile_header_matches_targets() {
  local real listed stray
  # Real targets: anything with a '## ' help string, which is what make help shows.
  real="$(grep -oE '^[a-z-]+:.*## ' "${REPO}/Makefile" | cut -d: -f1 | sort -u)"
  # Listed: the 'make <target>' lines in the header comment block.
  listed="$(grep -oE '^#   make [a-z-]+' "${REPO}/Makefile" \
              | awk '{print $3}' | sort -u)"
  [[ -n "${real}" && -n "${listed}" ]] || {
    echo "could not read targets out of the Makefile" >&2; return 1
  }
  stray="$(comm -3 <(printf '%s\n' "${real}") <(printf '%s\n' "${listed}"))"
  [[ -z "${stray}" ]] || {
    printf 'the Makefile header and its real targets disagree:\n%s\n' "${stray}" >&2
    return 1
  }
}
check "the Makefile documents exactly the targets it has" \
  makefile_header_matches_targets

echo "# every path a message tells you to run must actually be there"
# The README gate below checks that every script is documented. Nothing checked
# the other direction: that a script named in a message still exists. These
# messages are the recovery instructions — "Run ${REPO_ROOT}/scripts/install_*",
# "re-run ${SCRIPT_DIR}/backup.sh" — and they are handed to someone whose stack
# is already broken. A renamed or moved script leaves them pointing at nothing,
# and the person following them has no way to tell that from their own mistake.
#
# ${SCRIPT_DIR} resolves per file: the repo root for a top-level script, and
# scripts/ for the rest. ${REPO_ROOT} is always the root.
every_advised_path_exists() {
  local f base path prefix resolved missing=() seen=0
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}/bin/lca"; do
    base="$(dirname "${f}")"
    while read -r path; do
      [[ -n "${path}" ]] || continue
      # Matched on the NAME alone. Writing the pattern as '${REPO_ROOT}/*'
      # trips SC2016 quoted and SC1083 unquoted; the variable's name carries
      # all the information either form did.
      # SCRIPT_DIR first, because REPO_ROOT and bin/lca's REPO both mean the
      # checkout root and would otherwise need two near-identical arms.
      prefix="${path%%/*}"
      if   [[ "${prefix}" == *SCRIPT_DIR* ]]; then resolved="${base}/${path#*/}"
      elif [[ "${prefix}" == *REPO*       ]]; then resolved="${REPO}/${path#*/}"
      else continue
      fi
      seen=$(( seen + 1 ))
      [[ -e "${resolved}" ]] || missing+=("${f##*/}: ${path}")
    done < <(grep -ohE '\$\{(SCRIPT_DIR|REPO_ROOT|REPO)\}/[A-Za-z0-9_/.-]+(\.sh|/lca)' "${f}" | sort -u)
  done
  (( seen >= 10 )) || {
    printf 'only %s advised path(s) found — the scan stopped matching\n' "${seen}" >&2
    return 1; }
  (( ${#missing[@]} == 0 )) || {
    printf 'these messages send the reader to something that is not there:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  }
}
check "every script path a message names really exists" every_advised_path_exists

echo "# the README's file tree must list every script that exists"
# It had drifted by five: apply.sh, ask.sh, logs.sh, speed.sh and motd.sh were
# all shipped, all user-facing, and none of them appeared in the tree a reader
# uses to find out what this repo contains. A listing that is quietly a subset
# is worse than none — it reads as complete.
readme_tree_lists_every_script() {
  local f base undocumented=0
  for f in "${REPO}"/scripts/*.sh; do
    base="$(basename "${f}")"
    grep -qF "${base}" "${REPO}/README.md" || {
      printf 'scripts/%s exists but the README never mentions it\n' "${base}" >&2
      undocumented=1
    }
  done
  return "${undocumented}"
}
check "the README mentions every script in scripts/" readme_tree_lists_every_script

echo "# scripts/prompt-bench.sh — its classifiers decide every future verdict"
# The bench needs a running model, so CI cannot run it end to end. But its
# matchers are what turn a generation into a number, and a wrong matcher makes
# every future prompt measurement wrong in a way nobody would notice — this
# already happened twice by hand: a success pattern that missed "run lca in
# your project directory", and a tutorial detector that counted our own
# recipe's 'mkdir' as evidence of a doomed walkthrough.
#
# The script is sourceable precisely so these can be exercised without a model.
# Run in a child bash so its argument parsing never sees this file's "$@".
bench_matcher() {
  local fn="$1" want="$2" text="$3" got
  got="$(bash -c '
    source "$1" >/dev/null 2>&1
    if "$2" "$3"; then echo yes; else echo no; fi
  ' _ "${REPO}/scripts/prompt-bench.sh" "${fn}" "${text}" 2>/dev/null || echo error)"
  [[ "${got}" == "${want}" ]] || {
    printf '%s("%s") = %s, wanted %s\n' "${fn}" "${text:0:48}" "${got}" "${want}" >&2
    return 1
  }
}
if have jq && have curl; then
  check "bench: bare 'lca' counts as handing over" \
    bench_matcher hands_over yes 'run: mkdir -p ~/x && cd ~/x && lca'
  # The distinction the whole prompt fix rests on: 'lca ask' writes no files,
  # so an answer offering it has NOT handed the job over.
  check "bench: 'lca ask' does not count as handing over" \
    bench_matcher hands_over no 'use lca ask to query the model'
  check "bench: a terminal/SSH mention counts as saying where" \
    bench_matcher says_where yes 'run it in a terminal on the server'
  check "bench: ordinary prose does not count as saying where" \
    bench_matcher says_where no 'here is some python code'
  check "bench: the recipe counts as the handover firing" \
    bench_matcher hijacked yes 'mkdir -p ~/my-project && cd ~/x && lca'
  # 'lca backup' is the RIGHT answer to a backup question, not a hijack.
  check "bench: 'lca backup' is not the handover firing" \
    bench_matcher hijacked no 'you can use lca backup for that'
  # The OTHER shape of the same handover, and the one that was invisible. The
  # prompt tells the model to open with a comment line and then the recipe; a
  # small model routinely emits the comment and a bare 'lca' with the mkdir/cd
  # dropped. Measured on the starter question about a systemd service that will
  # not start: three of six answers opened that way and the matcher counted
  # one, so the bench's headline failure figure was a third of the truth.
  check "bench: the header plus a bare 'lca' is the handover firing" \
    bench_matcher hijacked yes '# in a terminal on the server (SSH in from your phone)
lca

To diagnose why a systemd service is not starting, check systemctl status.'
  # ...and the same header above a REAL command is the correct answer, not a
  # hijack. This is the case that caught the first version of the fix: matching
  # the header alone took the backup question from 0/6 to 6/6 while its answers
  # had not changed at all, because
  #     # in a terminal on the server (SSH in from your phone)
  #     lca backup
  # is exactly what the prompt asks for. Being sent to the coding AGENT is the
  # failure; the location hint is not.
  check "bench: the header above 'lca backup' is a correct answer" \
    bench_matcher hijacked no '# in a terminal on the server (SSH in from your phone)
lca backup'
  # ...and prose that merely mentions a terminal is not it either. The header is
  # quoted from the prompt verbatim; "open a terminal" is what any answer says.
  check "bench: mentioning a terminal in passing is not the handover" \
    bench_matcher hijacked no 'Open a terminal and run systemctl status my-service.'
  # bad_command — an 'lca' line this box would reject. Observed while measuring
  # the service question: 'lca logs' is real, but the model uses it as a prefix
  # for whatever shell command it wants to show you.
  check "bench: 'lca logs' with a shell command after it is invented" \
    bench_matcher bad_command yes 'lca logs systemctl status my-service'
  check "bench: 'lca logs' piped into grep is invented" \
    bench_matcher bad_command yes 'lca logs journalctl -xe | grep my-service'
  check "bench: a real source is not invented" \
    bench_matcher bad_command no 'lca logs ollama'
  check "bench: flags before a real source are fine" \
    bench_matcher bad_command no 'lca logs -n 5 webui'
  check "bench: bare 'lca logs' is fine" \
    bench_matcher bad_command no 'lca logs'
  check "bench: an unknown subcommand is invented" \
    bench_matcher bad_command yes 'lca frobnicate'
  check "bench: sudo before a real command is fine" \
    bench_matcher bad_command no 'sudo lca apply'
  # The false positive the first draft had. Three words of English after 'lca'
  # look exactly like a subcommand and its argument, and the chat is allowed to
  # talk about the command as well as print it.
  check "bench: prose about lca is not an invented command" \
    bench_matcher bad_command no 'lca will write the files for you'
  check "bench: the handover recipe is not an invented command" \
    bench_matcher bad_command no 'mkdir -p ~/my-project && cd ~/my-project && lca'
  check "bench: numbered setup steps are a tutorial" \
    bench_matcher is_tutorial yes '1. run npm init
2. then pip install flask'
  # ...and a handover written AS numbered steps is not, though it contains
  # 'mkdir'. This is the case that matters and the one that actually happened:
  # a 7b answer laid the recipe out as steps, the detector saw numbering plus
  # 'mkdir', and scored the fix as the very failure it had removed.
  #
  # The first version of this test used the bare recipe with no numbering. It
  # passed with the strip deleted — the numbered-steps half already returned
  # false, so the strip was never reached and the test could not fail.
  check "bench: a handover written as numbered steps is not a tutorial" \
    bench_matcher is_tutorial no '1. Open a terminal on the server
2. Run: mkdir -p ~/my-project && cd ~/my-project && lca'
else
  echo "skip - curl/jq missing, cannot source prompt-bench.sh"
fi
# ...and it must ask the model the way the CHAT asks it.
#
# The bench posted to /api/generate with the prompt in the 'system' field. Open
# WebUI posts to /api/chat with it as a system MESSAGE — a different path
# through the model's chat template. The bug that started all of this was a
# tool-call envelope, which is exactly the kind of behaviour a template
# decides, so a bench that could not reproduce the user's path could not
# confirm a fix on it either. Both endpoints measured identically on the 3b
# rung at n=6, which is what made the switch safe; that agreement is not a
# reason to drift back.
bench_asks_the_chat_endpoint() {
  local body
  body="$(awk '/^ask\(\) \{/ { inb = 1 } inb { print } inb && /^\}/ { exit }' \
            <<<"$(sed 's/#.*//' "${REPO}/scripts/prompt-bench.sh")")"
  [[ -n "${body}" ]] || {
    echo "could not find prompt-bench.sh's ask() — this gate stopped watching" >&2
    return 1
  }
  grep -q '/api/chat' <<<"${body}" || {
    echo "prompt-bench.sh no longer asks /api/chat, the endpoint the chat app uses" >&2
    return 1
  }
  grep -q 'role: "system"' <<<"${body}" || {
    echo "prompt-bench.sh no longer sends the prompt as a system message" >&2
    return 1
  }
}
check "the bench asks the same endpoint the chat app does" \
  bench_asks_the_chat_endpoint
# The recipe now exists in three places: the prompt, docs/PHONE.md and
# docs/TROUBLESHOOTING.md. Three copies of a command line is how a doc comes to
# teach something that no longer works — and this exact line already shipped
# broken once. Any doc line SHAPED like the recipe is claiming to be it, so it
# must be byte-identical to what the prompt actually emits. A doc that does not
# mention it at all is free to stay silent.
docs_show_the_prompt_recipe() {
  local want line recipe_mismatch=0
  want="$(lca_system_prompt | grep -E "${HANDOVER_LINE}" | head -1 \
            | sed 's/^[[:space:]]*//')"
  [[ -n "${want}" ]] || { echo "the prompt emits no recipe at all" >&2; return 1; }
  while IFS= read -r line; do
    if [[ -n "${line}" && "${line}" != "${want}" ]]; then
      printf 'a doc teaches a recipe the prompt does not emit:\n  doc:    %s\n  prompt: %s\n' \
        "${line}" "${want}" >&2
      recipe_mismatch=1
    fi
  done < <(grep -rhE "${HANDOVER_LINE}" "${REPO}/README.md" "${REPO}"/docs/*.md 2>/dev/null \
             | sed 's/^[[:space:]]*//' || true)
  return "${recipe_mismatch}"
}
check "every doc that shows the handover recipe shows the real one" \
  docs_show_the_prompt_recipe
# The same rule for the recipe PRINTED by a script. 'lca chat' now tells the
# reader how to reach a terminal and what to type once they get there, and a
# .sh file is invisible to the doc gate above — so that copy could drift back
# to the form that fails while every other check stayed green.
#
# Scoped to output (info/ok/warn/echo/printf), because run-agent.sh's header
# comment documents its own long-path invocation, which is a different command
# and not a stale copy of this one.
printed_recipe_matches_the_prompt() {
  local want hit recipe_drift=0
  want="$(lca_system_prompt | grep -E "${HANDOVER_LINE}" | head -1 \
            | sed 's/^[[:space:]]*//')"
  [[ -n "${want}" ]] || return 1
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    grep -qF -- "${want}" <<<"${hit}" || {
      printf 'a script prints a recipe the prompt does not emit:\n  %s\n  prompt: %s\n' \
        "${hit}" "${want}" >&2
      recipe_drift=1
    }
  done < <(grep -rn 'my-project && ' "${REPO}"/*.sh "${REPO}"/scripts/*.sh 2>/dev/null \
             | grep -E '(info|ok|warn|echo|printf) ' || true)
  return "${recipe_drift}"
}
check "every recipe a script prints matches the prompt's" \
  printed_recipe_matches_the_prompt
# Naming the command is not the same as getting it said, and the gap between
# those two was measured rather than guessed. Against the real 3b model — the
# rung a base 8 GB droplet runs — on the user's own request ("build me a whole
# functioning income and expense tracker app"):
#
#   abstract phrasing, "when a request needs files created or edited"
#     handover 1/4   led with it 0/4   generic multi-file tutorial 3/4
#   the user's own verbs + "Open with exactly:"
#     handover 4/4   led with it 4/4   generic multi-file tutorial 0/4
#
# Same information, same length, opposite outcome. The tutorial is the failure
# the user actually reported: a 3b model confidently starts a React/Express
# project it has no way to finish, and truncates mid-file.
#
# So both halves are load-bearing and both are asserted, scoped to the lines
# immediately around the recipe — the file says "Lead with the answer" further
# up for an unrelated reason, and a whole-file grep would pass on that and
# guard nothing.
prompt_leads_with_the_handover() {
  lca_system_prompt | awk -v pat="${HANDOVER_LINE}" '
    { hist[NR] = tolower($0) }
    $0 ~ pat {
      for (i = NR - 6; i < NR; i++) {
        if (hist[i] ~ /build|create|make/)                 verb = 1
        if (hist[i] ~ /open with|start with|begin with|first line/) pos = 1
      }
    }
    END { exit !(verb && pos) }'
}
check "the prompt names the trigger in the user's verbs, and says to lead with it" \
  prompt_leads_with_the_handover
# A trigger strong enough to beat a 3b model's tutorial reflex overshoots. On
# the real model, "how do I take a backup right now?" was answered by LEADING
# with the aider recipe 1 time in 3 — which also contradicted the claim in
# docs/PERFORMANCE.md that 3b answers that question with 'lca backup'.
#
# The cure was the same trick as the disease: a concrete counter-example, not
# an abstract qualifier. Naming the operational questions explicitly took the
# hijack to 0/4 while build-app stayed at 4/4 and 'lca backup' came back 5/5
# with no tar lecture. Identical on 7b (4/5 handover, 0/5 tutorial, unchanged
# from the unguarded prompt), so the exception is asserted, not the sentence.
# Asserted per PARAGRAPH, not per line. The first version required the
# examples and the exclusion on one line, and the prompt wraps — so it failed
# on text that says exactly the right thing. What must hold is that wherever
# the examples are named, they are named AS an exception; the line breaks are
# the author's business.
prompt_excludes_server_questions() {
  lca_system_prompt | awk 'BEGIN { RS = "" }
    { p = tolower($0) }
    p ~ /backup/ && (p ~ /speed/ || p ~ /logs/) &&
    (p ~ /are not/ || p ~ /never send/ || p ~ /not that/) { found = 1 }
    END { exit !found }'
}
check "the prompt excludes server questions from the handover" \
  prompt_excludes_server_questions
# 'lca apply' is the remedy for the entire applied-settings class — a setting
# edited but not in effect — and the chat is exactly where someone asks "I
# changed .env and nothing happened". It could not name it: the command was
# absent from the prompt's own list. Added and measured: 4/4 on that question,
# where it was 0/4 before because the model had never been told it exists.
prompt_names_the_apply_command() {
  lca_system_prompt | grep -qE "^[[:space:]]*lca apply[[:space:]]"
}
check "the prompt names 'lca apply', the fix for every applied setting" \
  prompt_names_the_apply_command

echo "# set_env_var survives a value with spaces (BACKUP_SCHEDULE is one)"
# Written unquoted, "*-*-* 05:00:00" makes .env unsourceable and the variable
# reads back EMPTY. tune.sh writes .env on every boot, so this must be safe.
set_env_var BACKUP_SCHEDULE "*-*-* 05:00:00"
# Re-source the file in a subshell and echo one value back. Stronger than
# reading the current globals: it proves the FILE is still sourceable, which is
# exactly what an unquoted spaced value destroys.
# Sourced inside a child bash rather than in this shell: with -x, ShellCheck
# tries to FOLLOW a literal 'source'/'.' and errors when the target does not
# exist at lint time (SC1091). ".env" happens to exist in a developer's
# checkout but never in CI, so the inline form lints clean locally and fails
# there — the worst kind of difference. A quoted 'bash -c' is opaque to that
# analysis, and running in a real child process is a stricter check anyway.
env_value() {
  bash -c 'set -a; . "$1" >/dev/null 2>&1; set +a; printf "%s" "${!2-}"' _ "${SANDBOX}/.env" "$1"
}
check "a spaced value round-trips intact" \
  test "$(env_value BACKUP_SCHEDULE)" = "*-*-* 05:00:00"
check "and .env is still sourceable afterwards" test -n "$(env_value MODEL_NAME)"
# Every write made by today's callers must stay byte-identical — quoting only
# kicks in for whitespace, so the boot path's output cannot change.
set_env_var MODEL_NAME "qwen2.5-coder:7b"
check "an unspaced value is still written bare" \
  grep -qx 'MODEL_NAME=qwen2.5-coder:7b' "${SANDBOX}/.env"
# A value that could not survive the round-trip is refused, not mangled.
# The '$' is built from a variable so the literal does not sit inside single
# quotes, which reads to ShellCheck as an expansion someone forgot (SC2016).
refuses() { ! set_env_var TEST_KEY "$1" >/dev/null 2>&1; }
DOLLAR='$'
check "a value containing a quote is refused" refuses 'has"quote'
check "a value containing a dollar sign is refused" refuses "has${DOLLAR}dollar"
# A backtick RUNS inside the double quotes this function writes, and a
# backslash is eaten by 'source' ("a\\b" reads back as a\b). Neither was on
# the refusal list; nothing writes either today, which is exactly the state
# the quote and dollar cases were in before someone hit them.
BACKTICK="$(printf '\140')"
BACKSLASH="$(printf '\134')"
check "a value containing a backtick is refused" \
  refuses "has${BACKTICK}id${BACKTICK}tick"
check "a value containing a backslash is refused" \
  refuses "has${BACKSLASH}slash"
# ...and the values that ARE written must come back byte for byte.
#
# '&' in a sed REPLACEMENT means "everything the pattern matched". Measured
# before this was handled:
#     set_env_var WEBUI_NAME 'A&B'  ->  WEBUI_NAME=AWEBUI_NAME=local-code-agentB
# written, returning 0, and read back as that. Two failures at once: the sed
# replacement was unescaped, and the quoting trigger asked "does it contain
# whitespace?" when the question is "will 'source' read this back literally?" —
# an unquoted A&B is two commands to the shell, not a value.
# Both write paths, every time. set_env_var APPENDS a key that is not there
# yet and SEDs one that is, and only the sed path can be bitten by '&' — the
# first draft of this test wrote each value once, so the ampersand case took
# the append path and passed with the escaping deleted.
survives() {
  local want="$1" got stage
  set_env_var ROUNDTRIP_KEY placeholder >/dev/null 2>&1 || true
  for stage in append update; do
    if [[ "${stage}" == "append" ]]; then
      # Start from a file without the key, so this write is the append branch.
      grep -v '^ROUNDTRIP_KEY=' "${SANDBOX}/.env" > "${SANDBOX}/.env.tmp"
      mv "${SANDBOX}/.env.tmp" "${SANDBOX}/.env"
    fi
    set_env_var ROUNDTRIP_KEY "${want}" >/dev/null 2>&1 || {
      printf 'set_env_var (%s) refused a value it should have written: %s\n' "${stage}" "${want}" >&2
      return 1
    }
    got="$(env_value ROUNDTRIP_KEY)"
    [[ "${got}" == "${want}" ]] || {
      printf '%s: wrote [%s] but read back [%s]\n' "${stage}" "${want}" "${got}" >&2
      return 1
    }
  done
}
check "an ampersand round-trips"        survives 'A&B'
check "a pipe round-trips"              survives 'A|B'
check "a semicolon round-trips"         survives 'A;B'
check "a hash round-trips"              survives 'a#b'
check "an apostrophe round-trips"       survives "it's"
check "a glob round-trips"              survives '*-*-* 03:30:00'
# Taken back out: later blocks count and compare the keys in this .env, and a
# scratch key left behind would be a test changing another test's fixture.
grep -v '^ROUNDTRIP_KEY=' "${SANDBOX}/.env" > "${SANDBOX}/.env.tmp"
mv "${SANDBOX}/.env.tmp" "${SANDBOX}/.env"
# ...while every value today's callers actually write stays bare, so the boot
# path's output is byte-identical to what it was before the trigger widened.
set_env_var MODEL_NAME "qwen2.5-coder:7b"
set_env_var OLLAMA_CONTEXT_LENGTH 8192
set_env_var AUTO_TUNE false
check "a model tag is still written bare" \
  grep -qx 'MODEL_NAME=qwen2.5-coder:7b' "${SANDBOX}/.env"
check "a number is still written bare" \
  grep -qx 'OLLAMA_CONTEXT_LENGTH=8192' "${SANDBOX}/.env"
check "a boolean is still written bare" \
  grep -qx 'AUTO_TUNE=false' "${SANDBOX}/.env"
set_env_var BACKUP_SCHEDULE "*-*-* 03:30:00"

echo "# sync_env_keys() backfills settings an old install predates"
# .env is created from .env.example once and never updated, so an install made
# before a setting existed cannot see it. Simulate that by deleting keys.
cp "${SANDBOX}/.env" "${SANDBOX}/.env.before"
grep -vE '^(BACKUP_SCHEDULE|MODEL_FAMILY|LCA_ASK_TOKENS)=' "${SANDBOX}/.env.before" > "${SANDBOX}/.env"
sync_env_keys >/dev/null 2>&1
check "a missing key is added" grep -qE '^MODEL_FAMILY=' "${SANDBOX}/.env"
# BACKUP_SCHEDULE contains spaces, so this only works because set_env_var
# quotes such values — the bug fixed one commit earlier was not latent at all
# once anything appended that key.
check "a spaced key is added intact" \
  test "$(env_value BACKUP_SCHEDULE)" = "*-*-* 03:30:00"
check "and .env is still sourceable" test -n "$(env_value MODEL_NAME)"
# The user's own choices must survive untouched.
set_env_var MODEL_NAME "qwen2.5-coder:14b"
sync_env_keys >/dev/null 2>&1
check "an existing value is never overwritten" \
  test "$(env_value MODEL_NAME)" = "qwen2.5-coder:14b"
# Running setup twice must not keep appending.
sync_env_before="$(md5sum < "${SANDBOX}/.env")"
sync_env_keys >/dev/null 2>&1
check "re-running changes nothing (idempotent)" \
  test "$(md5sum < "${SANDBOX}/.env")" = "${sync_env_before}"
set_env_var MODEL_NAME "qwen2.5-coder:7b"

echo "# every setting must exist in BOTH lib.sh's defaults and .env.example"
# A key defaulted in lib.sh but absent from .env.example is a real setting no
# user can discover. A key in .env.example with no lib.sh default means
# deleting that line silently changes behaviour, with no fallback behind it.
lib_default_keys() {
  sed -n '/^load_env()/,/^}/p' "${REPO}/scripts/lib.sh" \
    | sed -nE 's/^[[:space:]]*([A-Z_]+)="\$\{[A-Z_]+:-.*/\1/p' | sort -u
}
example_keys() { grep -oE '^[A-Z_]+=' "${REPO}/.env.example" | tr -d '=' | sort -u; }
undocumented_settings() { [[ -z "$(comm -23 <(lib_default_keys) <(example_keys))" ]]; }
unbacked_settings() { [[ -z "$(comm -13 <(lib_default_keys) <(example_keys))" ]]; }
check "every lib.sh default is documented in .env.example" undocumented_settings
check "every .env.example key has a lib.sh default" unbacked_settings
# ...and the two must agree on the VALUE, not merely on the key. Both lists
# currently match, but nothing held them together, and a divergence is exactly
# the kind that never reproduces: the box behaves one way with a .env present
# and another without one, or an install predating a key behaves differently
# from a fresh one. The comment above says a missing fallback "silently changes
# behaviour" — a fallback that disagrees with the documented default is the
# same failure with an extra step.
example_value() {  # KEY — the value .env.example ships, unquoted, comment-free
  grep -oE "^$1=.*" "${REPO}/.env.example" | head -1 \
    | sed -E "s/^$1=//; s/[[:space:]]+#.*\$//; s/^\"//; s/\"\$//"
}
defaults_agree_on_values() {
  local key libval exval mismatch=0
  while IFS='=' read -r key libval; do
    [[ -n "${key}" ]] || continue
    # Key-only parity is the two checks above; here, only shared keys matter.
    grep -qE "^${key}=" "${REPO}/.env.example" || continue
    exval="$(example_value "${key}")"
    if [[ "${libval}" != "${exval}" ]]; then
      printf 'default disagrees for %s: lib.sh falls back to %q, .env.example ships %q\n' \
        "${key}" "${libval}" "${exval}" >&2
      mismatch=1
    fi
  done < <(sed -n '/^load_env()/,/^}/p' "${REPO}/scripts/lib.sh" \
             | sed -nE 's/^[[:space:]]*([A-Z_]+)="\$\{[A-Z_]+:-(.*)\}"$/\1=\2/p')
  return "${mismatch}"
}
check "lib.sh's fallback and .env.example agree on every value" \
  defaults_agree_on_values

echo "# warm_model() is best-effort and must never fail or block its caller"
# It runs at the end of the boot oneshot. If it can fail, a warm-up that could
# not reach Ollama turns into a failed boot unit; if it can block, the unit
# sits for minutes (a bounded 300s wait was measured timing out with the model
# still unloaded, which is why this is detached rather than merely patient).
warm_is_best_effort() {
  ( OLLAMA_HOST="127.0.0.1:59999"; MODEL_NAME="not-a-real-model:1b"
    warm_model >/dev/null 2>&1 )
}
check "warm_model succeeds when Ollama is unreachable" warm_is_best_effort
warm_returns_promptly() {
  local t0="${SECONDS}"
  ( OLLAMA_HOST="127.0.0.1:59999"; warm_model >/dev/null 2>&1 )
  (( SECONDS - t0 < 5 ))
}
check "warm_model returns promptly" warm_returns_promptly
# Structural: the request must stay backgrounded. Losing the '&' is the one
# edit that would silently reintroduce a multi-minute stall at boot, and no
# behavioural test catches it without a host that accepts and never answers.
# '[[:space:]]' not '\s' — awk has no \s, and the first version of this check
# silently failed against correct code. Caught by mutation-testing it.
warm_is_detached() {
  awk '/^warm_model\(\)/ {f=1}
       f && /curl .*api\/generate/ {c=1}
       f && c && /&[[:space:]]*\)/ {ok=1}
       f && /^}/ {exit !ok}' "${REPO}/scripts/lib.sh"
}
check "warm_model backgrounds the request" warm_is_detached

echo "# a deliberately skipped component must not be reported as a problem"
# Adding a skip flag without teaching the health check about it produces an
# unfixable warning on a healthy box — the exact trap the auto-tune ladder had,
# where 'lca check' told MODEL_FAMILY users to run a script that was already
# right. Every SKIP_* must have a branch in check-system.sh that says "skipped"
# rather than "missing".
# -F with the needle built in a variable: the literal text is
#   "${SKIP_X}" == "true"
# and getting the quoting wrong here produces a check that fails against
# correct code, which is how the first version of this went.
skip_is_understood() {
  local needle="\"\${$1}\" == \"true\""
  grep -qF "${needle}" "${REPO}/check-system.sh"
}
check "check-system.sh understands SKIP_TAILSCALE" skip_is_understood SKIP_TAILSCALE
check "check-system.sh understands SKIP_DOCKER" skip_is_understood SKIP_DOCKER
# And the installer itself must honour it, or setup would install it anyway.
honours_skip() {
  local needle="\"\${SKIP_TAILSCALE}\" == \"true\""
  grep -qF "${needle}" "${REPO}/scripts/install_tailscale.sh"
}
check "install_tailscale.sh honours SKIP_TAILSCALE" honours_skip

echo "# the README's headline model list must match what the ladder can select"
# It claimed "3b/7b/14b/32b, auto-selected". 32b is not reachable at ANY RAM
# tier — the ladder tops out at 14b by design, with larger sizes left as a
# manual 'lca model' choice. A promise in the first table someone reads is the
# worst place for that to be wrong.
readme_sizes_match_ladder() {
  local claimed actual
  claimed="$(grep -oE 'The model family \([^)]*\)' "${REPO}/README.md" \
    | grep -oE '[0-9]+(\.[0-9]+)?b' | sort -u | tr '\n' ' ')"
  actual="$(family_sizes qwen2.5-coder | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  [[ -n "${claimed}" && "${claimed}" == "${actual}" ]]
}
check "README's model sizes match family_sizes" readme_sizes_match_ladder

echo "# the RAM ladder must live in exactly one place"
# check-system.sh used to keep its own copy, hardcoded to qwen2.5-coder. It
# drifted the moment MODEL_FAMILY existed: a qwen3 user was told forever that
# their model differed from a qwen2.5-coder "recommendation", and to run the
# script that had just chosen it. Any second copy will rot the same way.
# Matched without a literal '${...}' in the pattern: that reads to ShellCheck
# as a variable someone forgot to expand (SC2016), and it is also less brittle
# about how the path to tune.sh happens to be written.
sources_the_real_ladder() { grep -qE '^[[:space:]]*source .*scripts/tune\.sh' "${REPO}/check-system.sh"; }
no_hardcoded_ladder() { ! grep -qE 'TUNE_MODEL="[a-z0-9.]+-?[a-z]*:' "${REPO}/check-system.sh"; }
check "check-system.sh sources tune.sh's ladder" sources_the_real_ladder
check "check-system.sh hardcodes no model in its ladder" no_hardcoded_ladder

echo "# ...and it must not carry a second copy of the disk numbers either"
# The free-disk check hardcoded /usr/share/ollama/.ollama/models — where the
# SYSTEMD service keeps models — and fell back to '/' when that was absent. On
# a host with no systemd, the case this project supports specially, the models
# are under ${HOME} and the report was about the wrong filesystem. Measured:
# 6.2 GB of models in /root/.ollama/models, and the line said '/'. On a box
# whose /home is a separate volume that is a different number, not a rounding
# difference.
#
# And it was a different number anyway. 'df -BG' rounds up, free_gb floors:
#
#   df -BG --output=avail /  ->  13
#   free_gb /                ->  12
#
# pull_model refuses a download on free_gb's answer, so at the threshold this
# check passed a machine — "free disk: 15 GB (>= 15 GB)" — that the very next
# pull would refuse. Exactly the drift model_disk_gb's comment exists to stop.
disk_check_uses_the_shared_helpers() {
  local body
  body="$(sed -n '/^# Free disk where Ollama keeps its models/,/^# --- Backups/p' \
          "${REPO}/check-system.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find check-system.sh's free-disk block — this gate stopped watching" >&2
    return 1; }
  grep -q 'ollama_models_dir' <<<"${body}" || {
    echo "check-system.sh guesses where the models live instead of asking ollama_models_dir — on a host without systemd that is the wrong filesystem" >&2
    return 1; }
  grep -q 'free_gb' <<<"${body}" || {
    echo 'check-system.sh measures free space itself instead of using free_gb, which is what pull_model enforces' >&2
    return 1; }
  # Comments stripped above, so this is the CODE running df, not the note
  # explaining why it no longer does.
  ! grep -qE '(^|[^[:alnum:]_])df( |$)' <<<"${body}" || {
    echo 'check-system.sh is back to its own df — a second estimate of a number pull_model already computes' >&2
    return 1; }
}
check "the free-disk check asks lib.sh rather than measuring it again" \
  disk_check_uses_the_shared_helpers
# ...and it must not present a directory that does not exist as the one the
# models are in. ollama_models_dir falls back to ${HOME}/.ollama/models, which
# for a NON-ROOT reporter is a path they will never be in: the server here runs
# as root, and /root is unreadable from another account, so nothing can see
# where they really are. Found by running 'lca check' as an ordinary user —
# which is what the docs tell people to do — with 6.2 GB of models sitting in
# /root/.ollama/models:
#
#   [FAIL] only 13 GB free at /home/ubuntu/.ollama/models
#
# The number is right; free_gb walks up to the filesystem and it is the same
# one. Naming a directory that is not there as "where the models are" is not.
# This arrived with the fix that replaced the hardcoded /usr/share/ollama path,
# so it is a regression of my own, caught by using the product rather than by
# reading it.
disk_check_names_a_directory_that_exists() {
  local body
  body="$(sed -n '/^# Free disk where Ollama keeps its models/,/^# --- Backups/p' \
          "${REPO}/check-system.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find check-system.sh's free-disk block — this gate stopped watching" >&2
    return 1; }
  # shellcheck disable=SC2016  # the pattern is source text, not an expansion
  grep -q 'd "${MODELS_DIR}"' <<<"${body}" || {
    echo 'check-system.sh names the models directory without checking it exists — on any account that is not the one running the server, that path is a guess' >&2
    return 1; }
  # ...and all three messages must use the checked description, not the raw
  # path. Two of three would have been the easy mistake.
  local n
  n="$(grep -c 'MODELS_WHERE' <<<"${body}")"
  (( n >= 4 )) || {
    printf 'only %s uses of the checked location — one of the three messages still names the raw path\n' "${n}" >&2
    return 1
  }
  ! grep -qE '(free disk at|GB free at|free disk space at) \$\{MODELS_DIR\}' <<<"${body}" || {
    echo 'a free-disk message still names MODELS_DIR directly' >&2
    return 1; }
}
check "...and never names a models directory that is not there" \
  disk_check_names_a_directory_that_exists
# ...and the two helpers it now leans on are asserted directly, because a
# health check is only as good as they are.
check "free_gb walks up to a directory that exists" \
  test -n "$(free_gb /no/such/path/at/all)"
check "...and answers for its nearest existing parent" \
  test "$(free_gb /no/such/path/at/all)" = "$(free_gb /)"
models_dir_with() {  # OLLAMA_MODELS HOME -> the directory chosen
  bash -c 'source "$1" >/dev/null 2>&1
    OLLAMA_MODELS="$2"; HOME="$3"
    ollama_models_dir' _ "${SANDBOX}/scripts/lib.sh" "$1" "$2"
}
check "an explicit OLLAMA_MODELS wins" \
  test "$(models_dir_with /somewhere/else /home/nobody)" = "/somewhere/else"
# The fallback when neither candidate exists: the invoking user's home, which
# is where start_ollama_bg's server puts them. Named even though it is absent,
# because free_gb walks up from there — that pairing is the whole fix.
check "...and without one it falls back to the invoking user's home" \
  test "$(models_dir_with "" /home/nobody)" = "/home/nobody/.ollama/models"

# Sourcing tune.sh recomputes SCRIPT_DIR from tune.sh's own location, silently
# repointing the caller's at scripts/. Both callers restore it; if that restore
# is ever dropped, the next line added below the source resolves against the
# wrong directory and fails in a way that looks nothing like its cause.
restores_script_dir() {
  awk '/source .*scripts\/tune\.sh/ {seen=1; next} seen && /SCRIPT_DIR=/ {ok=1} END {exit !ok}' "$1"
}
check "check-system.sh restores SCRIPT_DIR after sourcing tune.sh" \
  restores_script_dir "${REPO}/check-system.sh"
check "update-model.sh restores SCRIPT_DIR after sourcing tune.sh" \
  restores_script_dir "${REPO}/update-model.sh"

echo "# ...and a hand-picked model must be sized BEFORE the gigabytes cross the wire"
# choose_for_ram refuses to auto-pick something this machine cannot hold, and
# its own comment says why: "silently pulling ~10 GB and then OOMing on first
# use is the worst outcome". The MANUAL pin — the path where a person types a
# size by hand, so the likeliest place to overreach — had no such check.
# 'lca model qwen2.5-coder:32b' on a 16 GiB box downloaded ~20 GB over a VPS
# line and only then failed model_responds with "Does this machine have enough
# RAM for it?", a question the code could have answered before the first byte.
# pull_model already gives this guarantee for DISK ("Asked BEFORE the download,
# not after it"); this is the same one for RAM.
#
# model_fits_ram moved to lib.sh to make that possible without sourcing tune.sh
# from inside main() — which would redefine main() out from under its caller —
# so the numbers are asserted directly here for the first time.
too_big_for() { ! model_fits_ram "$1" "$2"; }
check "16 GiB holds 7b"                 model_fits_ram qwen2.5-coder:7b  16
check "16 GiB holds 14b"                model_fits_ram qwen2.5-coder:14b 16
check "16 GiB does NOT hold 32b"        too_big_for    qwen2.5-coder:32b 16
check "8 GiB does NOT hold 16b"         too_big_for    deepseek-coder-v2:16b 8
# An unusual naming scheme must never become a refusal — the rule the ladder
# has always had, and the reason this can warn on a guess without blocking.
check "a tag with no size is never refused"   model_fits_ram mymodel:latest 4
check "...nor is a bare name"                 model_fits_ram mymodel 4
# ...and the number a message quotes must be the number the guard used.
# update-model.sh recited the rule in prose — "roughly 0.6 GB per billion
# parameters, plus about 1 GB" — leaving the reader to do arithmetic the guard
# had already done, from a second copy free to drift from the first.
check "the sizing helper answers in GB"       test "$(model_ram_gb qwen2.5-coder:7b)"  = 5.2
check "...for a fractional size too"          test "$(model_ram_gb qwen2.5-coder:1.5b)" = 1.9
check "...and refuses a tag it cannot read"   test -z "$(model_ram_gb mymodel:latest 2>/dev/null)"
# The guard and the helper have to agree at the boundary in BOTH directions,
# or one of them is a separate rule wearing the other's name.
guard_agrees_with_the_number() {
  local m need bad=0
  for m in 1.5b 3b 7b 8b 13b 14b 16b 24b 32b 70b; do
    need="$(model_ram_gb "q:${m}")" || { printf 'no size read for %s\n' "${m}" >&2; bad=1; continue; }
    # Exactly enough must fit; a hair less must not.
    model_fits_ram "q:${m}" "${need}" || {
      printf '%s needs %s GB but is refused at exactly %s\n' "${m}" "${need}" "${need}" >&2; bad=1; }
    ! model_fits_ram "q:${m}" "$(awk -v n="${need}" 'BEGIN{ printf "%.10g", n - 0.1 }')" || {
      printf '%s needs %s GB but is accepted below it\n' "${m}" "${need}" >&2; bad=1; }
  done
  return "${bad}"
}
check "the guard and the number it quotes are one rule" guard_agrees_with_the_number
# ...and no script may carry the formula a third time, in prose.
no_script_recites_the_formula() {
  local bad=0 f body
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh; do
    [[ "${f}" == */lib.sh ]] && continue      # where the formula lives
    [[ "${f}" == */speed.sh ]] && continue    # reports memory traffic, not sizing
    body="$(sed 's/#.*//' "${f}")"
    grep -qE '0\.6 GB per billion' <<<"${body}" || continue
    printf '%s tells the user the formula instead of the answer\n' "${f##*/}" >&2
    bad=1
  done
  return "${bad}"
}
check "no script recites the sizing formula instead of applying it" \
  no_script_recites_the_formula

echo "# a fallback that changes nothing must not be announced as a fallback"
# choose_for_ram falls back to qwen2.5-coder when MODEL_FAMILY has no size that
# fits. qwen2.5-coder IS the fallback, so on a box too small for its smallest
# size the default family produced, measured with choose_for_ram 2:
#
#   [warn] MODEL_FAMILY=qwen2.5-coder has no size that fits 2 GiB
#          (smallest is 3b) — falling back to qwen2.5-coder.
#
# It announced a change to the thing it already was, and then selected 3b — the
# model the same line had just ruled out. The check exists to stop "silently
# pulling ~10 GB and then OOMing on first use", its own words; it detected that
# case and walked into it anyway.
ladder_warning() {  # FAMILY RAM -> what it said on stderr
  bash -c '
    source "$1" >/dev/null 2>&1
    source "$2" >/dev/null 2>&1
    MODEL_FAMILY="$3"
    choose_for_ram "$4" 2>&1 >/dev/null' _ "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "$1" "$2"
}
ladder_pick() {  # FAMILY RAM -> the model chosen
  bash -c '
    source "$1" >/dev/null 2>&1
    source "$2" >/dev/null 2>&1
    MODEL_FAMILY="$3"
    choose_for_ram "$4" 2>/dev/null
    printf "%s" "${TUNE_MODEL}"' _ "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "$1" "$2"
}
no_phantom_fallback() {
  local out
  out="$(ladder_warning qwen2.5-coder 2)"
  grep -q 'falling back to qwen2.5-coder' <<<"${out}" && {
    printf 'the default family is told it is falling back to itself: %s\n' "${out}" >&2
    return 1; }
  # ...and silence is not the fix either: nothing fits, and that is worth
  # saying, because the model it picks anyway is going to be killed.
  grep -qi 'nothing in this project' <<<"${out}" || {
    printf 'a box too small for every model is told nothing at all: %s\n' "${out}" >&2
    return 1; }
  grep -qF '2.8' <<<"${out}" || {
    printf 'the warning does not say how much the smallest model needs: %s\n' "${out}" >&2
    return 1; }
}
check "the default family is never told it is falling back to itself" \
  no_phantom_fallback
# The real fallback must still happen, and still be announced — this is the
# case the branch was written for.
real_fallback_still_happens() {
  local out
  out="$(ladder_warning deepseek-coder-v2 8)"
  grep -q 'falling back to qwen2.5-coder' <<<"${out}" || {
    printf 'a family that genuinely does not fit is not moved off: %s\n' "${out}" >&2
    return 1; }
  [[ "$(ladder_pick deepseek-coder-v2 8)" == qwen2.5-coder:* ]] || {
    printf 'the fallback was announced but not taken: %s\n' "$(ladder_pick deepseek-coder-v2 8)" >&2
    return 1; }
}
check "a family that really has no size that fits is still moved off" \
  real_fallback_still_happens
# ...and a fallback whose target does not fit either says BOTH things.
fallback_that_also_fails_says_so() {
  local out
  out="$(ladder_warning deepseek-coder-v2 2)"
  grep -q 'falling back to qwen2.5-coder' <<<"${out}" || {
    echo 'the fallback is not announced' >&2; return 1; }
  grep -qi 'nothing in this project' <<<"${out}" || {
    printf 'the fallback lands somewhere that does not fit either, silently: %s\n' "${out}" >&2
    return 1; }
}
check "...and a fallback that lands somewhere too small says that too" \
  fallback_that_also_fails_says_so
pin_is_sized_before_the_pull() {
  local body line n=0 n_fit=0 n_pull=0
  # Scoped to main(): list_recommended calls model_fits_ram too, and a
  # whole-file grep is satisfied by that call alone with the pin left blind.
  body="$(sed -n '/^main() {/,/^}/p' "${REPO}/update-model.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find update-model.sh main() — this gate stopped watching" >&2
    return 1; }
  # Read line by line rather than 'grep -n | head -1': a reader that exits
  # early takes its writer with it under pipefail, which is the trap this
  # suite bans outright further down.
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "${line}" == *model_fits_ram* && ${n_fit}  -eq 0 ]]; then n_fit="${n}";  fi
    if [[ "${line}" == *pull_model*     && ${n_pull} -eq 0 ]]; then n_pull="${n}"; fi
  done <<<"${body}"
  (( n_pull > 0 )) || {
    echo 'update-model.sh no longer pulls in main() — this gate stopped watching' >&2
    return 1; }
  (( n_fit > 0 )) || {
    echo "'lca model' pulls without ever asking whether the model fits this machine's RAM" >&2
    return 1; }
  (( n_fit < n_pull )) || {
    echo "'lca model' sizes the model only AFTER downloading it — the gigabytes are already spent by then" >&2
    return 1; }
}
check "'lca model' checks the RAM before it starts the download" \
  pin_is_sized_before_the_pull
# ...and reclaiming disk afterwards must not be able to swallow the advice.
# 'ollama rm' ran bare under set -e, so a failure ended the script THERE —
# after MODEL_NAME and AUTO_TUNE were both written, and before the lines that
# say the chat app is still on the old model and needs 'lca apply'. The one
# instruction the command exists to give, lost on the run where the user asked
# for the most to happen.
remove_old_failure_is_reported() {
  local body
  body="$(sed -n '/remove_old}" == "true"/,/^  fi$/p' "${REPO}/update-model.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find update-model.sh's --remove-old block — this gate stopped watching" >&2
    return 1; }
  grep -qE '(if|elif) +ollama rm ' <<<"${body}" || {
    echo "update-model.sh runs 'ollama rm' bare — a failure ends the script before it says the chat app still needs 'lca apply'" >&2
    return 1; }
  grep -qi 'could not remove' <<<"${body}" || {
    echo "update-model.sh tests the removal but says nothing when it fails" >&2
    return 1; }
}
check "...and a removal that fails is reported instead of ending the run" \
  remove_old_failure_is_reported

echo "# 'lca help' must not advertise a command bin/lca cannot run"
# The same class of bug as the system-prompt check above, one layer out: help
# text drifts when a command is renamed, and a user following it gets "Unknown
# command". Aliases dispatched but deliberately left out of help (selftest,
# agent, code) are fine — this only checks help -> dispatch, not the reverse.
help_commands_all_real() {
  local sub bad=0
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    grep -qE "^[[:space:]]*[a-z|\"-]*\b${sub}\b[a-z|\"-]*\)" "${REPO}/bin/lca" || {
      printf 'lca help advertises a command bin/lca does not dispatch: %s\n' "${sub}" >&2
      bad=1
    }
  done < <("${REPO}/bin/lca" help 2>/dev/null | sed -n 's/^  lca \([a-z]\{1,\}\).*/\1/p' | sort -u)
  return "${bad}"
}
check "every command in 'lca help' is dispatched by bin/lca" help_commands_all_real
# ...and the other direction, which was never checked. A command you can run
# but cannot find is a feature nobody uses: 'lca harden' — re-apply the inbound
# guard that keeps ports 3000 and 11434 off the public internet — was
# dispatched and completely absent from the help, so the only way to learn it
# existed was to read bin/lca.
#
# Aliases and internal spellings are excluded by name, not by pattern, so
# adding one is a deliberate act rather than something a loose regex forgives.
dispatched_commands_are_all_documented() {
  local sub undocumented=0 helptext
  helptext="$("${REPO}/bin/lca" help 2>/dev/null)"
  while read -r sub; do
    [[ -n "${sub}" ]] || continue
    case "${sub}" in
      # 'selftest' is an alias for 'test'; 'online' is documented on the
      # 'lca offline|online' line, which the extractor below cannot see.
      selftest|online) continue ;;
    esac
    grep -qE "^  lca ${sub}\b" <<<"${helptext}" || {
      printf "bin/lca dispatches '%s' but 'lca help' never mentions it\\n" "${sub}" >&2
      undocumented=1
    }
  done < <(grep -oE '^  [a-z|]+\)' "${REPO}/bin/lca" | tr -d ' )' | tr '|' '\n' | sort -u)
  return "${undocumented}"
}
check "every command bin/lca dispatches appears in 'lca help'" \
  dispatched_commands_are_all_documented

echo "# the README's command table must not omit a command 'lca help' offers"
# The table is what someone scans to learn the tool, and it had drifted: five
# commands were missing, including 'lca backup' and 'lca restore' — the entire
# safety net was invisible to anyone reading the README. Same class as the
# 'lca help' -> dispatch check above, one layer further out.
# 'help' is excluded: a help command that documents itself in the table it
# prints is noise, not a contract.
readme_documents_every_command() {
  local sub bad=0 documented
  documented="$(sed -n '/^| Command | Does |/,/^$/p' "${REPO}/README.md" \
                 | grep -oE '`lca [a-z]+' | sed 's/^`lca //' | sort -u)"
  while read -r sub; do
    [[ -n "${sub}" && "${sub}" != "help" ]] || continue
    grep -qx -- "${sub}" <<<"${documented}" || {
      printf "'lca %s' is in 'lca help' but missing from the README table\\n" "${sub}" >&2
      bad=1
    }
  done < <("${REPO}/bin/lca" help 2>/dev/null | sed -n 's/^  lca \([a-z]\{1,\}\).*/\1/p' | sort -u)
  # A table that matched nothing would "pass" without checking anything.
  [[ -n "${documented}" ]] || { echo "no command table found in README.md" >&2; return 1; }
  return "${bad}"
}
check "the README table documents every 'lca help' command" \
  readme_documents_every_command

echo "# the README's settings table must match .env.example, both ways and with defaults"
# Same class as the command table above. This one caught its own author:
# SKIP_TAILSCALE was added to .env.example and lib.sh in an earlier change
# tonight and never reached the README's settings table, so the only way to
# discover it was to read .env.example — which is precisely what the table
# exists to save people from.
readme_documents_every_setting() {
  local key bad=0 documented shipped want got
  # The backtick is built rather than written literally: a matched PAIR inside
  # single quotes reads to ShellCheck as a command substitution (SC2016).
  local bt; bt="$(printf '\140')"
  # Scoped to the '.env reference' section, not the whole file. The AUTO-TUNE
  # section has its own table whose first column is also a backticked KEY —
  # 'MODEL_FAMILY | small / mid / big' — so a whole-file read pairs a real
  # setting with a default it never had. Harmless while only key NAMES were
  # compared; not once the DEFAULT is read out of the row.
  local section
  section="$(sed -n "/^## ${bt}[.]env${bt} reference/,/^## Repository/p" "${REPO}/README.md")"
  [[ -n "${section}" ]] || { echo "no '.env reference' section found in README.md" >&2; return 1; }
  documented="$(grep -oE "^\| ${bt}[A-Z_]+${bt}" <<<"${section}" | tr -d "|${bt} " | sort -u)"
  [[ -n "${documented}" ]] || { echo "no settings table found in README.md" >&2; return 1; }
  shipped="$(grep -oE '^[A-Z_]+=' "${REPO}/.env.example" | tr -d '=' | sort -u)"
  [[ -n "${shipped}" ]] || { echo "no settings found in .env.example" >&2; return 1; }
  while read -r key; do
    [[ -n "${key}" ]] || continue
    grep -qx -- "${key}" <<<"${documented}" || {
      printf '%s is in .env.example but missing from the README settings table\n' "${key}" >&2
      bad=1
    }
  done <<<"${shipped}"
  # The other direction, which nothing checked. A row for a key that no longer
  # exists is worse than a missing one: someone sets it, nothing happens, and
  # the file that told them to do it is the project's own front page.
  while read -r key; do
    [[ -n "${key}" ]] || continue
    grep -qx -- "${key}" <<<"${shipped}" || {
      printf '%s is in the README settings table but not in .env.example\n' "${key}" >&2
      bad=1
    }
  done <<<"${documented}"
  # ...and the DEFAULT each row states is a promise about behaviour, checked
  # here against the value the file actually ships.
  while IFS=$'\t' read -r key want; do
    [[ -n "${key}" ]] || continue
    want="${want#"${bt}"}"; want="${want%"${bt}"}"
    [[ "${want}" == '*(empty)*' ]] && want=""
    got="$(grep -E "^${key}=" "${REPO}/.env.example" | head -1 | cut -d= -f2-)"
    [[ "${want}" == "${got}" ]] || {
      printf 'README says %s defaults to [%s]; .env.example ships [%s]\n' \
        "${key}" "${want}" "${got}" >&2
      bad=1
    }
  done < <(grep -E "^\| ${bt}[A-Z_]+${bt}" <<<"${section}" \
    | sed -E "s/^\| ${bt}([A-Z_]+)${bt} \| ([^|]*)\|.*/\1\t\2/" \
    | sed 's/[[:space:]]*$//')
  return "${bad}"
}
check "the README settings table matches .env.example, defaults included" \
  readme_documents_every_setting

echo "# starter questions for the phone chat match Open WebUI's expected shape"
SUGGESTIONS="${REPO}/config/prompt-suggestions.json"
check "prompt-suggestions.json exists" test -r "${SUGGESTIONS}"
# Wrapper so jq's own stdout is discarded without redirecting check()'s "ok"
# line into /dev/null along with it.
json_ok() { jq -e "$1" "$2" >/dev/null 2>&1; }
not_stock() { ! grep -qi "roman empire\|kids' art" "${SUGGESTIONS}"; }
if have jq; then
  check "prompt-suggestions.json is valid JSON" json_ok . "${SUGGESTIONS}"
  # Open WebUI reads a list of {title: [line1, line2], content: str}. A wrong
  # shape still parses as JSON and then renders as an empty start screen, so
  # validating the shape is the only thing that actually catches it.
  check "every suggestion has a 2-line title and content" json_ok \
    'type == "array" and length > 0 and all(
       (.title | type == "array" and length == 2 and all(type == "string"))
       and (.content | type == "string" and length > 0))' "${SUGGESTIONS}"
  check "suggestions are not Open WebUI's stock ones" not_stock
  # PHONE.md tells the reader how many starter questions they will see. It said
  # "four" for as long as there were five, because nothing tied the sentence to
  # the file — and that page is the one a phone user actually reads.
  #
  # Matched on the NUMBER before the phrase, not on the sentence around it, so
  # rewording the paragraph is free and changing the count is not.
  doc_count_matches_suggestions() {
    local n claimed
    local words=(zero one two three four five six seven eight nine ten)
    n="$(jq 'length' "${SUGGESTIONS}")"
    claimed="$(grep -oiE '(one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+) starter question' \
                 "${REPO}/docs/PHONE.md" | head -1 | awk '{print tolower($1)}')"
    [[ -n "${claimed}" ]] || {
      echo "PHONE.md never says how many starter questions there are" >&2; return 1
    }
    # Written as a full if, not '(( ... )) && want=...'. Measured afterwards,
    # because the first version of this comment described the mechanism wrongly:
    # a false left side does NOT abort under 'set -e' — bash exempts every
    # command in an && list except the last. What it does is make the LIST
    # return 1, which matters only when the list is a function's final
    # statement, where it silently becomes the function's exit status. Here it
    # is not final, so the 'if' is defensive rather than required — but a later
    # edit that moves it to the end would turn a passing check into a failing
    # one with nothing to see.
    local want="${n}"
    if (( n <= 10 )); then want="${words[n]}"; fi
    [[ "${claimed}" == "${want}" || "${claimed}" == "${n}" ]] || {
      printf 'PHONE.md claims %s starter questions; the file has %s\n' \
        "${claimed}" "${n}" >&2
      return 1
    }
  }
  check "PHONE.md's starter-question count matches the file" \
    doc_count_matches_suggestions
fi

echo "# starting Ollama must not look like a hung terminal"
# 'lca speed' with Ollama down printed nothing at all for up to 60 seconds:
# ensure_ollama_up was called with every word suppressed. That is the least
# helpful possible response from the command people run when the box already
# feels slow, and 'lca ask' — the most-used command — did the same.
announces_slow_start() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    wait_for_ollama()   { return 1; }   # never comes up
    ensure_ollama_up()  { return 1; }
    ensure_ollama_up_announced 7 2>&1 >/dev/null
  ' _ "${REPO}/scripts/lib.sh")"
  grep -q 'starting it' <<<"${out}" || {
    printf 'no notice while starting Ollama: %s\n' "${out}" >&2; return 1
  }
}
check "a slow Ollama start is announced" announces_slow_start
# ...on stderr, because in 'lca ask' stdout is the model's answer and a
# progress line must not end up inside a piped or redirected one.
announcement_avoids_stdout() {
  local on_stdout
  on_stdout="$(bash -c '
    set -uo pipefail
    source "$1"
    wait_for_ollama()  { return 1; }
    ensure_ollama_up() { return 1; }
    ensure_ollama_up_announced 7 2>/dev/null
  ' _ "${REPO}/scripts/lib.sh")"
  [[ -z "${on_stdout}" ]] || {
    printf 'progress notice leaked onto stdout: %s\n' "${on_stdout}" >&2; return 1
  }
}
check "the notice goes to stderr, keeping stdout clean" announcement_avoids_stdout
# Nothing at all when Ollama is already up — the normal case must stay silent.
silent_when_already_up() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    wait_for_ollama() { return 0; }
    ensure_ollama_up_announced 7 2>&1
  ' _ "${REPO}/scripts/lib.sh")"
  [[ -z "${out}" ]] || {
    printf 'a healthy Ollama produced noise: %s\n' "${out}" >&2; return 1
  }
}
check "a healthy Ollama produces no notice" silent_when_already_up
# And the two commands that had the bug must use the announced form.
uses_announced_start() { grep -qF 'ensure_ollama_up_announced' "${REPO}/$1"; }
check "ask.sh announces a slow Ollama start"   uses_announced_start scripts/ask.sh
check "speed.sh announces a slow Ollama start" uses_announced_start scripts/speed.sh
# restore.sh waited 30 silent seconds at the very end of a recovery, and
# 'lca model --list' let ollama's own client error through — which says to run
# "ollama serve", the wrong instruction on a systemd box where the server is a
# managed service.
check "restore.sh announces a slow Ollama start"      uses_announced_start restore.sh
check "update-model.sh announces a slow Ollama start" uses_announced_start update-model.sh
# Nothing may go back to the silent form: that spelling is the bug.
no_silent_ollama_start() {
  local hits
  hits="$(grep -rln 'ensure_ollama_up [0-9]* >/dev/null' "${REPO}/scripts" "${REPO}" \
            --include='*.sh' 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these still start Ollama with all output suppressed:\n%s\n' "${hits}" >&2; return 1
  }
}
check "nothing starts Ollama with its output suppressed" no_silent_ollama_start
check "run-agent.sh announces a slow Ollama start" uses_announced_start run-agent.sh
# The suppressed-output spelling was only half of it. A long bare
# 'wait_for_ollama N' is the other half, and worse: it POLLS without starting
# anything. On a host with no systemd (or no sudo), 'lca' — the headline
# command — sat silent for 60 seconds waiting for a server nothing was
# starting, then advised 'systemctl restart' on a box that has no systemd.
#
# The rule is not "never wait". install_ollama.sh, restart_ollama and
# start_ollama_bg all wait a long time and are right to: each has just started
# the thing it waits for, and said so. So a long wait is allowed when the few
# lines above it either START the server or SAY something. Encoding that rather
# than a blanket ban is what stops this being suppressed the first time it is
# inconvenient.
no_unannounced_long_wait() {
  local hits
  hits="$(awk -f "${TESTS_DIR}/long-wait.awk" "$@")"
  [[ -z "${hits}" ]] || {
    printf 'these wait a long time for an Ollama nobody started, in silence:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no long wait for an Ollama nobody started or announced" \
  no_unannounced_long_wait "${REPO}"/*.sh "${REPO}"/scripts/*.sh

echo "# a model pull must survive a transient registry failure"
# CI hit the real thing: the registry answered 503 at 396 MB of a 397 MB
# download, and the whole pull was thrown away. On a droplet that is gigabytes
# and it aborts the first-boot install. Retrying is safe because 'ollama pull'
# resumes from the blobs already in the local store.
# Driven with a stub 'ollama' so the retry loop is exercised for real, without
# a network: sleep is stubbed too, or the test would wait 15 seconds.
pull_retries_then_succeeds() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); [[ "${ATTEMPTS}" -ge 3 ]]; }
    sleep() { :; }
    pull_model fake-model:1b >/dev/null 2>&1
    printf "rc=%s attempts=%s\n" "$?" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh")"
  [[ "${out}" == "rc=0 attempts=3" ]] || {
    printf 'expected a successful third attempt, got: %s\n' "${out}" >&2; return 1
  }
}
check "a pull that fails twice then succeeds is a success" pull_retries_then_succeeds
pull_gives_up_after_three() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 1; }
    sleep() { :; }
    pull_model fake-model:1b >/dev/null 2>&1
    printf "rc=%s attempts=%s\n" "$?" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh")"
  # Bounded: a genuinely unavailable model must still fail, and not loop.
  [[ "${out}" == "rc=1 attempts=3" ]] || {
    printf 'expected failure after exactly 3 attempts, got: %s\n' "${out}" >&2; return 1
  }
}
check "a pull that never succeeds fails after exactly 3 attempts" pull_gives_up_after_three

echo "# a pull must not spend gigabytes finding out there was no room for them"
# Every other disk message in this project is a post-mortem — "disk full? check
# df -h" — which on a model pull means learning it after several GB have
# crossed the wire. On a VPS whose disk is fixed and whose model is the biggest
# thing on it, that is the difference between a refusal and a broken box: the
# .env writes, the drop-in, the backups and the WebUI volume all share that
# filesystem, and this is what fills it.
check "0.5b rounds up to 1 GB"  test "$(model_disk_gb qwen2.5-coder:0.5b)" = "1"
check "3b needs about 2 GB"     test "$(model_disk_gb qwen2.5-coder:3b)"   = "2"
check "7b needs about 5 GB"     test "$(model_disk_gb qwen2.5-coder:7b)"   = "5"
check "14b needs about 9 GB"    test "$(model_disk_gb qwen2.5-coder:14b)"  = "9"
# An unknown size must stay unknown. Turning "I cannot tell" into a number is
# how a guess becomes a refusal of a model that would have fitted.
unsized_tag_is_unknown() { ! model_disk_gb weird-model 2>/dev/null; }
check "a tag with no parameter count has no estimate" unsized_tag_is_unknown
# free_gb answers about a real filesystem, and about the nearest existing
# parent when the models directory has not been created yet.
free_gb_is_a_number()      { [[ "$(free_gb /)" =~ ^[0-9]+$ ]]; }
free_gb_walks_up()         { [[ "$(free_gb /nonexistent-xyz/models)" =~ ^[0-9]+$ ]]; }
check "free_gb reports whole GB for a path"        free_gb_is_a_number
check "...and for one that does not exist yet"     free_gb_walks_up
# ...and free_gb has to be pointed at the RIGHT filesystem, which is
# ollama_models_dir's whole job. `make coverage` found this one: three branches
# and no test touched any of them.
#
# It is not cosmetic. Someone who moved their models onto a second, bigger disk
# with OLLAMA_MODELS has a pre-flight check that would measure / instead, find
# it full, and refuse a pull that had room — the exact opposite of the failure
# the check was added to prevent.
models_dir_for() {  # OLLAMA_MODELS HOME -> the answer
  bash -c 'source "$1" >/dev/null 2>&1
           if [[ -n "$2" ]]; then export OLLAMA_MODELS="$2"; else unset OLLAMA_MODELS; fi
           HOME="$3"; ollama_models_dir' _ "${REPO}/scripts/lib.sh" "$1" "$2"
}
ollama_models_dir_answers_correctly() {
  local home="${SANDBOX}/mdir" service=/usr/share/ollama/.ollama/models got want
  rm -rf "${home}"; mkdir -p "${home}/.ollama/models"
  # 1. An explicit OLLAMA_MODELS wins over any directory that happens to exist.
  got="$(models_dir_for /mnt/big-disk/models "${home}")"
  [[ "${got}" == "/mnt/big-disk/models" ]] || {
    printf 'OLLAMA_MODELS ignored: wanted /mnt/big-disk/models, got %s\n' "${got}" >&2
    return 1; }
  # 2. Unset: the service account's store if it exists, else this user's. The
  #    expectation is computed from the same fact the code tests, so this is
  #    deterministic on a box with or without the service directory — the
  #    environment-dependence trap that bit the guarded_ports tests.
  want="${home}/.ollama/models"
  [[ -d "${service}" ]] && want="${service}"
  got="$(models_dir_for "" "${home}")"
  [[ "${got}" == "${want}" ]] || {
    printf 'unset OLLAMA_MODELS: wanted %s, got %s\n' "${want}" "${got}" >&2
    return 1; }
  # 3. Nothing exists anywhere: still an answer, not an empty string. It only
  #    feeds a warning, and free_gb walks up to the nearest real parent.
  want="${SANDBOX}/nowhere/.ollama/models"
  [[ -d "${service}" ]] && want="${service}"
  got="$(models_dir_for "" "${SANDBOX}/nowhere")"
  [[ "${got}" == "${want}" ]] || {
    printf 'with no store anywhere: wanted %s, got %s\n' "${want}" "${got}" >&2
    return 1; }
}
check "ollama_models_dir prefers OLLAMA_MODELS, then the real store" \
  ollama_models_dir_answers_correctly
# The ORDER of the two candidates matters and cannot be asserted on a box that
# has only one of them: Ollama runs as its own service account, so on a machine
# with both stores the service one is the filesystem that fills up.
#
# No pipe anywhere in here, deliberately. Written first as
# 'sed lib.sh | awk ... exit', which passed on this machine and FAILED in CI:
# awk stops reading at the line it wants, sed keeps writing into a closed pipe,
# takes SIGPIPE, and under 'set -o pipefail' the pipeline reports failure. It
# is a race against the 64 KiB pipe buffer, so it depends on how much of the
# file is left — lib.sh is the biggest file here and the match is halfway up,
# which is why this one lost and the identical checks against motd.sh do not.
# The same trap lib.sh's own current_run_log() carries a comment about.
service_store_is_checked_first() {
  local body l line="" svc_at home_at
  # A range match reads the whole file; nothing exits early.
  body="$(sed -n '/^ollama_models_dir() {/,/^}/p' "${REPO}/scripts/lib.sh")"
  while IFS= read -r l; do
    [[ "${l}" == *"for d in"* ]] && { line="${l}"; break; }
  done <<<"${body}"
  [[ -n "${line}" ]] || {
    echo 'ollama_models_dir no longer loops over candidate stores' >&2; return 1; }
  [[ "${line}" == */usr/share/ollama* && "${line}" == *HOME* ]] || {
    echo 'the candidate list no longer names both the service store and the user one' >&2
    return 1; }
  # Prefix lengths, so the comparison is positional without invoking anything.
  svc_at="${line%%/usr/share/ollama*}"
  home_at="${line%%HOME*}"
  (( ${#svc_at} < ${#home_at} )) || {
    echo "the user's store is checked before the service account's" >&2
    return 1; }
}
check "...and looks at the service account's store before the user's" \
  service_store_is_checked_first
pull_with_space() {   # FREE_GB -> "rc=N attempts=N" plus the message
  bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    # Captured OUT of the positional parameters first: inside a function, $2 is
    # that FUNCTION second argument, and free_gb is called with one. The stub
    # read empty and the assertions failed for a reason unrelated to the code.
    FREE="$2"
    free_gb() { printf "%s\n" "${FREE}"; }
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 0; }
    sleep() { :; }
    pull_model qwen2.5-coder:14b 2>&1
    printf "rc=%s attempts=%s\n" "$?" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh" "$1" 2>&1
}
NO_ROOM="$(pull_with_space 3)"
check "a pull with no room downloads nothing at all" \
  grep -q 'attempts=0' <<<"${NO_ROOM}"
check "...and names what it needs and what there is" \
  grep -qE 'about 9 GB and only 3 GB is free' <<<"${NO_ROOM}"
check "...and says how to make room" \
  grep -q 'ollama rm' <<<"${NO_ROOM}"
check "room enough still pulls" \
  grep -q 'attempts=1' <<<"$(pull_with_space 40)"
# A tag whose size cannot be estimated must still be pullable.
check "an unsized tag is pulled, not refused" \
  grep -q 'attempts=1' <<<"$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    free_gb() { printf "1\n"; }
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 0; }
    pull_model weird-model >/dev/null 2>&1
    printf "attempts=%s\n" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh")"
# Running out DURING the download must not be retried: the next attempt
# re-downloads everything, twice, on a disk that just proved too small.
pull_that_fills_the_disk() {
  bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0
    # Room to start, none once the first attempt has run.
    free_gb() { if (( ATTEMPTS == 0 )); then printf "40\n"; else printf "2\n"; fi; }
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 1; }
    sleep() { :; }
    pull_model qwen2.5-coder:14b 2>&1
    printf "attempts=%s\n" "${ATTEMPTS}"
  ' _ "${REPO}/scripts/lib.sh" 2>&1
}
FILLED="$(pull_that_fills_the_disk)"
check "a pull that fills the disk is not retried" grep -q 'attempts=1' <<<"${FILLED}"
check "...and says why it stopped" grep -q 'ran .* out of space' <<<"${FILLED}"
pull_succeeds_first_time_without_retrying() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"
    ATTEMPTS=0; SLEPT=0
    ollama() { ATTEMPTS=$((ATTEMPTS+1)); return 0; }
    # Counted, not printed: an echo here lands on stdout, and the first version
    # of this test discarded stdout — so it silently only checked the retry.
    sleep() { SLEPT=$((SLEPT+1)); }
    pull_model fake-model:1b >/dev/null 2>&1
    printf "attempts=%s slept=%s\n" "${ATTEMPTS}" "${SLEPT}"
  ' _ "${REPO}/scripts/lib.sh")"
  # The happy path must not sleep or re-pull — it runs on every setup.
  [[ "${out}" == "attempts=1 slept=0" ]] || {
    printf 'a first-time success did extra work: %s\n' "${out}" >&2; return 1
  }
}
check "a pull that works first time does not retry or sleep" \
  pull_succeeds_first_time_without_retrying

echo "# OnCalendar comparison must survive systemd's shorthands"
# The backup timer keeps the schedule it was installed with, so BACKUP_SCHEDULE
# edited in .env and never applied leaves backups on the old cadence. Detecting
# that by comparing raw strings would report drift on a healthy box the moment
# someone wrote "daily" instead of "*-*-* 00:00:00" — an unfixable warning,
# which is worse than no warning.
if have systemd-analyze; then
  same_schedule() {
    local a b
    a="$(normalized_calendar "$1")" || return 1
    b="$(normalized_calendar "$2")" || return 1
    [[ "${a}" == "${b}" ]]
  }
  differing_schedule() { ! same_schedule "$1" "$2"; }
  check "'daily' equals '*-*-* 00:00:00' (no false drift)" \
    same_schedule daily '*-*-* 00:00:00'
  check "'weekly' differs from 'daily' (real drift is seen)" \
    differing_schedule weekly daily
  check "the .env default normalises to itself" \
    same_schedule '*-*-* 03:30:00' '*-*-* 03:30:00'
  # An unparseable spec must yield nothing, so the caller stays silent rather
  # than reporting drift between a real schedule and a parse failure.
  rejects_nonsense() { ! normalized_calendar 'not-a-schedule' >/dev/null 2>&1; }
  check "an invalid OnCalendar spec is refused, not guessed" rejects_nonsense
  # check-system.sh must actually use it.
  check_compares_schedule() { grep -qF 'normalized_calendar' "${REPO}/check-system.sh"; }
  check "check-system.sh compares the timer's schedule with .env" check_compares_schedule
fi

echo "# a manual pin must still apply .env to the running service"
# AUTO_TUNE=false means "do not re-pick the model from RAM". It used to mean
# "ignore .env entirely": tune.sh returned before its drift check, so editing
# OLLAMA_KEEP_ALIVE or OLLAMA_CONTEXT_LENGTH did nothing, on every boot, with
# nothing said. 'lca model' sets AUTO_TUNE=false for you, so that was the state
# of anyone who had pinned a model — and .env.example openly invites editing
# OLLAMA_KEEP_ALIVE ("set this to -1 to keep the model resident").
# Reproduced with real files before it was fixed: .env said -1, the drop-in
# said 30m, and tune.sh printed "Nothing to do".
# Anchored on the block that ends in "keeping your manual pin", because
# tune.sh's --dry-run section tests AUTO_TUNE the same way earlier in the file
# and the first version of this matched that one instead — failing against
# correct code. The window resets at each occurrence so only the real branch
# can satisfy it. No literal '${...}' in the pattern: ShellCheck reads that
# inside single quotes as an unexpanded variable (SC2016).
autotune_false_still_converges() {
  awk '/AUTO_TUNE/ && /!= "true"/ {inblk=1; sawresync=0; next}
       inblk && /resync_dropin_if_drifted/ {sawresync=1}
       inblk && /keeping your manual pin/ {if (sawresync) ok=1; inblk=0}
       END {exit !ok}' "${REPO}/scripts/tune.sh"
}
check "tune.sh converges the drop-in even when AUTO_TUNE=false" \
  autotune_false_still_converges
# One convergence RULE shared by both paths. (Not "one call to
# render_ollama_dropin" — the ordinary re-tune path renders too, and asserting
# that was the second way this test failed against correct code.)
resync_rule_is_shared() {
  local defs calls
  defs="$(grep -rc '^resync_dropin_if_drifted() {' "${REPO}/scripts/lib.sh" || true)"
  calls="$(grep -c 'resync_dropin_if_drifted' "${REPO}/scripts/tune.sh" || true)"
  [[ "${defs}" == "1" ]] || { printf 'convergence rule defined %s times in lib.sh\n' "${defs}" >&2; return 1; }
  (( calls >= 2 )) || { printf 'convergence rule called from only %s place(s)\n' "${calls}" >&2; return 1; }
}
check "the drift rule is defined once and used by both paths" resync_rule_is_shared

# Nowhere may re-implement the drift DECISION. A second copy is how the pinned
# path was forgotten, and how 'lca apply' would drift from what tune.sh does on
# boot. "Has it drifted?" is one question with one answer — ollama_dropin_matches,
# which diffs the installed file against render_ollama_dropin_content — and both
# halves live in lib.sh. Everyone else asks; nobody reads the file themselves.
#
# This replaces two lines that could not enforce it. The first required apply.sh
# to CONTAIN render_ollama_dropin, which is the opposite of "may not
# re-implement"; the second was then reachable only when that was already true,
# so it could never fail. A whole-file grep for a name the file was required to
# have is not a test of anything.
drift_decision_is_shared() {
  local f stripped
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh; do
    [[ "${f}" == "${REPO}/scripts/lib.sh" ]] && continue
    # Comments stripped first: three scanners in this file have been satisfied
    # by their own explanatory prose, and this one names every symbol it bans.
    stripped="$(sed 's/#.*//' "${f}")"
    if grep -q 'render_ollama_dropin_content' <<<"${stripped}"; then
      printf '%s renders the expected drop-in itself\n' "${f##*/}" >&2
      return 1
    fi
    # Naming the path is fine — check-system.sh tells the user where the file
    # is. Reading its CONTENTS is the drift decision, hand-rolled.
    if grep -qE '\b(grep|sed|awk|diff|cmp|cat|head|tail)\b.*OLLAMA_DROPIN' <<<"${stripped}"; then
      printf '%s reads the drop-in itself instead of asking ollama_dropin_matches\n' "${f##*/}" >&2
      return 1
    fi
  done
  # Both halves defined exactly once, and only in lib.sh.
  local n
  for f in ollama_dropin_matches render_ollama_dropin_content; do
    n="$(grep -c "^${f}() {" "${REPO}/scripts/lib.sh" || true)"
    [[ "${n}" == "1" ]] || { printf '%s defined %s times in lib.sh\n' "${f}" "${n}" >&2; return 1; }
  done
  return 0
}
check "nothing outside lib.sh re-implements the drop-in drift decision" \
  drift_decision_is_shared

# 'lca apply' must ASK before it writes. Rendering the drop-in unconditionally
# restarts Ollama — unloading the model, so the next question pays the load
# again — on every run of a command whose whole promise is "applies whatever has
# fallen behind and nothing that has not".
apply_asks_before_rendering() {
  # The render is no longer a bare '  render_ollama_dropin' line — it moved
  # inside 'if ! ( render_ollama_dropin && restart_ollama )' so a die() in
  # either cannot end the whole apply. The PROPERTY is unchanged and still
  # asserted: the drift question comes first. Only the anchor moved with it.
  #
  # Comments skipped, because the note explaining that change names the
  # function four times and awk reads the raw file — the whole-file-grep trap
  # this suite keeps re-learning, arriving from the other direction.
  awk '/^apply_ollama\(\) \{/          { inb = 1 }
       inb && /^[[:space:]]*#/         { next }
       inb && /ollama_dropin_matches/  { asked = NR }
       inb && /render_ollama_dropin/   { if (!wrote) wrote = NR }
       inb && /^\}/                    { exit }
       END { exit !(asked > 0 && wrote > asked) }' "${REPO}/scripts/apply.sh"
}
check "apply.sh checks for drift before re-rendering the drop-in" \
  apply_asks_before_rendering

echo "# 'lca apply' — one command for every setting that needs applying"
# Three separate silent failures came from .env settings that are baked into
# something long-lived. 'lca check' names a different fix command for each;
# this is the one command that does whatever is needed. It must be honest
# about a component that is absent (not "already matches"), and a dry run must
# change nothing — verified against real files, not just asserted here.
APPLY="${REPO}/scripts/apply.sh"
check "apply.sh is executable" test -x "${APPLY}"
apply_covers() { grep -qF "$1" "${APPLY}"; }
check "apply covers the Ollama drop-in"  apply_covers 'apply_ollama'
check "apply covers the chat app"        apply_covers 'apply_webui'
check "apply covers the backup timer"    apply_covers 'apply_backup_timer'
# No applier may invoke another script bare under 'set -e'. apply_webui has
# said why since it was written — "a failed re-create aborted 'lca apply'
# right here: the inbound guard was never reconciled, no summary was printed"
# — and the other two did exactly that, including the last one, where
# everything else has already succeeded by the time it runs.
appliers_check_the_scripts_they_call() {
  local hits
  hits="$(grep -nE '^[[:space:]]*"\$\{(REPO_ROOT|SCRIPT_DIR)\}/[^"]*"' "${REPO}/scripts/apply.sh" || true)"
  [[ -z "${hits}" ]] || {
    printf 'apply.sh runs these without checking their status:\n%s\n' "${hits}" >&2
    return 1
  }
  # ...and the guarded form must still be there, or a rename could empty this.
  grep -qE 'if ! "\$\{(REPO_ROOT|SCRIPT_DIR)\}/' "${REPO}/scripts/apply.sh" || {
    echo "apply.sh no longer calls any sub-script — this gate stopped watching" >&2
    return 1
  }
}
check "no applier runs a sub-script without checking it worked" \
  appliers_check_the_scripts_they_call

echo "# setup.sh may only die on the four steps without which there is no stack"
# Same rule, one script over. setup.sh already knows the distinction — it
# guards Docker, the chat app and Tailscale with "continuing without it" and
# says so in a comment — but three other steps were bare: the initial
# auto-tune, and both boot-service installs. Auto-tune only chooses a model
# tag, and .env already holds a usable one; the two --install-service calls
# sit two lines above the inbound guard and three above the final check. A
# failure in any of them ended a first-boot install with the ports unguarded
# and nothing verified, having already done everything else correctly.
#
# Bare and fatal is right for exactly four: base packages, git, the venv that
# holds aider, and Ollama. Without any one of them there is no stack.
setup_only_dies_on_core_steps() {
  local core='install_dependencies|install_git|install_python|install_ollama'
  local bare found
  # Lines that START with the quoted path and carry no '||' fallback.
  bare="$(grep -nE '^[[:space:]]*"[$][{]SCRIPT_DIR[}]/[^"]*"' "${REPO}/setup.sh" \
    | grep -v '||' | grep -vE "(${core})[.]sh" || true)"
  [[ -z "${bare}" ]] || {
    printf 'setup.sh dies on a step it could carry on without:\n%s\n' "${bare}" >&2
    return 1
  }
  found="$(grep -cE "^[[:space:]]*\"[$][{]SCRIPT_DIR[}]/scripts/(${core})[.]sh\"" "${REPO}/setup.sh")"
  [[ "${found}" == "4" ]] || {
    printf 'expected the 4 core installers to run bare, found %s — this gate stopped watching\n' "${found}" >&2
    return 1
  }
}
check "setup.sh only aborts on the steps that leave no stack at all" \
  setup_only_dies_on_core_steps
# The dry run must be incapable of changing anything: every mutating call has
# to sit behind the 'would' guard that returns early.
dry_run_guards_every_change() {
  local fn bad=0
  for fn in apply_ollama apply_webui apply_backup_timer; do
    awk -v f="${fn}" '$0 ~ "^"f"\\(\\) \\{" {inf=1}
         inf && /would /        {guarded=1}
         inf && /render_ollama_dropin|install_webui\.sh|--install-timer/ \
             && !/^[[:space:]]*(info|warn|ok|die|#)/ {if (!guarded) bad=1}
         inf && /^}/            {inf=0}
         END {exit bad}' "${APPLY}" || {
      printf '%s can change something before its dry-run guard\n' "${fn}" >&2; bad=1
    }
  done
  return "${bad}"
}
check "every change in apply.sh sits behind the dry-run guard" dry_run_guards_every_change
# A dry run's plan is the entire answer, so it must survive a redirect. The
# first version printed it through warn() — i.e. to stderr — so
# 'lca apply --dry-run > plan.txt' produced a file with a summary count and no
# plan. Invisible in a terminal, where both streams land together; CI caught it
# only because it captured stdout.
dry_run_plan_is_on_stdout() {
  local out
  out="$(cd "${SANDBOX}" && DRY_RUN=true CHANGED=0 bash -c '
    source "$1"; C_YELLOW=""; C_RESET=""
    source /dev/stdin <<EOF
$(sed -n "/^would()/,/^}/p" "$2")
EOF
    would "do the thing" 2>/dev/null' _ "${REPO}/scripts/lib.sh" "${APPLY}")"
  grep -q 'do the thing' <<<"${out}" || {
    echo "the dry-run plan does not reach stdout" >&2; return 1
  }
}
check "the dry-run plan reaches stdout, not stderr" dry_run_plan_is_on_stdout
# "Cannot ask" is not "nothing to do". Every docker probe collapses "no
# container" and "daemon is down" into the same non-zero exit, and the first
# version reported a down daemon as "not created yet — create it with
# install_webui.sh": untrue, and a command that could not have worked either,
# while a perfectly good container sat there with drifted settings.
apply_distinguishes_daemon_down() {
  local out
  out="$(bash -c '
    set -uo pipefail
    source "$1"                # lib.sh
    source "$2"                # apply.sh (its guard stops main from running)
    docker_daemon_reachable() { return 1; }
    webui_container_exists()  { return 0; }   # a container DOES exist
    have() { return 0; }
    ENABLE_WEBUI=true; SKIP_DOCKER=false; DRY_RUN=false
    CHANGED=0; BLOCKED=0; UNCHECKED=0
    apply_webui 2>&1
    printf "UNCHECKED=%s CHANGED=%s\n" "${UNCHECKED}" "${CHANGED}"
  ' _ "${REPO}/scripts/lib.sh" "${APPLY}" 2>&1)"
  grep -qi 'cannot reach the Docker daemon' <<<"${out}" || {
    printf 'a down daemon was not reported as such: %s\n' "${out}" >&2; return 1
  }
  grep -q 'UNCHECKED=1' <<<"${out}" || {
    printf 'a down daemon was not counted as unchecked: %s\n' "${out}" >&2; return 1
  }
  # And it must not have claimed the container is missing.
  if grep -qi 'not created yet' <<<"${out}"; then
    echo "a down daemon was reported as a missing container" >&2; return 1
  fi
}
check "apply reports an unreachable Docker daemon, not a missing container" \
  apply_distinguishes_daemon_down
# ...and the summary must never say "everything matches" about something it
# could not look at.
apply_summary_admits_unchecked() {
  awk '/CHANGED == 0/ {inf=1}
       inf && /UNCHECKED > 0/ {guarded=1}
       inf && /already matches .env/ {if (!guarded) bad=1; inf=0}
       END {exit bad}' "${APPLY}"
}
check "apply never claims a clean bill for an unchecked component" \
  apply_summary_admits_unchecked

echo "# 'lca apply' must move Ollama before rebuilding the chat app"
# The container bakes in OLLAMA_BASE_URL at creation. docs/TROUBLESHOOTING.md
# now tells people to fix a moved OLLAMA_HOST with 'lca apply', so Ollama must
# be listening on the new port before the container is rebuilt to point at it.
# Reversed, the chat app spends the gap talking to a port nothing answers on —
# the exact failure this command was written to end. Silent if broken: the end
# state is still correct, only the window between is wrong.
apply_moves_ollama_first() {
  awk '/^main\(\) \{/ {inmain=1}
       inmain && /^  apply_ollama$/ {o=NR}
       inmain && /^  apply_webui$/  {w=NR}
       END {exit !(o > 0 && w > 0 && o < w)}' "${APPLY}"
}
check "apply re-points Ollama before it rebuilds the chat app" \
  apply_moves_ollama_first
# A missing component is not a matching one.
distinguishes_absent_from_matching() {
  grep -qF 'webui_container_exists' "${APPLY}"
}
check "apply says 'not created yet' rather than 'already matches'" \
  distinguishes_absent_from_matching
# Scheduled backups are opt-in; applying .env must not create a timer nobody
# asked for.
never_creates_a_timer() {
  awk '/^apply_backup_timer\(\) \{/ {inf=1}
       inf && /is-enabled/ {guarded=1}
       inf && /--install-timer/ && !/^[[:space:]]*(info|warn|ok|die|#)/ {if (!guarded) bad=1}
       inf && /^}/ {inf=0}
       END {exit bad}' "${APPLY}"
}
check "apply never installs a backup timer that was not there" never_creates_a_timer
check "'lca apply' is dispatched by bin/lca" grep -q 'apply)' "${REPO}/bin/lca"
# check-system.sh must report the drift, for the user who has not rebooted yet.
check_reports_dropin_drift() {
  grep -qF 'ollama_dropin_matches' "${REPO}/check-system.sh"
}
check "check-system.sh reports ollama config drift" check_reports_dropin_drift
# ...and the OTHER half of the same class. Ollama's drop-in drift was reported
# here from the start; the chat app's was reported only by './webui.sh status',
# which is not the command the README, the docs or the login banner point
# anyone at. So the half containing the assistant's own system prompt could
# drift with 'lca check' saying nothing — the exact silence this class of test
# exists to break.
check_reports_webui_drift() {
  grep -qF 'webui_drift' "${REPO}/check-system.sh" || {
    echo "'lca check' never asks whether the chat app matches .env" >&2
    return 1
  }
  # And it must not claim a match for a container that is not there: with no
  # container every comparison reads "cannot tell", and "matches .env" about a
  # thing that does not exist is worse than saying nothing.
  awk '/webui_drifted="\$\(webui_drift/ { found=1 }
       found && /p_pass "chat app matches/ { ok=guarded }
       /if \[\[ -n "\$\{webui_status\}" \]\]/ { guarded=1 }
       END { exit !ok }' "${REPO}/check-system.sh" || {
    echo "the chat-app drift check is not scoped to an existing container" >&2
    return 1
  }
}
check "check-system.sh reports chat app config drift too" check_reports_webui_drift

echo "# every setting baked into the WebUI container must be drift-checked"
# Editing .env does not change a running container, so each of these can be
# changed in .env and silently not take effect. Port and model drift were
# already reported; signup drift was not — and that is the one where the
# silence means "you think signups are locked and they are open".
drift_checked() {
  local var="$1"
  # Read out of the container in exactly ONE place (lib.sh's webui_container_env
  # / webui_drift). It used to be written out per key inline in webui.sh, and
  # the third key — signups — was simply never added, which is the whole reason
  # the comparison now lives in one function.
  grep -qF "webui_container_env ${var}" "${REPO}/scripts/lib.sh" || {
    printf 'lib.sh never reads %s out of the running container\n' "${var}" >&2; return 1
  }
  # ...while the message stays specific per key: "PORT differs" and "anyone can
  # still register an account" are not the same news.
  grep -qiE "warn \"${2} drift" "${REPO}/webui.sh" || {
    printf 'nothing warns specifically about %s (%s) drift\n' "${var}" "${2}" >&2; return 1
  }
}
check "webui.sh reports PORT drift"          drift_checked PORT Port
check "webui.sh reports DEFAULT_MODELS drift" drift_checked DEFAULT_MODELS Model
check "webui.sh reports ENABLE_SIGNUP drift"  drift_checked ENABLE_SIGNUP Signup
check "webui.sh reports OLLAMA_BASE_URL drift" drift_checked OLLAMA_BASE_URL "Ollama address"
check "webui.sh reports WEBUI_NAME drift"      drift_checked WEBUI_NAME Name
check "webui.sh reports system prompt drift" \
  drift_checked DEFAULT_MODEL_PARAMS "System prompt"
check "webui.sh reports starter question drift" \
  drift_checked DEFAULT_PROMPT_SUGGESTIONS "Starter question"
# Every setting the installer bakes in from .env must be compared. The three
# telemetry flags are constants, so they cannot drift; everything else can, and
# "the ones we happened to think of" is how OLLAMA_BASE_URL — the address the
# phone uses to reach the model at all — went unchecked.
#
# ONE definition, used by both tests below. Written out twice, the reach test
# guarded its own copy: reverting the loop's pattern to the blind one left
# every test green. Two copies drifting apart is the bug this whole gate
# exists to catch, so it must not be how the gate is built.
baked_keys() {
  grep -oE '\-e "?[A-Z_]+=' "${REPO}/scripts/install_webui.sh" \
    | grep -oE '[A-Z_]+' | sort -u
}
every_baked_setting_is_compared() {
  local key bad=0
  while read -r key; do
    [[ -n "${key}" ]] || continue
    case "${key}" in
      # Constants, not .env-derived, so there is nothing for them to drift
      # FROM. ENABLE_OPENAI_API and ENABLE_VERSION_UPDATE_CHECK join them:
      # both are off unconditionally because this stack has no cloud API and
      # no business calling github.com to see if it is out of date.
      DO_NOT_TRACK|SCARF_NO_ANALYTICS|ANONYMIZED_TELEMETRY) continue ;;
      ENABLE_OPENAI_API|ENABLE_VERSION_UPDATE_CHECK) continue ;;
    esac
    grep -qF "webui_container_env ${key}" "${REPO}/scripts/lib.sh" || {
      printf 'install_webui.sh bakes in %s but nothing ever compares it\n' "${key}" >&2
      bad=1
    }
  done < <(baked_keys)
  return "${bad}"
}
check "every setting baked into the container is drift-checked" \
  every_baked_setting_is_compared
# The gate above is only as good as what it can see, and for two settings it
# saw nothing. It anchored on '^<spaces>-e KEY=', which matches the plain
# 'docker run' flags but NOT the two baked in from inside an array literal as
# '-e "KEY=$(...)"' — the system prompt and the starter questions. So the pair
# that decides what the assistant will and will not do were precisely the two
# nothing compared, and 'lca apply' answered "already matches .env" after a
# repo update that changed the prompt. Assert the scanner's reach directly:
# a gate whose blind spot is invisible is worse than no gate.
baked_scanner_sees_array_form() {
  local found
  found="$(baked_keys)"
  grep -qx 'DEFAULT_MODEL_PARAMS' <<<"${found}" || {
    echo "the baked-settings scanner cannot see DEFAULT_MODEL_PARAMS" >&2; return 1
  }
  grep -qx 'DEFAULT_PROMPT_SUGGESTIONS' <<<"${found}" || {
    echo "the baked-settings scanner cannot see DEFAULT_PROMPT_SUGGESTIONS" >&2; return 1
  }
  # ...and it must not invent keys either: everything it yields has to be a
  # real '-e' flag in the installer.
  local key
  while read -r key; do
    [[ -n "${key}" ]] || continue
    grep -qE "\\-e \"?${key}=" "${REPO}/scripts/install_webui.sh" || {
      printf 'the scanner produced %s, which install_webui.sh never bakes in\n' "${key}" >&2
      return 1
    }
  done <<<"${found}"
}
check "the baked-settings scanner sees the array-literal '-e \"KEY=\"' form" \
  baked_scanner_sees_array_form
# ...and the comparison itself must work, not merely exist. The tests above
# are source greps; this one drives webui_drift() for real, with the container
# read stubbed so it runs anywhere (CI has no docker daemon). The bug being
# guarded is behavioural: 'lca apply' reported "already matches .env" to
# someone who had just pulled a repo whose system prompt was different.
#
# Each case runs in a subshell so the stub cannot leak into later tests.
if have jq; then
  # drift_says PATTERN LIVE_VALUE — is PATTERN among the drifted keys when the
  # container was created with LIVE_VALUE as its system prompt?
  # The stub's variable is NOT called 'live'. webui_drift() declares its own
  # 'local live', and bash's dynamic scoping means the stub — called from
  # inside it — would read webui_drift's empty one instead of ours. The test
  # then passed the "no drift" cases and failed the one that mattered, for a
  # reason that had nothing to do with the code under test.
  drift_says() {
    local want="$1" stub_live="$2" out
    out="$(
      webui_container_env() {
        [[ "$1" == "DEFAULT_MODEL_PARAMS" ]] || return 1
        [[ -n "${stub_live}" ]] || return 1
        printf '%s' "${stub_live}"
      }
      webui_drift || true
    )"
    # Spelled out rather than '! grep -q ...': a bare negation as a function's
    # last statement is SC2251 (it skips errexit), and the repo lints clean.
    if [[ "${want}" == "none" ]]; then
      if grep -q SYSTEM_PROMPT <<<"${out}"; then
        printf 'drift was claimed when it should not have been: %s\n' "${out}" >&2
        return 1
      fi
      return 0
    fi
    grep -q SYSTEM_PROMPT <<<"${out}"
  }
  check "a container holding today's prompt is not called drifted" \
    drift_says none "$(lca_system_prompt | jq -Rsc '{system: .}')"
  check "a container holding a different prompt IS reported as drift" \
    drift_says SYSTEM_PROMPT "$(printf 'you are a helpful assistant' | jq -Rsc '{system: .}')"
  # An install predating the setting, or one made without jq, baked in no such
  # value at all. "Cannot tell" is not "differs" — claiming drift there would
  # send every one of those users to re-create a container for no reason.
  check "a container created without the setting is not called drifted" \
    drift_says none ""
else
  echo "skip - jq not installed, cannot exercise the system prompt comparison"
fi

echo "# reading the container's settings must never wait for ever on a wedged docker"
# 'docker inspect' has no timeout of its own. Against a daemon that accepts the
# socket connection and then answers nothing, the CLI waits indefinitely — and
# every caller of webui_container_env is a REPORTER: 'lca check', 'lca test',
# 'lca apply', the login banner. The banner runs as root on every SSH login, so
# unbounded there is not "the banner is slow", it is a machine nobody can log
# in to in order to restart the daemon.
#
# Behavioural, not a grep: a docker that sleeps, and a clock.
webui_env_is_bounded() {
  local dir="${SANDBOX}/wedged" start elapsed
  rm -rf "${dir}"; mkdir -p "${dir}"
  printf '#!/bin/sh\nsleep 30\n' >"${dir}/docker"
  # sudo stubbed too, and not for convenience: without it the root fallback
  # either prompts for a password (hanging the test on a developer box) or
  # finds the REAL docker through sudo's secure_path, so the run would prove
  # nothing about the stub. 'exec "$@"' keeps the fallback on the sleeper.
  printf '#!/bin/sh\nexec "$@"\n' >"${dir}/sudo"
  chmod +x "${dir}/docker" "${dir}/sudo"
  # A file rather than 'bash -c': shellcheck stops recognising the -c argument
  # as a script once a 'timeout' wrapper stands in front of it, and reads the
  # positional parameters inside as an unexpanded string (SC2016). The repo
  # lints at zero findings, and a disable directive to keep a test convenient
  # is exactly the sort of thing that later hides a real one.
  cat >"${dir}/probe.sh" <<'PROBE'
#!/usr/bin/env bash
export PATH="$2:${PATH}"
export LCA_INSPECT_TIMEOUT=1
source "$1" >/dev/null 2>&1
load_env_readonly
webui_container_env PORT
PROBE
  start="$(date +%s)"
  # Wrapped, so a regression FAILS this check instead of stalling the suite
  # for a minute — the unbounded form takes 30s per attempt, twice.
  timeout 25 bash "${dir}/probe.sh" "${REPO}/scripts/lib.sh" "${dir}" >/dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - start ))
  if (( elapsed >= 10 )); then
    printf 'webui_container_env took %ss against a hung docker — it is unbounded\n' "${elapsed}" >&2
    return 1
  fi
}
if have timeout; then
  check "webui_container_env gives up on a hung docker instead of waiting" \
    webui_env_is_bounded
else
  echo "skip - no 'timeout' command, cannot bound the docker read"
fi

# And check-system.sh must say something about open signups, since that is
# where a user looks when asking "is this box safe?".
signup_reported_by_check() {
  grep -qF 'WEBUI_ENABLE_SIGNUP' "${REPO}/check-system.sh"
}
check "check-system.sh reports the signup setting" signup_reported_by_check

echo "# every drift message must name the one command that fixes drift"
# 'lca apply' exists precisely so nobody has to remember which script applies
# which setting. It was added, documented in TROUBLESHOOTING.md — and then the
# place users actually MEET drift, the output of 'lca check' and
# 'webui.sh status', went on naming individual scripts. Seven messages, seven
# different things to remember, for a problem that now has one answer.
drift_messages_name_apply() {
  local bad=0 line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    grep -qF 'lca apply' <<<"${line}" || {
      printf 'a drift message does not point at "lca apply":\n  %s\n' "${line:0:120}" >&2
      bad=1
    }
  done < <(grep -hE '(warn|p_warn) ".*[Dd]rift' "${REPO}/check-system.sh" "${REPO}/webui.sh")
  return "${bad}"
}
check "every drift message points at 'lca apply'" drift_messages_name_apply

# ...and nothing may offer a container RESTART as the way to make a setting
# take effect. 'lca model' did: "aider and Open WebUI pick the new default up
# automatically (WebUI may need: webui.sh restart)". Half of that is true —
# aider reads .env on every run — and the other half cannot work. MODEL_NAME is
# baked into the container as '-e DEFAULT_MODELS=', a container's environment
# is fixed for its lifetime, and 'restart' is stop+start of the SAME container.
# So the one script whose entire purpose is changing that setting was the one
# script pointing at a command that could not apply it, while webui_drift,
# 'lca check' and 'webui.sh status' all said 'lca apply'.
#
# Keyed on the container, not on 'restart' generally: 'systemctl restart ollama'
# IS how the drop-in takes effect, because those settings live in a unit file
# rather than baked into an image.
#
# No carve-outs, because none turned out to be needed: naming the command as a
# command reads 'lca webui <cmd>' or a 'restart)' case arm, neither of which
# matches "restart the chat app to make X take effect". The one exemption kept
# is a line that ALSO says 'lca apply' — a message may well need to explain
# that a restart is not enough.
no_restart_as_apply_instruction() {
  local f hits bad=0
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/README.md "${REPO}"/docs/*.md; do
    hits="$(sed 's/^[[:space:]]*#.*//' "${f}" \
      | grep -nE '(webui\.sh|lca webui|docker) restart' \
      | grep -vF 'lca apply' || true)"
    [[ -z "${hits}" ]] || {
      printf '%s offers a container restart as the way to apply a setting:\n%s\n' \
        "${f##*/}" "${hits}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "no command offers a chat-app restart as the way to apply a setting" \
  no_restart_as_apply_instruction

echo "# a 120-second wait is the wrong answer to a port read off the container"
# Every health wait polls .env's WEBUI_PORT; the container listens on the port
# it was CREATED with. When those differ — someone edited .env and has not
# applied it — 'lca webui start' and 'lca webui restart' each spent two minutes
# probing a port nothing would ever answer on, then said "check the logs",
# where a perfectly healthy app is logging on another port. 'status' already
# detected the mismatch; the other two never asked.
#
# Driven against a stubbed container, so no docker daemon is needed. The third
# case is the one that keeps this honest: an unreadable container is "cannot
# tell", not "mismatch", or every box without docker access would be told its
# ports disagree.
webui_mismatch() {  # live-port -> the reason, or empty
  bash -c '
    source "$1" >/dev/null 2>&1
    WEBUI_PORT=3000
    if [[ "$2" == "__unreadable__" ]]; then webui_container_env() { return 1; }
    else LIVE="$2"; webui_container_env() { printf "%s" "${LIVE}"; }; fi
    port_mismatch_reason || true' _ "${REPO}/webui.sh" "$2" 2>/dev/null
}
mismatch_says() { grep -qF -- "$1" <<<"$(webui_mismatch _ "$2")"; }
no_mismatch()   { [[ -z "$(webui_mismatch _ "$1")" ]]; }
check "matching ports are not a mismatch"        no_mismatch 3000
check "a different live port is explained"       mismatch_says "listens on port 8080" 8080
check "...and points at the one command that fixes it" \
  mismatch_says "lca apply" 8080
check "an unreadable container is not a mismatch" no_mismatch __unreadable__
# ...and every wait must consult it, not just the one that always did.
#
# 'waits' is counted and required non-zero. This gate previously matched
# 'wait_for_webui', which webui.sh stopped calling directly the day the wait
# grew a second failure mode and moved behind webui_wait_or_die — at which
# point awk matched nothing, set nothing, and reported ok about zero waits.
# Caught while making that change; the counter is so the next rename cannot
# do it quietly.
every_health_wait_checks_the_port() {
  awk '/^[[:space:]]*#/ { next }
       /port_mismatch_reason/ { seen = NR }
       /wait_for_webui|webui_wait_or_die/ {
         waits++
         if (seen == 0 || NR - seen > 6) { print "unguarded wait at line " NR; bad = 1 }
       }
       END {
         if (waits == 0) {
           print "this gate found no health wait in webui.sh at all — it has been renamed and the gate now checks nothing"
           bad = 1
         }
         exit bad
       }' "${REPO}/webui.sh"
}
check "every health wait explains a port mismatch instead of timing out" \
  every_health_wait_checks_the_port

echo "# a chat app that is slow to start is not one that failed to start"
# The deadline was 120s for start/restart and 180s for the installer. Measured
# from the container's own log on this project's CPU-only box, every real boot
# it has had — container start to "Started server process":
#
#   29s, 4m30s, 1m57s, 16s, 6m55s
#
# Three of five were at or past 120s and two past 180s: Open WebUI loads an
# embedding model before it serves, and that competes with Ollama for the same
# cores. So the ordinary case — the box reboots, both come up, the owner reads
# the banner and runs the command it gives — ended in "[FAIL] Container
# started but no HTTP answer after 120s" about a container that answered four
# minutes later.
#
# Raising the number alone would mean a genuinely dead container holds the
# terminal for ten minutes, so the wait now watches the container too and the
# two outcomes must stay distinguishable. Driven with a /health that never
# answers and no real sleeping, so this costs nothing to run.
wait_outcome() {  # container-alive(yes|no) timeout -> rc
  bash -c '
    source "$1" >/dev/null 2>&1
    sleep() { :; }
    webui_responds() { return 1; }
    if [[ "$2" == yes ]]; then webui_container_running() { return 0; }
    else webui_container_running() { return 1; }; fi
    rc=0; wait_for_webui "$3" >/dev/null 2>&1 || rc=$?
    printf "%s" "${rc}"' _ "${REPO}/scripts/lib.sh" "$1" "$2"
}
check "a container that is up but not answering times out as 'slow'" \
  test "$(wait_outcome yes 90)" = 1
check "a container that has stopped is a different answer, not the same one" \
  test "$(wait_outcome no 90)" = 2
# ...and the stopped case must be reported PROMPTLY. Returning 2 only at the
# deadline would be the same ten-minute stall the long timeout was supposed to
# be safe from: the check runs every 30s, so a stopped container is named then
# even when the caller allowed 600.
check "...and it says so at the first check, not at the deadline" \
  test "$(wait_outcome no 600)" = 2
# A silent wait through seven minutes is indistinguishable from a hang, and
# the honest reading of that silence is "this is broken, kill it".
wait_is_not_silent() {
  local out
  out="$(bash -c '
    source "$1" >/dev/null 2>&1
    sleep() { :; }
    webui_responds() { return 1; }
    webui_container_running() { return 0; }
    wait_for_webui 90 2>&1 || true' _ "${REPO}/scripts/lib.sh")"
  [[ -n "${out}" ]] || { echo 'a multi-minute wait prints nothing at all' >&2; return 1; }
  grep -qi 'still starting' <<<"${out}" || {
    printf 'the wait never says it is still working: %s\n' "${out}" >&2; return 1; }
}
check "a long wait keeps saying it is still working" wait_is_not_silent
# ...and the distinction must survive the trip to the user. One message for
# both outcomes is the hedge this whole change exists to remove.
wait_die_msg() {  # yes|no -> the message
  bash -c '
    source "$1" >/dev/null 2>&1
    sleep() { :; }
    webui_responds() { return 1; }
    if [[ "$2" == yes ]]; then webui_container_running() { return 0; }
    else webui_container_running() { return 1; }; fi
    webui_wait_or_die 60 "SEE-THE-LOG"' _ "${REPO}/scripts/lib.sh" "$1" 2>&1 || true
}
wait_messages_are_different() {
  local alive dead
  alive="$(wait_die_msg yes)"; dead="$(wait_die_msg no)"
  [[ "${alive}" != "${dead}" ]] || {
    printf 'a stopped container and a slow one are given the same message: %s\n' "${alive}" >&2
    return 1; }
  grep -qi 'still running' <<<"${alive}" || {
    printf 'the slow case does not say the container is still up: %s\n' "${alive}" >&2; return 1; }
  grep -qi 'stopped' <<<"${dead}" || {
    printf 'the stopped case does not say the container stopped: %s\n' "${dead}" >&2; return 1; }
  grep -qi 'slow' <<<"${dead}" || {
    printf 'the stopped case does not rule out "it is just slow", which is what the reader will assume: %s\n' "${dead}" >&2
    return 1; }
  local m
  for m in "${alive}" "${dead}"; do
    grep -qF 'SEE-THE-LOG' <<<"${m}" || {
      printf 'a failure message does not name the log that would explain it: %s\n' "${m}" >&2
      return 1; }
  done
}
check "a stopped container and a slow one are told apart, in words" \
  wait_messages_are_different
# ...and no script may take the raw wait and collapse it again.
every_caller_uses_the_deciding_wrapper() {
  local bad=0 seen=0 f
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh; do
    [[ "${f}" == */lib.sh ]] && continue    # where both functions live
    grep -q 'wait_for_webui' "${f}" || continue
    seen=$((seen+1))
    printf '%s calls wait_for_webui directly instead of webui_wait_or_die, so it cannot tell a stopped container from a slow one\n' \
      "${f##*/}" >&2
    bad=1
  done
  # Nothing to find is the CORRECT state here, so 'seen' is not required to be
  # non-zero — but the wrapper must exist, or this passes over a repo that
  # deleted the distinction entirely.
  grep -q '^webui_wait_or_die()' "${REPO}/scripts/lib.sh" || {
    echo 'webui_wait_or_die is gone, so nothing is drawing the distinction any more' >&2
    bad=1
  }
  return "${bad}"
}
check "no script flattens the two ways a start can fail" \
  every_caller_uses_the_deciding_wrapper

echo "# a restart is not an apply, and must stop implying that it is"
# 'docker restart' is stop-then-start of the SAME container, and a container's
# environment is fixed when it is created. So a restart carries every setting
# the container was built with — and restarting is exactly what someone tries
# after editing .env. The whole output was "Open WebUI restarted."
webui_note() {  # drifted keys (newline-separated), or __none__ -> the note
  bash -c '
    source "$1" >/dev/null 2>&1
    KEYS="$2"
    if [[ "${KEYS}" == "__none__" ]]; then webui_drift() { return 1; }
    else webui_drift() { printf "%s\n" "${KEYS}"; }; fi
    drift_note 2>&1' _ "${REPO}/webui.sh" "$1" 2>/dev/null
}
note_says()  { grep -qF -- "$1" <<<"$(webui_note "$2")"; }
note_quiet() { [[ -z "$(webui_note "$1")" ]]; }
check "nothing drifted -> the restart says nothing extra" \
  note_quiet __none__
check "a drifted setting is named after the restart" \
  note_says "SYSTEM_PROMPT" "SYSTEM_PROMPT"
check "...and the note points at the one command that applies it" \
  note_says "lca apply" "SYSTEM_PROMPT"
# ...and both commands that re-use an existing container must draw it. 'start'
# is the same trap: it starts the container that is already there.
start_and_restart_draw_the_note() {
  local body
  body="$(awk '/^  case "\$\{cmd\}" in/ { inb = 1 } inb' \
            <<<"$(sed 's/#.*//' "${REPO}/webui.sh")")"
  [[ -n "${body}" ]] || {
    echo "could not find webui.sh's command dispatch — this gate stopped watching" >&2
    return 1
  }
  local n
  n="$(grep -c 'drift_note' <<<"${body}")"
  [[ "${n}" == "2" ]] || {
    printf 'expected start and restart to draw the drift note, found %s call(s)\n' "${n}" >&2
    return 1
  }
}
check "both 'start' and 'restart' say what they did NOT apply" \
  start_and_restart_draw_the_note

echo "# auto-tune must apply its own decision to everything that holds a copy"
# tune.sh runs on every boot; a droplet resize is the headline reason. When the
# ladder moves it writes MODEL_NAME, re-renders the Ollama drop-in, restarts
# Ollama and prints "Auto-tune applied" — and stopped there. The chat app was
# created with the OLD model baked in, so the phone went on offering it while
# .env, the drop-in and that very line all said otherwise. Only 'lca check'
# knew, and only if someone ran it.
#
# Reconciled rather than reported, because nobody watches a boot oneshot.
tune_reconciles_after_a_model_change() {
  awk '/^[[:space:]]*#/ { next }
       /old_model.*!=.*chosen_model/ { inb = 1 }
       inb && /apply\.sh/ { found = 1 }
       inb && /^    else$/ { exit }
       END { exit !found }' "${REPO}/scripts/tune.sh" || {
    echo 'tune.sh changes the model without reconciling anything that baked the old one in' >&2
    return 1; }
}
check "auto-tune reconciles the rest of the system when the model changes" \
  tune_reconciles_after_a_model_change
# ...and the boot unit has to be ordered after Docker, or that reconciliation
# runs while the daemon is still starting: apply.sh then correctly reports it
# could not look, and the container keeps the old model anyway.
tune_unit_waits_for_docker() {
  grep -qE '^[[:space:]]*echo "After=.*docker\.service' "${REPO}/scripts/tune.sh"
}
check "the auto-tune boot unit is ordered after Docker" tune_unit_waits_for_docker

echo "# no document may tell you to re-run an installer to apply a .env change"
# 'lca apply' replaced a lookup table of "which script applies which setting",
# but seven instructions across README.md, YOUR-TURN.md, PHONE.md and
# TROUBLESHOOTING.md still named the individual installers. One of them was
# outright incomplete: "change OLLAMA_HOST to another port and re-run
# scripts/install_ollama.sh" renders the drop-in and never touches the chat
# app container, which is exactly how the phone came to be pointed at a port
# nothing listens on. 'lca apply' does both, so the advice is now correct as
# well as shorter.
# Naming an installer for what it IS (docs/INSTALL.md) is fine; this only
# forbids naming it as the way to APPLY an edit.
#
# The shape, not the sentence. What is wrong is the PAIRING — text about .env
# next to an instruction to run an installer, with no mention of 'lca apply' —
# so that is what both gates below look for, over a sliding two-line window
# because prose wraps and an instruction routinely spans two lines.
#
# The version this replaces matched two literal strings: "re-run
# `scripts/install_" and "re-running `scripts/install_". Measured against two
# phrasings a person would plausibly write — "then run\n`scripts/install_webui.sh`"
# and "execute /opt/local-code-agent/scripts/install_ollama.sh again" — it
# matched neither. The relative-path spelling was baked in too, and these
# messages moved to absolute paths a few commits ago.
#
# The '.env' in the window is the load-bearing half, not decoration. Without it
# the scan cannot tell "apply your edit" from "install the missing thing", and
# the latter is correct advice: measured across the scripts lca dispatches to,
# sixteen windows say things like "docker not installed (run
# .../install_docker.sh)" and "virtualenv missing (run .../install_python.sh)".
# 'lca apply' has nothing to offer any of them.
#
# APPLY_ADVICE_RE is the run-verb governing an installer path. A closed set of
# verbs is still hand-written, but it is a much smaller thing to keep complete
# than a set of English sentences, and it is what separates advice from the two
# legitimate mentions in the tree: docs/INSTALL.md naming the installer for what
# it IS, and TROUBLESHOOTING.md saying manual drop-in edits are overwritten "on
# the next ... run" — a verb AFTER the path, not before it.
APPLY_ADVICE_RE='(run|re-run|rerun|execute|invoke|call)[^.]{0,60}install_[a-z_]*\.sh'
# pairs_env_with_installer FILE — print each two-line window that reads as
# "edit .env, then run an installer", skipping any that names lca apply.
pairs_env_with_installer() {
  awk -v pat="${APPLY_ADVICE_RE}" '
    { prev = cur; cur = $0; w = prev " " cur }
    w ~ /\.env/ && w ~ pat && w !~ /lca apply/ { printf "%d: %s\n", NR, substr(w, 1, 200) }' "$@"
}
no_installer_as_apply_instruction() {
  local f hits
  for f in "${REPO}/README.md" "${REPO}"/docs/*.md; do
    hits="$(pairs_env_with_installer "${f}" || true)"
    [[ -z "${hits}" ]] || {
      printf '%s tells the reader to run an installer instead of lca apply:\n%s\n' \
        "${f##*/}" "${hits}" >&2
      return 1
    }
  done
}
check "no doc names an installer as the way to apply a .env edit" \
  no_installer_as_apply_instruction
# The same rule for the messages a user reads at the terminal, which is where
# it was actually still being broken: 'lca check' warned that signups were open
# and told you to re-run scripts/install_webui.sh, while PHONE.md — fixed in
# the same change that added 'lca apply' — told you 'sudo lca apply'. Two
# half-remembered ways to do one thing is precisely what that command exists
# to end, and the docs gate could not see a string inside a .sh file.
#
# Scoped to the surfaces that REPORT state. An installer telling you to re-run
# an installer is correct advice — install_webui.sh's port clash happens after
# it has already removed the old container, so 'lca apply' would have nothing
# to re-create and the installer really is the next step.
no_status_command_sends_you_to_an_installer() {
  local s hits
  # Two upgrades, both from finding this rule broken again in a place the old
  # check could not see.
  #
  # Path-agnostic, because these messages name absolute paths now and a pattern
  # tied to the old relative spelling would match nothing ever again — a gate
  # that cannot fail, guarding a rule that still matters.
  #
  # And a sliding two-line window, because 'lca speed' broke it across two
  # info() calls: "...set OLLAMA_KEEP_ALIVE=-1 in .env and re-run" on one line,
  # the installer path on the next. Each line alone was innocent. Every script
  # lca dispatches to is scanned now, not just the two that report state —
  # speed.sh is a report too, and it was not on the list.
  #
  # Third upgrade, same as the docs gate above: the pattern was the literal
  # phrase 'in \.env and re-run.*install_', so a message reading "edit
  # WEBUI_PORT in .env, then run .../install_webui.sh" — the same mistake,
  # differently worded — went straight through. It matches the pairing now, not
  # a sentence.
  local msgs
  for s in "${LCA_TARGETS[@]}"; do
    msgs="${SANDBOX}/msgs-${s//\//_}"
    grep -E '\b(warn|info|die|err|ok|p_pass|p_warn|p_fail)[[:space:]]+"' "${REPO}/${s}" \
      > "${msgs}" || true
    hits="$(pairs_env_with_installer "${msgs}" || true)"
    [[ -z "${hits}" ]] || {
      printf '%s names an installer instead of lca apply:\n%s\n' "${s}" "${hits}" >&2
      return 1
    }
  done
}
check "no status command names an installer to apply a .env edit" \
  no_status_command_sends_you_to_an_installer

echo "# the login banner's install-state machine"
# The banner is the first thing anyone sees on this box, so being confidently
# wrong there is worse than saying nothing. Every state is exercised against a
# real log file, because the states differ only by content and mtime.
MOTD="${REPO}/scripts/motd.sh"
LOGDIR="${SANDBOX}/logs"
mkdir -p "${LOGDIR}"
# motd_state NAME AGE_SECONDS — write a log (from stdin), age it, classify it.
motd_state() {
  local f="${LOGDIR}/$1" age="$2"
  cat > "${f}"
  touch -d "@$(( $(date +%s) - age ))" "${f}"
  LCA_LOG="${f}" bash -c 'source "$1"; load_env_readonly; install_state' _ "${MOTD}" 2>/dev/null
}
state_is() {
  local want="$1" got="$2"
  [[ "${got}" == "${want}" ]] || { printf 'expected state %s, got %s\n' "${want}" "${got}" >&2; return 1; }
}

check "a fresh log with no verdict is 'running'" state_is running "$(motd_state running 5 <<'EOF'
=== local-code-agent first-boot install started: today ===
==> Downloading the model
EOF
)"
# The one that matters: this repository's own build VM had an interrupted
# install from 19 hours earlier, and "no verdict yet" would have told a user
# with a perfectly working stack that nothing works.
check "an old log with no verdict is 'stalled', not 'running'" state_is stalled "$(motd_state stalled 4000 <<'EOF'
=== local-code-agent first-boot install started: yesterday ===
==> Installing Docker
EOF
)"
# The log file is named 'complete', not 'done': an unquoted 'done' as an
# argument reads to ShellCheck as the loop keyword (SC1010).
check "SETUP COMPLETE is 'done'" state_is "done" "$(motd_state complete 30 <<'EOF'
=== local-code-agent first-boot install started: today ===
SETUP COMPLETE — local-code-agent is ready.
EOF
)"
check "SETUP FINISHED WITH ERRORS is 'failed'" state_is failed "$(motd_state failed 30 <<'EOF'
=== local-code-agent first-boot install started: today ===
SETUP FINISHED WITH ERRORS — 2 step(s) failed.
EOF
)"
check "FIRST-BOOT INSTALL FAILED is 'failed'" state_is failed "$(motd_state bootfail 30 <<'EOF'
=== local-code-agent first-boot install started: today ===
FIRST-BOOT INSTALL FAILED — the droplet is NOT ready.
EOF
)"
# A re-run appends to the same log. Reading the whole file would find the
# PREVIOUS run's "COMPLETE" and report a finished install while one is midway.
check "a re-run ignores the previous run's verdict" state_is running "$(motd_state rerun 5 <<'EOF'
=== local-code-agent first-boot install started: yesterday ===
SETUP COMPLETE — local-code-agent is ready.
=== local-code-agent first-boot install finished: yesterday ===
=== local-code-agent first-boot install started: today ===
==> Installing Ollama
EOF
)"
missing_log_is_none() {
  [[ "$(LCA_LOG="${SANDBOX}/no-such-log" bash -c \
    'source "$1"; load_env_readonly; install_state' _ "${MOTD}" 2>/dev/null)" == "none" ]]
}
check "no log at all is 'none'" missing_log_is_none

echo "# 'ready' has to mean a question can be answered, not that a port replies"
# The banner's strongest word meant only that the Ollama API responded. An
# engine with no model responds to /api/version perfectly and then fails every
# question the very next banner line invites. Two things make that reachable:
# setup no longer dies when the model pull fails — deliberately, so the rest of
# the stack still installs — and a hand-installed box writes no first-boot log,
# so install_state returns 'none' and this probe decides 'ready' alone.
#
# Asymmetric on purpose, and both directions are asserted. Only a positive
# answer that does NOT list the model counts; no curl, no reply, or an
# unparseable body is "could not tell". A banner that cried "not ready" on a
# slow box at every login would be worse than one that says nothing.
motd_missing() {  # stubbed /api/tags body -> "missing" | "no"
  # The body goes through a variable, not through quick()'s own positional
  # parameters: inside the stub "$3" is quick's third ARGUMENT (curl's URL),
  # not the script's. Written that way first, and three of the five checks
  # below passed on it — because a URL contains no '"models"' either.
  bash -c '
    source "$1" >/dev/null 2>&1
    load_env_readonly
    MODEL_NAME=qwen2.5-coder:7b
    BODY="$2"
    if [[ "${BODY}" == "__fail__" ]]; then quick() { return 1; }
    else quick() { printf "%s" "${BODY}"; }; fi
    model_missing && echo missing || echo no' _ "${MOTD}" "$1" 2>/dev/null
}
missing_is() { [[ "$(motd_missing "$2")" == "$1" ]]; }
check "a listed model is not reported missing" \
  missing_is no      '{"models":[{"name":"qwen2.5-coder:7b"}]}'
check "another model listed instead IS missing" \
  missing_is missing '{"models":[{"name":"llama3.1:8b"}]}'
check "an empty model list IS missing" \
  missing_is missing '{"models":[]}'
check "no answer is not evidence of missing" \
  missing_is no      '__fail__'
check "an unparseable answer is not evidence of missing" \
  missing_is no      '<html>502 Bad Gateway</html>'
# ...and the ready banner has to consult it, or the probe is decoration.
ready_banner_asks_about_the_model() {
  # Comments stripped: the note above banner_ready names the helper, and a
  # whole-file grep would be satisfied by that alone.
  awk '/^banner_ready\(\) \{/ { inb = 1 }
       inb && /model_missing/  { found = 1 }
       inb && /^\}/            { exit }
       END { exit !found }' <<<"$(sed 's/#.*//' "${REPO}/scripts/motd.sh")"
}
check "the ready banner asks whether the model is there" \
  ready_banner_asks_about_the_model

echo "# ...and the banner has to name the one command that writes files"
# Before this, the ready banner named the chat URL, 'lca ask' and 'lca help' —
# a text box with no filesystem, one-shot text, and a menu. Not one line named
# the coding agent, while "Ask right here" sat directly where someone looking
# for code would land. That is the same failure as the chat itself, one layer
# earlier and on the screen you get without asking for it: it is what the one
# real bug reporter was reading when they picked the wrong door.
motd_coding_row() {  # AIDER_PATH -> the rendered row
  # The path goes through a variable rather than the stub's own positional
  # parameters: inside a function "$1" is the FUNCTION's argument, not the
  # script's — a mistake this file has made three times.
  bash -c '
    source "$1" >/dev/null 2>&1
    load_env_readonly
    FAKE="$2"
    # AFTER the source: lib.sh defines aider_bin, and a stub set before it
    # would be silently replaced.
    aider_bin() { printf "%s\n" "${FAKE}"; }
    coding_row' _ "${MOTD}" "$1" 2>/dev/null
}
coding_row_names_the_writer() {
  local out
  out="$(motd_coding_row /bin/sh)"   # /bin/sh: an executable that always exists
  [[ -n "${out}" ]] || {
    echo 'the ready banner says nothing about the coding agent' >&2; return 1; }
  # Bare 'lca' — the word on its own. 'lca ask' would satisfy a naive grep for
  # "lca" and is precisely the wrong door: one-shot text, no filesystem.
  grep -qE '(^|[^[:alnum:]_-])lca([^[:alnum:]_-]|$)' <<<"${out}" || {
    echo 'the coding row never names bare "lca"' >&2; return 1; }
  if grep -qE 'lca +(ask|chat|check|help)' <<<"${out}"; then
    echo 'the coding row points at a command that cannot write files' >&2
    return 1
  fi
}
check "the ready banner names the coding agent, not just the chat" \
  coding_row_names_the_writer
# ...and when aider is not installed it must SAY so rather than going quiet.
# 'ready' is the strongest word this file prints; a box that cannot run the
# coding agent has not earned it, which is the same argument model_missing
# makes about an engine with no model.
coding_row_reports_a_missing_agent() {
  local out
  out="$(motd_coding_row /nonexistent/aider)"
  grep -qi 'missing' <<<"${out}" || {
    echo 'a box with no coding agent still prints a banner that says "ready"' >&2
    return 1; }
  # ...naming the fix, and the same one run-agent.sh names, so they cannot drift.
  grep -q 'install_python.sh' <<<"${out}" || {
    echo 'the banner reports a missing coding agent without naming the fix' >&2
    return 1; }
}
check "...and says so when the coding agent is not installed" \
  coding_row_reports_a_missing_agent
# The helper is worth nothing if the ready banner never calls it. Same
# comment-stripped, function-scoped shape as the model probe above.
ready_banner_offers_the_coding_agent() {
  awk '/^banner_ready\(\) \{/ { inb = 1 }
       inb && /coding_row/     { found = 1 }
       inb && /^\}/            { exit }
       END { exit !found }' <<<"$(sed 's/#.*//' "${REPO}/scripts/motd.sh")"
}
check "...and the ready banner actually prints that row" \
  ready_banner_offers_the_coding_agent
# YOUR-TURN.md prints a sample of this banner, and someone deciding what this
# box is for reads that sample long before they ever see the real one. It went
# stale the instant motd.sh changed — a screenshot in a doc is drift waiting to
# happen, and a documented banner that hides the product is the same bug as a
# real one that does.
documented_ready_banner_shows_the_agent() {
  local doc="${REPO}/docs/YOUR-TURN.md" block rows
  block="$(awk '/local-code-agent  ready/ { inb = 1 }
                inb && /^ *```/           { exit }
                inb' "${doc}")"
  [[ -n "${block}" ]] || {
    echo 'YOUR-TURN.md no longer shows the ready banner at all' >&2; return 1; }
  # Drop the rows that cannot write files, then require what is left to still
  # name 'lca' — otherwise "lca ask" alone would satisfy this.
  rows="$(grep -vE 'lca +(ask|chat|check|help)' <<<"${block}" || true)"
  grep -qE '(^|[^[:alnum:]_-])lca([^[:alnum:]_-]|$)' <<<"${rows}" || {
    echo "the banner YOUR-TURN.md shows names only doors that cannot write files" >&2
    return 1; }
}
check "...and the banner the walkthrough shows is not a lie about it" \
  documented_ready_banner_shows_the_agent

echo "# ...and it must not speak in 'lca' on a box that has no 'lca'"
# setup.sh symlinks /usr/local/bin/lca and deliberately does NOT die when it
# cannot — no root, or a read-only /usr/local — it warns and carries on. Right
# call: the stack works, only the short name is missing. But every line of this
# banner is written in 'lca', so such a box gets "ready", a chat URL and four
# commands that all answer 'command not found'. Measured on exactly that box.
#
# chat_address() already refuses to print 'sudo tailscale up' where tailscale
# is absent, and says so in as many words. Same rule, applied to the command
# this file names four times instead of once.
motd_lca_row() {  # present | absent -> the rendered rows
  bash -c '
    source "$1" >/dev/null 2>&1
    load_env_readonly
    STATE="$2"
    # After the source: lib.sh defines have(), and a stub set before it would
    # be silently replaced.
    have() { [[ "$1" == "lca" && "${STATE}" == "present" ]]; }
    missing_lca_row' _ "${MOTD}" "$1" 2>/dev/null
}
banner_names_a_command_that_exists() {
  local absent present
  absent="$(motd_lca_row absent)"
  present="$(motd_lca_row present)"
  [[ -n "${absent}" ]] || {
    echo 'with no lca on PATH the banner still hands out four commands that do not exist' >&2
    return 1; }
  grep -q 'bin/lca' <<<"${absent}" || {
    echo 'the banner reports lca missing without naming the path that does work' >&2
    return 1; }
  grep -q 'setup.sh' <<<"${absent}" || {
    echo 'the banner names the fallback but never how to get the short name back' >&2
    return 1; }
  [[ -z "${present}" ]] || {
    echo 'the banner nags about lca on a box where lca is installed' >&2
    return 1; }
}
check "the banner says so when 'lca' is not on PATH, and stays quiet when it is" \
  banner_names_a_command_that_exists

echo "# ...and neither surface may offer 'tailscale up' where tailscale is absent"
# Two commands explain how to reach the chat: the login banner and 'lca chat'.
# motd.sh's chat_address() learned the rule — "pointing at 'sudo tailscale up'
# here would hand the user a command that does not exist" — and webui.sh did
# not, so 'lca chat' printed exactly that on a box with no tailscale. Measured
# here, where tailscale is genuinely absent. It is the command docs/PHONE.md
# and YOUR-TURN.md both send people to for phone setup, so it is the first
# thing a new owner runs and the first thing that fails.
#
# Gated on both files together, because one copy of a rule in two reporters is
# how they drifted in the first place.
#
# SCOPED to the two regions that print the advice, and that scoping is the
# gate. Written first as a whole-file grep for 'have tailscale' and
# 'not installed', which passed with webui.sh's entire conditional deleted:
# the file mentions tailscale once more when it fetches the IP, and says
# "Docker is not installed" three hundred lines away. Both mutations came back
# NOT CAUGHT — a gate satisfied by unrelated text elsewhere in the file, which
# is the third time that exact fault has appeared on this branch.
tailscale_advice_is_conditional() {
  local body bad=0
  # The 'url' subcommand of webui.sh — what 'lca chat' runs.
  # Comments stripped from BOTH regions. Without that, motd.sh's own comment —
  # "Not installed and not skipped: pointing at 'sudo tailscale up' here would
  # hand the user a command that does not exist" — satisfies the check that the
  # code still has a not-installed arm, and deleting the arm passes.
  # shellcheck disable=SC2016  # the sed address is a literal, not an expansion
  body="$(sed -n '/if \[\[ "${cmd}" == "url" \]\]; then/,/^  fi$/p' "${REPO}/webui.sh" \
          | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find webui.sh's url block — this gate stopped watching" >&2; return 1; }
  # if/fi rather than 'A && B || C', which shellcheck rightly flags (SC2015)
  # and which CONTRIBUTING trap #2 already tells you not to write. An earlier
  # draft put a comment inside the && chain as well, where a trailing backslash
  # continues INTO the comment and silently drops the command after it.
  #
  # The SKIP_TAILSCALE match is the CONDITION, not the word: the skipped arm's
  # own message says "SKIP_TAILSCALE=true", so a bare name match survives
  # replacing the test with 'elif false' and a dead arm passes. '.*' rather
  # than '[^"]*' because the condition is "${SKIP_TAILSCALE:-false}" == "true"
  # and the quote inside the expansion stopped the tighter pattern reaching the
  # '=='  — which made the gate fail on a clean tree.
  if ! grep -q 'tailscale up' <<<"${body}" \
     || ! grep -qi 'not installed' <<<"${body}" \
     || ! grep -qE 'SKIP_TAILSCALE.*==' <<<"${body}"; then
    echo "'lca chat' no longer distinguishes tailscale down / absent / skipped — it hands a box without tailscale a command that does not exist" >&2
    bad=1
  fi
  # ...and the login banner, which learned this rule first.
  body="$(sed -n '/^chat_address() {/,/^}/p' "${REPO}/scripts/motd.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find motd.sh's chat_address — this gate stopped watching" >&2; return 1; }
  grep -qi 'not installed' <<<"${body}" || {
    echo 'the login banner offers tailscale advice without a "not installed" arm' >&2
    bad=1; }
  return "${bad}"
}
check "both 'lca chat' and the banner check for tailscale before naming it" \
  tailscale_advice_is_conditional
# ...and so must setup.sh's own closing advice, which is the third surface that
# names the command. That run tolerates a failed Tailscale install by design —
# "Tailscale did not install — continuing without private phone access" — and
# then finished by telling the reader to run 'sudo tailscale up'. It knew.
setup_next_steps_check_for_tailscale() {
  local body
  body="$(awk '/^  step "Next steps"/ { inb = 1; next }
               inb && /VERDICT_PRINTED/ { exit }
               inb' "${REPO}/setup.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo 'could not find setup.sh Next steps — this gate stopped watching' >&2; return 1; }
  grep -q 'tailscale up' <<<"${body}" || return 0   # no suggestion, nothing to guard
  grep -q 'have tailscale' <<<"${body}" || {
    echo "setup.sh's closing advice offers 'tailscale up' without checking it installed" >&2
    return 1; }
  grep -qi 'did not install' <<<"${body}" || {
    echo "setup.sh checks for tailscale but says nothing when the install it just ran failed" >&2
    return 1; }
}
check "...and so does setup.sh's closing advice" \
  setup_next_steps_check_for_tailscale
# ...from headline(), so a sixth banner state added later cannot forget it.
# Every banner calls exactly one headline, and the note has to sit above the
# rows it is about.
every_banner_state_gets_the_warning() {
  awk '/^headline\(\) \{/       { inb = 1 }
       inb && /missing_lca_row/ { found = 1 }
       inb && /^\}/             { exit }
       END { exit !found }' <<<"$(sed 's/#.*//' "${REPO}/scripts/motd.sh")"
}
check "...and every banner state inherits it, not just the ready one" \
  every_banner_state_gets_the_warning
# ...except the two banners that are already about setup not having finished,
# where "run sudo setup.sh" is wrong (it is running) or duplicated (stalled
# already prints that line).
#
# Keyed on WHICH BANNER renders, not on install_state, and that distinction is
# the whole reason this check exists. Written the state way first and it was
# wrong on the machine it was written on: a verdict-less log from an
# interrupted first boot makes install_state say 'stalled' while main(), which
# trusts the live system over the log, prints banner_ready. The row vanished
# from exactly the box that needed it — caught by running it, not by reading it.
banner_render() {  # BANNER -> its output, with lca absent
  bash -c '
    source "$1" >/dev/null 2>&1
    load_env_readonly
    SETUP_LOG=/nonexistent
    have() { [[ "$1" != "lca" ]]; }
    model_missing() { return 1; }
    chat_address() { return 1; }
    "$2" 2>&1' _ "${MOTD}" "$1" 2>/dev/null
}
setup_banners_stay_quiet_about_lca() {
  local b out
  # banner_no_model keeps the path half and drops the "Install the name" half:
  # it ends with "Finish it: sudo setup.sh" of its own, so the full note
  # printed that command twice two lines apart — but its last row is
  # "Details: lca check", so going silent would leave its own advice unusable.
  out="$(banner_render banner_no_model)"
  if [[ "$(grep -c 'setup\.sh' <<<"${out}")" != "1" ]]; then
    printf 'banner_no_model names setup.sh %s times; it should say it once\n' \
      "$(grep -c 'setup\.sh' <<<"${out}")" >&2
    return 1
  fi
  grep -q 'NOT on PATH' <<<"${out}" || {
    echo 'banner_no_model dropped the path note, and its own last row says "lca check"' >&2
    return 1; }
  for b in banner_installing banner_stalled; do
    out="$(banner_render "${b}")"
    ! grep -q 'NOT on PATH' <<<"${out}" || {
      printf '%s tells the user to run setup.sh while setup is the thing that is wrong\n' "${b}" >&2
      return 1; }
  done
  # ...and the ready banner must STILL say it. This is the assertion the first
  # implementation failed.
  out="$(banner_render banner_ready)"
  grep -q 'NOT on PATH' <<<"${out}" || {
    echo 'the ready banner went quiet about a missing lca — the one place it matters' >&2
    return 1; }
}
check "...but the two setup banners stay quiet, and the ready one does not" \
  setup_banners_stay_quiet_about_lca

echo "# ...and no failure message may tell a systemd-less box to 'systemctl start docker'"
# Same family as the tailscale rule above, found the same way — by standing on
# the box. This container has systemctl on PATH and systemd nowhere near PID 1:
#
#   $ systemctl start docker
#   System has not been booted with systemd as init system (PID 1). Can't operate.
#   Failed to connect to bus: Host is down
#
# Five messages recommended exactly that, unconditionally: webui.sh, restore.sh,
# apply.sh, install_webui.sh and check-system.sh. Every one of them fires at the
# moment the daemon is already down, i.e. the only moment the reader needs the
# command to work. systemd_available() has been in lib.sh the whole time and
# answers correctly here; the messages simply never asked it.
#
# Three assertions, because each one alone passes a different way of breaking it:
#   1. behaviour — the helper actually branches (a helper that ignores its
#      condition passes any amount of grepping for systemd_available);
#   2. no literal outside the helper — a sixth message added later, or one of
#      the five edited back, is caught;
#   3. the call sites are still there — deleting '$(docker_start_hint)' from all
#      five leaves no literal to find, so (2) alone would go green on it.
docker_hint_for() {  # yes|no -> the hint that host is given
  # Stubs AFTER the source, and the argument read into a variable first: inside
  # a function "$2" is the FUNCTION's argument. Both directions stubbed rather
  # than trusting the host, so this reads the same in CI as it does here.
  bash -c 'source "$1" >/dev/null 2>&1
    SD="$2"
    if [[ "${SD}" == "yes" ]]; then systemd_available() { return 0; }
    else systemd_available() { return 1; }; fi
    docker_start_hint' _ "${REPO}/scripts/lib.sh" "$1" 2>/dev/null
}
docker_advice_is_conditional() {
  local out bad=0 files=() f body callers=0
  out="$(docker_hint_for yes)"
  grep -q 'systemctl start docker' <<<"${out}" || {
    printf 'a systemd host is no longer told the command that works there: %s\n' "${out}" >&2
    bad=1; }
  # 'systemctl start', not the bare word: the no-systemd text names systemctl on
  # purpose — "there is no systemd here, so systemctl cannot do it" — because a
  # reader who already tried it deserves to know why it failed. The bare-word
  # form was the first draft and it failed on a clean tree, flagging the fix for
  # explaining itself. What must not appear is the imperative.
  out="$(docker_hint_for no)"
  if grep -q 'systemctl start' <<<"${out}" || [[ -z "${out}" ]]; then
    printf 'a host without systemd is handed systemctl anyway: %s\n' "${out}" >&2
    bad=1
  fi
  [[ "$(docker_hint_for no)" != "$(docker_hint_for yes)" ]] || {
    echo 'docker_start_hint gives both hosts the same answer — it stopped branching' >&2
    bad=1; }
  # ...and nothing outside the helper may hardcode it. Comments stripped: the
  # helper's own note quotes the command three times, and the first draft of
  # this gate flagged lib.sh for its own explanation of the fix. The helper's
  # body is then cut out by name, so the one legitimate copy is not a special
  # case in the pattern.
  mapfile -t files < <(printf '%s\n' "${REPO}"/*.sh "${REPO}"/scripts/*.sh \
                                     "${REPO}"/deploy/*.sh "${REPO}"/bin/lca)
  (( ${#files[@]} >= 20 )) || {
    printf 'the file sweep found only %s scripts — this gate stopped watching\n' \
      "${#files[@]}" >&2
    return 1
  }
  for f in "${files[@]}"; do
    body="$(sed 's/#.*//' "${f}" | sed '/^docker_start_hint() {$/,/^}$/d')"
    if grep -q 'systemctl start docker' <<<"${body}"; then
      # shellcheck disable=SC2016  # naming the call site to write, not running it
      printf '%s hardcodes "systemctl start docker" — use $(docker_start_hint)\n' \
        "${f##*/}" >&2
      bad=1
    fi
    # if/fi rather than 'A && B': CONTRIBUTING trap #2, and errexit reads an
    # AND-list's tail differently from a plain command.
    #
    # Either helper counts. docker_unreachable_advice wraps this one to add the
    # "what works for THIS USER" half, so a message that routes through it is
    # still asking the host how — but only as long as that wrapper really does
    # call it, which is asserted below rather than assumed. Without that, moving
    # messages behind the wrapper would be a way to lose the question quietly.
    if [[ "${f}" != */lib.sh ]] \
       && grep -qE 'docker_start_hint|docker_unreachable_advice' <<<"${body}"; then
      callers=$((callers + 1))
    fi
  done
  local wrapper
  wrapper="$(sed -n '/^docker_unreachable_advice() {$/,/^}$/p' "${REPO}/scripts/lib.sh")"
  [[ -n "${wrapper}" ]] || {
    echo 'docker_unreachable_advice is gone, and messages were routed through it' >&2
    bad=1
  }
  if [[ -n "${wrapper}" ]] && ! grep -q 'docker_start_hint' <<<"${wrapper}"; then
    echo 'docker_unreachable_advice no longer asks docker_start_hint, so every message behind it stopped asking the host how' >&2
    bad=1
  fi
  # webui.sh, restore.sh, scripts/apply.sh, scripts/install_webui.sh and
  # check-system.sh. Counted, so silently dropping the hint from a message is a
  # failure rather than one fewer literal to find.
  (( callers >= 5 )) || {
    printf 'only %s scripts still ask docker_start_hint; five messages need it\n' \
      "${callers}" >&2
    bad=1
  }
  return "${bad}"
}
check "every 'start Docker' message asks the host how, instead of assuming systemd" \
  docker_advice_is_conditional

echo "# ...and none may offer root a remedy that only works for somebody else"
# docker_start_hint answers "what works on this host". The second half of the
# same question is "what works for this user", and three messages answered it
# with a fixed list. Measured on this box with the daemon genuinely down and
# the command run as root:
#
#   [FAIL] Cannot reach the Docker daemon as 'root'. Start it (...), or add
#          yourself to the docker group (sudo .../install_docker.sh) and log
#          out/in, or re-run this as root.
#
# Group membership is not consulted for uid 0 and root cannot re-run anything
# as root, so two of the three remedies are for a different reader — and the
# one that can work is between them. check-system.sh has always known the rule
# ("running as root — docker group membership not needed"); these three never
# asked. Both arms driven through am_root, so neither depends on who is running
# the suite.
advice_as() {  # root | notroot -> the sentence
  bash -c '
    set -uo pipefail
    source "$1"
    AMROOT="$2"
    am_root() { [[ "${AMROOT}" == root ]]; }
    docker_unreachable_advice' _ "${REPO}/scripts/lib.sh" "$2" 2>/dev/null
}
advice_fits_the_reader() {
  local as_root_says as_user_says
  as_root_says="$(advice_as _ root)"
  as_user_says="$(advice_as _ notroot)"
  [[ -n "${as_root_says}" && -n "${as_user_says}" ]] || {
    echo 'docker_unreachable_advice printed nothing' >&2; return 1; }
  grep -qi 'docker group' <<<"${as_root_says}" && {
    printf 'root is told to join the docker group: %s\n' "${as_root_says}" >&2; return 1; }
  grep -qi 're-run this as root' <<<"${as_root_says}" && {
    printf 'root is told to re-run as root: %s\n' "${as_root_says}" >&2; return 1; }
  # ...and the remedy that DOES work must survive the trimming.
  grep -qi 'start it' <<<"${as_root_says}" || {
    printf 'root is left with no remedy at all: %s\n' "${as_root_says}" >&2; return 1; }
  # The non-root reader keeps all three: for them every one is reachable.
  local want
  for want in 'docker group' 're-run this as root' 'start it'; do
    grep -qi -- "${want}" <<<"${as_user_says}" || {
      printf 'an ordinary user loses a remedy that works for them (%s): %s\n' "${want}" "${as_user_says}" >&2
      return 1; }
  done
}
check "root is not told to join a group it is not consulted for" \
  advice_fits_the_reader
# ...and no script may write that list out by hand again.
no_script_hardcodes_docker_remedies() {
  local bad=0 seen=0 f body
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh; do
    [[ "${f}" == */lib.sh ]] && continue                 # where the helper lives
    [[ "${f}" == */install_docker.sh ]] && continue      # it does the adding
    [[ "${f}" == */check-system.sh ]] && continue        # reports membership, and already branches on root
    body="$(sed 's/^[[:space:]]*#.*//' "${f}")"
    grep -qiE 'add yourself to the docker group|re-run (this )?as root if you cannot sudo' <<<"${body}" || continue
    printf '%s hands out docker remedies without asking who is reading\n' "${f##*/}" >&2
    bad=1
  done
  # Every message about a daemon this account could not reach, counted. Three
  # said "Start it" and nothing else — restore.sh, apply.sh and uninstall.sh —
  # which is right only once you know the daemon is genuinely down. They reach
  # that line through docker_daemon_reachable, which is false for a user who
  # cannot talk to a perfectly healthy daemon, so "start it" was advice to
  # restart a service that was already running.
  #
  # check-system.sh is deliberately NOT in this list, and is the reason the
  # rule was findable at all: it says "docker daemon not responding
  # ($(docker_start_hint))" only in the branch where can_root_now was true and
  # root still got nothing, which really does mean the daemon is down. It
  # reports group membership separately, with its own root arm. It is the one
  # that got this right.
  local f2
  for f2 in "${REPO}"/webui.sh "${REPO}"/scripts/install_webui.sh \
            "${REPO}"/scripts/logs.sh "${REPO}"/restore.sh \
            "${REPO}"/scripts/apply.sh "${REPO}"/uninstall.sh; do
    grep -q 'docker_unreachable_advice' "${f2}" && seen=$((seen+1))
  done
  (( seen == 6 )) || {
    printf 'only %s of the 6 daemon-unreachable messages ask who is reading\n' "${seen}" >&2
    bad=1
  }
  return "${bad}"
}
check "no script writes the docker remedies out by hand" \
  no_script_hardcodes_docker_remedies

echo "# ...and neither may the model engine's own diagnostics"
# The same fault, in the messages that fire when inference fails — which is the
# one moment the reader has nothing else to go on. Four of them, none guarded:
#
#   check-system.sh  "did not respond (RAM? see: free -h and journalctl -u ollama)"
#   selftest.sh      "did not respond — check RAM headroom and: journalctl -u ollama"
#   setup.sh         "did not respond. Check RAM headroom and: journalctl -u ollama"
#   selftest.sh      "not reachable — try: sudo systemctl restart ollama"
#
# Where there is no systemd there is no journal for ollama either: this project
# starts the server itself under nohup and writes OLLAMA_BG_LOG. So 'lca check',
# 'lca test' and the install itself each offered one command at the moment the
# engine failed, and it returns nothing at all here.
#
# run-agent.sh and tune.sh had already learned the rule and are deliberately
# left alone — their arms differ in BEHAVIOUR, not wording (tune.sh writes the
# tuned values to .env and exits 0). That is also why this gate allow-lists
# files rather than banning the literals outright: the four sites above had no
# arm at all, and a fifth added later is the regression to catch.
ollama_hint_for() {  # HELPER yes|no-systemd -> its output
  bash -c 'source "$1" >/dev/null 2>&1
    load_env_readonly
    SD="$3"
    if [[ "${SD}" == "yes" ]]; then systemd_available() { return 0; }
    else systemd_available() { return 1; }; fi
    "$2"' _ "${REPO}/scripts/lib.sh" "$1" "$2" 2>/dev/null
}
literal_is_allow_listed() {  # LITERAL HELPER ALLOWED...
  local literal="$1" helper="$2"; shift 2
  local allowed=" $* " f rel body bad=0 found=0
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh "${REPO}"/bin/lca; do
    rel="${f#"${REPO}"/}"
    body="$(sed 's/#.*//' "${f}")"
    grep -qF "${literal}" <<<"${body}" || continue
    found=$((found + 1))
    if [[ "${allowed}" != *" ${rel} "* ]]; then
      # shellcheck disable=SC2016  # naming the call site to write, not running it
      printf '%s hardcodes "%s" — use $(%s), which asks the host\n' "${rel}" "${literal}" "${helper}" >&2
      bad=1
      continue
    fi
    # An allow-listed file still has to branch. Whole-file, and said plainly:
    # this proves the file knows about systemd, not that this particular line
    # sits inside the guard. The behavioural checks above are what prove the
    # helper works; this only stops a file being allow-listed and then losing
    # its arm entirely.
    grep -q 'systemd_available' <<<"${body}" || {
      printf '%s is allowed to name "%s" but no longer checks systemd_available at all\n' \
        "${rel}" "${literal}" >&2
      bad=1
    }
  done
  (( found > 0 )) || {
    printf 'nothing in the tree contains "%s" — this gate stopped watching\n' "${literal}" >&2
    return 1
  }
  return "${bad}"
}
ollama_advice_is_conditional() {
  local out bad=0
  # The helpers must branch, and the no-systemd arm must not hand back a
  # systemd-only command. Checked as "does it name the systemd command",
  # because the no-systemd text is allowed to mention systemd when explaining
  # why it cannot be used — the lesson from the Docker gate one section up.
  out="$(ollama_hint_for ollama_log_hint yes)"
  grep -q 'journalctl -u ollama' <<<"${out}" || {
    printf 'a systemd host is no longer pointed at the journal: %s\n' "${out}" >&2; bad=1; }
  out="$(ollama_hint_for ollama_log_hint no)"
  if grep -q 'journalctl' <<<"${out}" || [[ -z "${out}" ]]; then
    printf 'a host with no journal is sent to journalctl anyway: %s\n' "${out}" >&2; bad=1
  fi
  grep -q 'logs.sh' <<<"${out}" || {
    printf 'the no-systemd arm does not name a log this host actually has: %s\n' "${out}" >&2; bad=1; }

  out="$(ollama_hint_for ollama_restart_hint yes)"
  grep -q 'systemctl restart ollama' <<<"${out}" || {
    printf 'a systemd host is no longer told how to restart the service: %s\n' "${out}" >&2; bad=1; }
  out="$(ollama_hint_for ollama_restart_hint no)"
  if grep -q 'systemctl' <<<"${out}" || [[ -z "${out}" ]]; then
    printf 'a host without systemd is handed systemctl anyway: %s\n' "${out}" >&2; bad=1
  fi

  # scripts/lib.sh holds both helpers; logs.sh reads the journal itself behind
  # its own '! systemd_available' early return; install_ollama.sh exits 0 on
  # the no-systemd path long before either literal; run-agent.sh and tune.sh
  # each carry a full second arm.
  literal_is_allow_listed 'journalctl -u ollama' ollama_log_hint \
    scripts/lib.sh scripts/logs.sh scripts/install_ollama.sh || bad=1
  literal_is_allow_listed 'systemctl restart ollama' ollama_restart_hint \
    scripts/lib.sh scripts/install_ollama.sh run-agent.sh scripts/tune.sh || bad=1
  return "${bad}"
}
check "the engine's failure messages name a log and a restart this host has" \
  ollama_advice_is_conditional

echo "# ...and 'lca logs webui' must not blame the container for a daemon it never reached"
# run_reader's probe collapses two answers: 'docker container inspect' returns
# non-zero for a missing container and for a daemon that is not answering
# alike. Measured with the daemon unreachable while the container was running
# and serving:
#
#   [warn] Could not read logs for container 'open-webui'
#          (is it created? try: lca webui status).
#
# It is created, it is running, and 'lca webui status' needs the same daemon —
# so the command people run when things are broken sent them in a circle. The
# same fault docker_daemon_reachable exists for, and the same one uninstall.sh
# had two commits ago.
#
# Driven with a stubbed 'docker' that fails everything, so 'have docker' is
# true and the daemon is unreachable on every machine — not just on one where
# docker happens to be installed or absent.
logs_webui_with_a_dead_daemon() {
  local sb="${SANDBOX}/logsweb" out
  rm -rf "${sb}"; make_stub_dir "${sb}/stub"
  printf '#!/bin/sh\nexit 1\n' > "${sb}/stub/docker"
  chmod +x "${sb}/stub/docker"
  # shellcheck disable=SC2031  # a one-command env prefix, not a subshell edit
  out="$(PATH="${sb}/stub:${PATH}" timeout 60 bash "${REPO}/scripts/logs.sh" webui 2>&1 || true)"
  rm -rf "${sb}"
  printf '%s' "${out}"
}
logs_does_not_blame_the_container() {
  local out
  out="$(logs_webui_with_a_dead_daemon)"
  grep -qi 'is it created' <<<"${out}" && {
    printf 'a daemon that could not be reached is reported as a container that may never have existed: %s\n' "${out}" >&2
    return 1; }
  grep -qi 'daemon could not be reached' <<<"${out}" || {
    printf 'the daemon problem is not named at all: %s\n' "${out}" >&2
    return 1; }
  # ...and it must say the silence proves nothing about the chat app, which is
  # the whole correction.
  grep -qi 'says nothing about whether it is running' <<<"${out}" || {
    printf 'it does not say the result is silent about the chat app: %s\n' "${out}" >&2
    return 1; }
}
check "'lca logs webui' says the daemon was unreachable, not that the container is missing" \
  logs_does_not_blame_the_container

echo "# ...and 'pull the model' must know whether the kill switch will allow it"
# Seven messages tell someone their model is missing. THREE asked first —
# check-system.sh, restore.sh and run-agent.sh each wrote the same two-arm
# branch by hand — and four did not: 'lca ask', 'lca speed', 'lca test' and
# prompt-bench.sh all said "pull it with: ollama pull X" flat out. With netmode
# OFFLINE that command cannot reach the registry, and the one thing standing
# between the reader and their model goes unmentioned. Being correct in three
# places is how the fourth is not, which is the argument docker_daemon_reachable
# already makes in its own header.
#
# All seven route through pull_advice now, including the three that were right,
# which is what lets this gate be BLANKET instead of an allow-list — the shape
# the two gates above had to settle for. lib.sh is the single exception: it
# holds the helper, and pull_model actually runs the command.
pull_advice_for() {  # online|offline -> the sentence
  bash -c 'source "$1" >/dev/null 2>&1
    load_env_readonly
    if [[ "$2" == "offline" ]]; then net_blocked() { return 0; }
    else net_blocked() { return 1; }; fi
    pull_advice "a-model:7b"' _ "${SANDBOX}/scripts/lib.sh" "$1" 2>/dev/null
}
pull_advice_checks_the_kill_switch() {
  local out bad=0 f rel body
  out="$(pull_advice_for online)"
  if ! grep -q 'ollama pull a-model:7b' <<<"${out}" || grep -qi 'kill switch' <<<"${out}"; then
    printf 'an online machine no longer just gets the pull command: %s\n' "${out}" >&2
    bad=1
  fi
  out="$(pull_advice_for offline)"
  if ! grep -qi 'kill switch' <<<"${out}" || ! grep -q 'netmode.sh online' <<<"${out}"; then
    printf 'an offline machine is told to pull with no mention of the kill switch: %s\n' "${out}" >&2
    bad=1
  fi
  # The pull command still has to be there — the reader needs it for after they
  # turn the switch off, and dropping it would pass a "mentions the switch" test.
  grep -q 'ollama pull a-model:7b' <<<"${out}" || {
    printf 'the offline sentence never names the command to run afterwards: %s\n' "${out}" >&2
    bad=1; }
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh "${REPO}"/bin/lca; do
    rel="${f#"${REPO}"/}"
    [[ "${rel}" == "scripts/lib.sh" ]] && continue
    body="$(sed 's/#.*//' "${f}")"
    grep -q 'ollama pull' <<<"${body}" || continue
    # shellcheck disable=SC2016  # naming the call site to write, not running it
    printf '%s names "ollama pull" itself — use $(pull_advice MODEL), which says when the kill switch is in the way\n' \
      "${rel}" >&2
    bad=1
  done
  return "${bad}"
}
check "...and every 'your model is missing' message routes through pull_advice" \
  pull_advice_checks_the_kill_switch

echo "# a dead engine on a working box is not 'the install stopped before it finished'"
# install_state cannot tell those apart: both are a verdict-less log. Its own
# header comment describes the second case — an interrupted first boot on a
# machine where everything works — and main() still chose banner_stalled for it
# the moment ollama stopped.
#
# Measured on this machine with ollama killed: "the install stopped before it
# finished (nothing written to the log for 144 h) · Finish it: sudo setup.sh".
# A 20-30 minute re-run, offered for a process that had died a minute earlier,
# on a box whose stack had been serving for days.
motd_headline_for() {  # STATE  AIDER(yes|no) -> the headline
  # Values into variables BEFORE the stubs: inside a function "$2" is the
  # FUNCTION's argument, not the script's, and the first version of this probe
  # returned empty for all three cases because of it.
  bash -c 'source "$1" >/dev/null 2>&1; load_env_readonly
    ST="$2"; AI="$3"
    install_state() { printf "%s" "${ST}"; }
    engine_up() { return 1; }
    # BOTH directions stubbed. Leaving the "present" case to the real
    # aider_bin() made the gate depend on whether .venv exists — true on this
    # machine, false in the unit-test CI job, which never runs
    # install_python.sh. It passed here and turned CI red, which is the same
    # environment-dependence that made guarded_ports fail on a real install
    # earlier in this branch. /bin/sh is an executable that always exists.
    if [[ "${AI}" == "no" ]]; then aider_bin() { printf "/nonexistent/aider\n"; }
    else aider_bin() { printf "/bin/sh\n"; }; fi
    main 2>&1' _ "${MOTD}" "$1" "$2" 2>/dev/null | grep -m1 'local-code-agent'
}
dead_engine_is_not_a_stalled_install() {
  local out
  # The product is installed: the engine is the problem, and the fix is a
  # minute of looking at ollama, not half an hour of setup.
  out="$(motd_headline_for stalled yes)"
  grep -q 'model engine is not running' <<<"${out}" || {
    printf 'a working box with a dead engine is told its install stopped: %s\n' "${out}" >&2
    return 1; }
  # ...and the genuinely-abandoned install must still be told to finish.
  out="$(motd_headline_for stalled no)"
  grep -q 'install stopped before it finished' <<<"${out}" || {
    printf 'an install that really did stop partway no longer says so: %s\n' "${out}" >&2
    return 1; }
}
check "a stalled log with the agent installed means the engine died, not the install" \
  dead_engine_is_not_a_stalled_install

echo "# ...and a chat app that is DOWN is louder than one that is merely stale"
# chat_stale_row warns when the chat is up but running an older assistant. The
# banner said nothing at all when it was simply not answering: headline still
# "ready", and the row above still handing out a phone URL. Measured by
# stopping the container — 'lca check' reported it twice with the fix, and the
# one screen you get without asking offered the link anyway.
motd_chat_down_row() {  # answering | down -> the rendered row
  bash -c 'source "$1" >/dev/null 2>&1; load_env_readonly
    ANS="$2"
    ENABLE_WEBUI=true; SKIP_DOCKER=false
    have() { [[ "$1" == "curl" ]]; }
    quick() { [[ "${ANS}" == "answering" ]]; }
    chat_down_row' _ "${MOTD}" "$1" 2>/dev/null
}
banner_reports_a_chat_that_is_down() {
  local down up
  down="$(motd_chat_down_row down)"
  up="$(motd_chat_down_row answering)"
  [[ -n "${down}" ]] || {
    echo 'the banner says "ready" and offers a chat URL that answers nothing' >&2
    return 1; }
  grep -q 'webui start' <<<"${down}" || {
    echo 'the banner reports the chat down without naming the command that starts it' >&2
    return 1; }
  [[ -z "${up}" ]] || {
    echo 'the banner nags about a chat app that is answering perfectly well' >&2
    return 1; }
  # row() pads labels to 20; a longer one eats its own separator and the value
  # stops lining up with every other row. The first version was 21.
  local label
  label="$(sed -e 's/^   //' -e 's/  .*//' <<<"${down}")"
  (( ${#label} <= 20 )) || {
    printf 'the label "%s" is %s characters and breaks the banner alignment\n' \
      "${label}" "${#label}" >&2
    return 1; }
}
check "the banner says when the chat app is not answering, and is quiet when it is" \
  banner_reports_a_chat_that_is_down
# ...and it has to be drawn, not merely defined.
ready_banner_draws_the_chat_down_row() {
  awk '/^banner_ready\(\) \{/ { inb = 1 }
       inb && /chat_down_row/  { found = 1 }
       inb && /^\}/            { exit }
       END { exit !found }' <<<"$(sed 's/#.*//' "${REPO}/scripts/motd.sh")"
}
check "...and the ready banner actually draws it" \
  ready_banner_draws_the_chat_down_row

echo "# ...and whether the chat app is still answering with an older assistant"
# The container is created with the assistant's instructions baked in, so a
# 'git pull' that fixes the assistant does not reach a running one and nothing
# restarts it. On such a box every other line of this banner is true — engine
# up, model pulled, URL live — which is exactly why "ready" was the last thing
# the one real bug reporter saw before asking the chat to build an app and
# getting a JSON tool-call blob back. 'lca check' knew. 'lca test' knew. The
# only screen you get without asking for it did not.
if have jq; then
  motd_stale() {   # stubbed live prompt value -> "stale" | "no"
    # Same shape as motd_missing above, and the same reason for the uppercase
    # stub variable: webui_prompt_drifted declares its own 'local live', and
    # bash's dynamic scoping would hand the stub that empty one.
    local out
    out="$(bash -c '
      source "$1" >/dev/null 2>&1
      load_env_readonly
      ENABLE_WEBUI="$3"; SKIP_DOCKER=false
      LIVE="$2"
      if [[ "${LIVE}" == "__unreadable__" ]]; then webui_container_env() { return 1; }
      else webui_container_env() {
             [[ "$1" == "DEFAULT_MODEL_PARAMS" ]] || return 1
             printf "%s" "${LIVE}"
           }; fi
      chat_stale_row' _ "${MOTD}" "$1" "${2:-true}" 2>/dev/null || true)"
    if grep -q 'OUT OF DATE' <<<"${out}"; then echo stale; else echo no; fi
  }
  stale_is() { [[ "$(motd_stale "$2" "${3:-true}")" == "$1" ]]; }
  check "a container holding today's prompt draws no warning" \
    stale_is no    "$(lca_system_prompt | jq -Rsc '{system: .}')"
  check "a container holding an older prompt IS called out on the banner" \
    stale_is stale "$(printf 'you are a helpful assistant' | jq -Rsc '{system: .}')"
  # "Could not look" is not "out of date". A banner that warned whenever docker
  # was unreadable would be crying wolf at every login on a box with no chat
  # app at all, and a banner people learn to skip is worth nothing.
  check "an unreadable container draws no warning" \
    stale_is no    '__unreadable__'
  check "a container created without the setting draws no warning" \
    stale_is no    ''
  # Switched off in .env: there is no chat app to be out of date.
  check "no warning when the chat app is disabled" \
    stale_is no    "$(printf 'you are a helpful assistant' | jq -Rsc '{system: .}')" false
else
  echo "skip - jq not installed, cannot exercise the banner's staleness warning"
fi
# ...and the ready banner has to draw it, or the probe is decoration — the same
# trap as model_missing, which is why that check exists directly above.
ready_banner_warns_about_a_stale_chat() {
  awk '/^banner_ready\(\) \{/ { inb = 1 }
       inb && /chat_stale_row/ { found = 1 }
       inb && /^\}/            { exit }
       END { exit !found }' <<<"$(sed 's/#.*//' "${REPO}/scripts/motd.sh")"
}
check "the ready banner draws the stale-chat warning" \
  ready_banner_warns_about_a_stale_chat
# The banner runs on EVERY login, so this one probe must be bounded far tighter
# than a health check. webui_container_env is bounded (proved above); this is
# the caller actually asking for the short leash.
motd_bounds_the_docker_read() {
  awk '/^chat_stale_row\(\) \{/ { inb = 1 }
       inb && /LCA_INSPECT_TIMEOUT=[0-9]/ { found = 1 }
       inb && /^\}/ { exit }
       END { exit !found }' <<<"$(sed 's/#.*//' "${REPO}/scripts/motd.sh")"
}
echo "# the three small helpers 'make coverage' had never seen run"
# apt_get and the two GPU probes cannot run here — one installs packages, two
# need a card CI does not have either. These three can, and each has a failure
# mode with teeth: webui_url() is where every health check and the banner's new
# chat probe point, webui_responds() is what 'webui.sh start' waits on before
# declaring success, and require_cmd() is what turns a missing dependency into
# a sentence instead of a raw error later on.
url_for() { ( WEBUI_PORT="$1"; webui_url ); }
check "webui_url uses the configured port" test "$(url_for 8080)" = "http://127.0.0.1:8080"
check "...and defaults to 3000 when unset" test "$( ( unset WEBUI_PORT; webui_url ) )" = "http://127.0.0.1:3000"
# A plain function, not 'bash -c': a fresh shell has never sourced lib.sh, so
# url_for would be undefined there. Written the other way first and it failed
# exactly like that — the stub-scope trap this file keeps re-learning.
url_is_loopback() { [[ "$(url_for 3000)" == http://127.0.0.1:* ]]; }
check "...and always asks loopback, never the tailscale address" url_is_loopback
webui_responds_probes_health() {
  # The stub writes to a FILE. webui_responds sends curl's stdout AND stderr to
  # /dev/null itself, so a stub that printed would be swallowed and this check
  # would pass on an empty string forever — which is how it first behaved.
  local spy="${SANDBOX}/curl-args" seen
  rm -f "${spy}"
  ( WEBUI_PORT=3000
    curl() { printf '%s\n' "$*" > "${spy}"; }
    webui_responds || true )
  seen="$(cat "${spy}" 2>/dev/null || true)"
  [[ -n "${seen}" ]] || { echo 'webui_responds never called curl at all' >&2; return 1; }
  grep -q '/health' <<<"${seen}" || {
    printf 'webui_responds no longer asks /health: %s\n' "${seen}" >&2; return 1; }
  grep -q -- '--max-time' <<<"${seen}" || {
    echo 'webui_responds has no timeout, so a wedged port hangs whatever waits on it' >&2
    return 1; }
}
check "webui_responds asks /health, with a timeout" webui_responds_probes_health
# require_cmd must DIE on a missing tool, not merely return non-zero.
require_cmd_rc() {  # COMMAND -> the status require_cmd exits with
  # Read AFTER the subshell rather than printed inside it: require_cmd calls
  # die, die exits, and an echo placed after it never runs.
  local rc=0
  ( require_cmd "$1" ) >/dev/null 2>&1 || rc=$?
  printf '%s' "${rc}"
}
check "require_cmd passes a command that exists" test "$(require_cmd_rc sh)" = "0"
check "...and dies on one that does not" test "$(require_cmd_rc no-such-command-xyz)" = "1"

check "the banner asks docker with a short leash, not the default one" \
  motd_bounds_the_docker_read

echo "# the login banner must never write anything"
# It runs as ROOT on every SSH login. load_env creates .env from .env.example
# when missing, so the plain loader would leave a root-owned .env behind merely
# because someone logged in — and the next non-root setup.sh could not write it.
motd_creates_nothing() {
  local dir="${SANDBOX}/noenv"
  rm -rf "${dir}"; mkdir -p "${dir}/scripts"
  cp "${REPO}/scripts/lib.sh" "${REPO}/scripts/motd.sh" "${dir}/scripts/"
  cp "${REPO}/.env.example" "${dir}/"
  LCA_LOG="${SANDBOX}/no-such-log" "${dir}/scripts/motd.sh" >/dev/null 2>&1 || true
  [[ ! -e "${dir}/.env" ]]
}
check "motd.sh does not create .env" motd_creates_nothing
# ...while the ordinary loader must still do exactly what it always did.
load_env_still_creates() {
  local dir="${SANDBOX}/withenv"
  rm -rf "${dir}"; mkdir -p "${dir}/scripts"
  cp "${REPO}/scripts/lib.sh" "${dir}/scripts/"
  cp "${REPO}/.env.example" "${dir}/"
  bash -c 'source "$1/scripts/lib.sh"; load_env' _ "${dir}" >/dev/null 2>&1 || true
  [[ -e "${dir}/.env" ]]
}
check "load_env still creates .env (the read-only mode is opt-in)" load_env_still_creates

echo "# the banner's verdict markers must match the lines actually printed"
# motd.sh classifies on prefixes of setup.sh's and do-user-data.sh's verdict
# lines. Reword either end and the banner silently reports 'running' forever.
motd_markers_are_real() {
  local marker bad=0
  for marker in "SETUP COMPLETE" "SETUP FINISHED WITH ERRORS" "FIRST-BOOT INSTALL FAILED"; do
    grep -qF "${marker}" "${REPO}/scripts/motd.sh" || {
      printf 'motd.sh no longer looks for: %s\n' "${marker}" >&2; bad=1; continue
    }
    grep -qF "${marker}" "${REPO}/setup.sh" || grep -qF "${marker}" "${REPO}/deploy/do-user-data.sh" || {
      printf 'nothing ever prints the marker motd.sh classifies on: %s\n' "${marker}" >&2; bad=1
    }
  done
  return "${bad}"
}
check "every marker motd.sh matches on is really printed" motd_markers_are_real

# ...and every state the banner can PRINT must be in the table that explains
# them. docs/TROUBLESHOOTING.md lists what each banner means, by hand, and
# adding "engine running, but model X is NOT downloaded" to motd.sh left that
# table describing six states out of seven — with its 'ready' row still saying
# "Ollama answered. This wins over anything the log says", which had stopped
# being the whole rule.
#
# The list is read out of motd.sh, so the next state is covered without editing
# this. Each headline is cut at the first expansion, bracket or dash, which is
# the part that stays constant, and whitespace is normalised because the banner
# pads for alignment and prose does not.
banner_states_are_documented() {
  local doc line stable bad=0 seen=0
  doc="$(tr -s '[:space:]' ' ' < "${REPO}/docs/TROUBLESHOOTING.md")"
  while IFS= read -r line; do
    stable="${line%%\$\{*}"
    stable="${stable%%(*}"
    stable="${stable%%—*}"
    stable="$(tr -s '[:space:]' ' ' <<<"${stable}")"
    stable="${stable# }"; stable="${stable% }"
    [[ -n "${stable}" ]] || continue
    seen=$(( seen + 1 ))
    grep -qF -- "${stable}" <<<"${doc}" || {
      printf 'the banner can print "%s" but TROUBLESHOOTING.md does not explain it\n' \
        "${stable}" >&2
      bad=1
    }
  done < <(grep -oE 'headline "[^"]*"' "${REPO}/scripts/motd.sh" \
             | sed -E 's/^headline "//; s/"$//' | sort -u)
  # Same trap as everywhere else in this file: renaming headline() left this
  # finding no states at all and reporting ok. Measured.
  (( seen >= 3 )) || {
    printf 'only %s banner state(s) found in motd.sh — this stopped watching them\n' "${seen}" >&2
    return 1
  }
  return "${bad}"
}
check "every banner state is explained in TROUBLESHOOTING.md" \
  banner_states_are_documented

# do-user-data.sh runs before the clone exists, so it cannot source lib.sh and
# keeps its own copy of the log path. If the two drift, the banner watches a
# file the installer never writes and reports 'none' during every install.
log_path_agrees() {
  local from_lib from_userdata
  # Matched without a literal '${...}' in the pattern: ShellCheck reads that
  # inside single quotes as a variable someone forgot to expand (SC2016).
  from_lib="$(sed -n 's|^SETUP_LOG=.*:-\(/[^}]*\)}"$|\1|p' "${REPO}/scripts/lib.sh")"
  from_userdata="$(sed -n 's|^LOG_FILE=.*:-\(/[^}]*\)}"$|\1|p' "${REPO}/deploy/do-user-data.sh")"
  [[ -n "${from_lib}" && -n "${from_userdata}" ]] || {
    echo "could not read the log path out of one of the two files" >&2; return 1
  }
  [[ "${from_lib}" == "${from_userdata}" ]] || {
    printf 'log path drift: lib.sh=%s do-user-data.sh=%s\n' "${from_lib}" "${from_userdata}" >&2; return 1
  }
}
check "lib.sh and do-user-data.sh agree on the install log path" log_path_agrees

# run-parts --lsbsysinit (how pam_motd invokes it) skips any filename with a
# dot in it, so installing this as '99-local-code-agent.sh' would silently
# never run.
motd_filename_is_runnable() {
  local path base
  path="$(sed -n 's|^MOTD_FILE="\(.*\)"$|\1|p' "${REPO}/scripts/lib.sh")"
  [[ -n "${path}" ]] || { echo "could not read MOTD_FILE from lib.sh" >&2; return 1; }
  base="${path##*/}"
  [[ -n "${base}" && "${base}" != *.* ]]
}
check "the installed banner filename has no dot (run-parts would skip it)" \
  motd_filename_is_runnable

echo "# setup.sh must actually run every installer that exists"
# An installer that nothing calls is worse than a missing one: it looks like
# coverage, passes ShellCheck, and is only discovered when a user asks why the
# thing it installs is not there. Adding scripts/install_foo.sh and forgetting
# the line in setup.sh is a one-keystroke mistake with no other symptom.
setup_runs_every_installer() {
  local f name bad=0 found=0
  for f in "${REPO}"/scripts/install_*.sh; do
    [[ -e "${f}" ]] || continue
    found=1
    name="$(basename "${f}")"
    grep -qF "scripts/${name}" "${REPO}/setup.sh" || {
      printf 'setup.sh never invokes scripts/%s\n' "${name}" >&2
      bad=1
    }
  done
  # No installers found would otherwise "pass" without checking anything.
  (( found == 1 )) || { echo "no scripts/install_*.sh found at all" >&2; return 1; }
  return "${bad}"
}
check "setup.sh invokes every scripts/install_*.sh" setup_runs_every_installer

echo "# the install's final verdict line must read the same everywhere"
# docs/YOUR-TURN.md and docs/DO.md tell the user to watch the log for exactly
# this line, and deploy/do-user-data.sh documents it as one of its three
# outcomes. Reword it in setup.sh alone and the instruction becomes "wait for a
# line that never comes" — a failure mode that looks like a hung install.
# setup.sh is the single source; the others must quote it verbatim.
verdict_line_is_consistent() {
  local line f bad=0
  line="$(sed -n 's/^SETUP_DONE_LINE="\(.*\)"$/\1/p' "${REPO}/scripts/lib.sh")"
  # Without this guard an empty extraction makes every 'grep -qF ""' below
  # match, and the test passes while checking nothing.
  [[ -n "${line}" ]] || { echo "could not read SETUP_DONE_LINE from lib.sh" >&2; return 1; }
  for f in docs/YOUR-TURN.md docs/DO.md deploy/do-user-data.sh; do
    grep -qF -- "${line}" "${REPO}/${f}" || {
      printf '%s does not contain the verdict line from setup.sh: %s\n' "${f}" "${line}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "the SETUP COMPLETE line matches across lib.sh and the docs" \
  verdict_line_is_consistent

# ...and the first-boot script has to REACH one of those lines, including when
# the clone worked but brought back the wrong tree.
#
# install.sh checks this — "observed here by accident, cloning a stale local
# 'main' that held only a README" — and do-user-data.sh, whose header opens
# with an "EDIT ME if you forked the repository" block, did not. Measured
# against a repository holding one README, apt stubbed:
#
#   .../target/scripts/motd.sh: No such file or directory
#   (could not install the login banner — continuing)
#   .../target/setup.sh: No such file or directory
#   === setup reported problems — its verdict line is above ===
#
# It points at a verdict line that does not exist, because setup.sh never ran,
# and NOT ONE of the three lines its own header promises appears in the log.
# docs/YOUR-TURN.md step 2 tells people to watch that log for a definitive
# answer; a wrong fork is exactly when they need one.
#
# Driven for real against a local git repo. apt-get is stubbed because this
# script installs packages unconditionally; everything else — the clone, the
# check, the verdict — is the real thing.
DUD_SB="${SANDBOX}/dud"
dud_run() {  # REPO_DIR -> the log contents, then "rc=N"
  local rc=0 out
  rm -rf "${DUD_SB}/target" "${DUD_SB}/log"
  # shellcheck disable=SC2031  # a one-command env prefix, not a subshell edit
  out="$(PATH="${DUD_SB}/stub:${PATH}" LCA_REPO_URL="$1" LCA_DIR="${DUD_SB}/target" \
         LCA_LOG="${DUD_SB}/log" LCA_RUN_SETUP=false \
         timeout 120 bash "${REPO}/deploy/do-user-data.sh" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}
first_boot_refuses_a_tree_with_no_setup() {
  local out
  make_stub_dir "${DUD_SB}/stub"; mkdir -p "${DUD_SB}/notours"
  printf '#!/bin/sh\nexit 0\n' > "${DUD_SB}/stub/apt-get"
  chmod +x "${DUD_SB}/stub/apt-get"
  if [[ ! -d "${DUD_SB}/notours/.git" ]]; then
    ( cd "${DUD_SB}/notours" && git init -q . \
      && echo '# some other project' > README.md \
      && git -c user.email=t@t -c user.name=t add -A \
      && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  fi
  out="$(dud_run "${DUD_SB}/notours")"
  grep -q 'FIRST-BOOT INSTALL FAILED' <<<"${out}" || {
    printf 'a clone with no setup.sh gives no verdict at all — the log just stops, which reads as "still working":\n%s\n' "${out}" >&2
    return 1; }
  grep -q 'no setup.sh' <<<"${out}" || {
    printf 'the verdict does not say what was actually wrong:\n%s\n' "${out}" >&2
    return 1; }
  grep -q 'rc=0' <<<"${out}" && {
    printf 'it exited 0 having installed nothing:\n%s\n' "${out}" >&2
    return 1; }
  # ...and it must stop BEFORE the banner install, or a first boot pointed at
  # the wrong repository leaves an /etc/update-motd.d symlink into it.
  ! grep -q 'Installing the login banner' <<<"${out}" || {
    printf 'it went on to install a login banner out of a tree that is not this project:\n%s\n' "${out}" >&2
    return 1; }
}
check "the first-boot script refuses a clone that is not this project" \
  first_boot_refuses_a_tree_with_no_setup

echo "# the install's verdict must carry an exit status, not just a line"
# setup.sh printed "SETUP FINISHED WITH ERRORS" and then exited 0. That made
# deploy/do-user-data.sh's failure branch — and its comment claiming setup
# "exits non-zero on a partial failure" — dead code: a droplet whose model
# never downloaded reported a successful first-boot install, and any
# automation branching on the exit code was misled. A verdict nobody can act
# on programmatically is not a verdict.
verdict_ok_exits_zero()  { setup_verdict true  >/dev/null 2>&1; }
verdict_bad_exits_one()  { ! setup_verdict false >/dev/null 2>&1; }
check "setup_verdict true exits 0"  verdict_ok_exits_zero
check "setup_verdict false exits non-zero" verdict_bad_exits_one
# ...and each must print the line the docs and the login banner look for.
verdict_prints() {
  local want="$1" flag="$2" out
  out="$(setup_verdict "${flag}" 2>&1 || true)"
  grep -qF -- "${want}" <<<"${out}" || {
    printf 'setup_verdict %s printed: %s\n' "${flag}" "${out}" >&2; return 1
  }
}
check "the success verdict prints SETUP COMPLETE" \
  verdict_prints "SETUP COMPLETE — local-code-agent is ready." true
check "the failure verdict prints SETUP FINISHED WITH ERRORS" \
  verdict_prints "SETUP FINISHED WITH ERRORS" false
# setup.sh must actually USE it — printing the line by hand again would
# reintroduce exactly the bug above while leaving these tests green.
setup_uses_verdict() {
  grep -qE '^[[:space:]]*setup_verdict "\$\{setup_ok\}"' "${REPO}/setup.sh" || {
    echo "setup.sh no longer ends on setup_verdict" >&2; return 1
  }
  # And nothing may re-hardcode a verdict line outside lib.sh.
  ! grep -qF 'SETUP FINISHED WITH ERRORS' "${REPO}/setup.sh"
}
check "setup.sh reports through setup_verdict" setup_uses_verdict

# ...on EVERY failing exit, not only the orderly one at the end of main.
#
# Three things read setup.sh's output rather than its status: do-user-data.sh
# promises the log "always ends with exactly one of three lines" and then says
# "its verdict line is above"; docs/YOUR-TURN.md step 2 tells the user to watch
# for one of two lines; and motd.sh's install_state greps for them. A die() —
# or any of the nine installer scripts main runs bare under 'set -e' — printed
# none of the three. Measured on a log ending in "Model pull failed": with the
# verdict line install_state says 'failed'; without it, 'running' for fifteen
# minutes and 'stalled' after that, so the banner told someone whose install
# was over that it was still going.
#
# Driven, not grepped. The bug is about an exit path nobody wrote code for, and
# a scan for the word 'trap' would pass on a trap that fires on the wrong
# statuses. So: run the real setup.sh in a throwaway copy of the repo whose
# first installer is stubbed to fail. Nothing here needs root or a network —
# setup.sh dies at that stub, three steps in.
SETUP_SB="${SANDBOX}/setupfail"
mkdir -p "${SETUP_SB}/scripts"
cp "${REPO}/setup.sh" "${SETUP_SB}/setup.sh"
cp "${REPO}/scripts/lib.sh" "${SETUP_SB}/scripts/lib.sh"
cp "${REPO}/.env.example" "${SETUP_SB}/.env.example"
printf '#!/usr/bin/env bash\nexit 9\n' > "${SETUP_SB}/scripts/install_dependencies.sh"
chmod +x "${SETUP_SB}/setup.sh" "${SETUP_SB}/scripts/install_dependencies.sh"
setup_fail_rc=0
setup_fail_out="$(cd "${SETUP_SB}" && ./setup.sh </dev/null 2>&1)" || setup_fail_rc=$?
setup_help_rc=0
setup_help_out="$(cd "${SETUP_SB}" && ./setup.sh --help </dev/null 2>&1)" || setup_help_rc=$?

failing_setup_prints_verdict() {
  grep -qF 'SETUP FINISHED WITH ERRORS' <<<"${setup_fail_out}" || {
    printf 'setup.sh died with no verdict line. Its output was:\n%s\n' \
      "${setup_fail_out}" >&2
    return 1
  }
}
# The status is half the contract: do-user-data.sh and update.sh branch on it,
# and a trap that swallowed the installer's code would report a generic 1 for a
# specific failure.
failing_setup_keeps_status() { [[ "${setup_fail_rc}" == "9" ]]; }
# Never a verdict on a run that did nothing. '--help' exits 0 before the first
# side effect, and a trap firing there would write SETUP FINISHED WITH ERRORS
# into the log of a machine nobody had installed yet.
help_prints_no_verdict() {
  [[ "${setup_help_rc}" == "0" ]] && ! grep -qF 'SETUP ' <<<"${setup_help_out}"
}
check "a failing setup still prints its verdict"  failing_setup_prints_verdict

# The composite of the two changes above, driven end to end: a model pull that
# fails must not cost the user everything that comes after it.
#
# It used to die() there. On a droplet that ran out of disk during the
# download that meant no chat app, no Tailscale, no 'lca' command, no login
# banner, no boot services — and no 'netmode.sh harden', so Ollama was left
# installed and running with nothing in front of it. None of those steps needs
# a model. The guard is the one that matters most, and it is the assertion this
# test exists for.
#
# Every script setup.sh shells out to is a stub that records that it ran, so
# nothing here installs, downloads or firewalls anything; the shims put Ollama
# up, the model absent, and the pull refusing.
POST_SB="${SANDBOX}/pullfail"
mkdir -p "${POST_SB}/scripts" "${POST_SB}/bin"
cp "${REPO}/setup.sh" "${POST_SB}/setup.sh"
cp "${REPO}/.env.example" "${POST_SB}/.env.example"
cp "${REPO}/scripts/lib.sh" "${POST_SB}/scripts/lib.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${POST_SB}/bin/lca"
# Quoted heredocs, and the log path arrives through the environment: a stub
# needs a literal "$1" in its body, and writing that inside a single-quoted
# printf format is what ShellCheck flags as SC2016.
export RAN_LOG="${POST_SB}/ran.log"
for step_script in install_dependencies install_git install_docker install_python \
                   install_ollama install_webui install_tailscale tune motd; do
  cat > "${POST_SB}/scripts/${step_script}.sh" <<'STUB'
#!/usr/bin/env bash
printf 'scripts/%s\n' "${0##*/}" >> "${RAN_LOG}"
exit 0
STUB
done
cat > "${POST_SB}/netmode.sh" <<'STUB'
#!/usr/bin/env bash
printf 'netmode.sh %s\n' "$1" >> "${RAN_LOG}"
exit 0
STUB
cat > "${POST_SB}/check-system.sh" <<'STUB'
#!/usr/bin/env bash
printf 'check-system.sh\n' >> "${RAN_LOG}"
exit 1
STUB
chmod +x "${POST_SB}"/*.sh "${POST_SB}"/scripts/*.sh "${POST_SB}"/bin/*
cat >> "${POST_SB}/scripts/lib.sh" <<'SHIM'
ensure_ollama_up_announced() { return 0; }
model_present() { return 1; }
pull_model() { return 1; }
net_guard() { :; }
can_root() { return 1; }
sync_env_keys() { :; }
SHIM
pullfail_rc=0
pullfail_out="$(cd "${POST_SB}" && ./setup.sh </dev/null 2>&1)" || pullfail_rc=$?
pullfail_ran="$(cat "${POST_SB}/ran.log" 2>/dev/null || true)"

pullfail_ran_step() {
  grep -qxF "$1" <<<"${pullfail_ran}" || {
    printf 'a failed model pull skipped: %s\nwhat did run:\n%s\n' "$1" "${pullfail_ran}" >&2
    return 1
  }
}
# The security one first, because it is the reason this is not just tidiness.
check "a failed model pull still applies the inbound guard" \
  pullfail_ran_step "netmode.sh harden"
check "...still installs the boot services"  pullfail_ran_step "netmode.sh --install-service"
check "...still installs the login banner"   pullfail_ran_step "scripts/motd.sh"
check "...still runs the final check"        pullfail_ran_step "check-system.sh"
pullfail_reports_failure() {
  [[ "${pullfail_rc}" == "1" ]] && grep -qF 'SETUP FINISHED WITH ERRORS' <<<"${pullfail_out}"
}
check "...and still reports the install as failed" pullfail_reports_failure
check "a failing setup keeps its exit status"     failing_setup_keeps_status
check "setup.sh --help prints no verdict"         help_prints_no_verdict
# update.sh takes a backup specifically so it can be restored when the update
# goes wrong. Dying bare under 'set -e' would never mention it.
# Scoped to the "Re-running setup" section and stopped at the next step: the
# first version of this searched the whole rest of the file, found the
# unrelated restore.sh mention in the self-test branch below, and passed
# happily with the guard deleted.
update_mentions_restore_on_failure() {
  awk '/step "Re-running setup"/ {seen=1; next}
       seen && /step "/ {exit}
       seen && /if ! .*setup\.sh/ {guarded=1}
       seen && /restore\.sh/ {ok=1}
       END {exit !(ok && guarded)}' "${REPO}/update.sh"
}
check "update.sh points at the backup when setup fails" \
  update_mentions_restore_on_failure

echo "# 'lca check --quick' skips the one probe that costs real time"
# Measured on this box: a full 'lca check' took 242 seconds, of which all but
# about 3 were one probe — asking the model to generate. setup.sh runs exactly
# that probe a few steps earlier and dies if it fails, so the final check was
# paying for it twice on every install and every E2E run in CI.
quick_flag_documented_in_usage() {
  local out
  out="$(bash "${REPO}/check-system.sh" --help 2>&1)" || return 1
  # A DESCRIBED flag, not merely the token. The first version searched for
  # '--quick' anywhere in the output and could not fail: the usage line
  # "Usage: lca check [--quick]" contains it, so deleting the explanation
  # entirely left the test green. What must stay true is that someone reading
  # --help learns what the flag does.
  grep -qE '^[[:space:]]*--quick[[:space:]]+[a-z]' <<<"${out}"
}
check "check-system.sh --help explains what --quick does, and exits 0" \
  quick_flag_documented_in_usage
# An unknown flag must be refused rather than silently ignored: a typo'd
# '--quik' that runs the slow path anyway is the failure this whole flag is
# meant to remove.
rejects_unknown_flag() {
  bash "${REPO}/check-system.sh" --definitely-not-a-flag >/dev/null 2>&1
  (( $? == 2 ))
}
check "check-system.sh rejects an unknown flag with exit 2" rejects_unknown_flag
# The generation probe must sit UNDER the guard, not merely somewhere in the
# same file. Asserted on the block so that moving the probe out from under the
# branch fails here even though both strings still appear.
quick_guards_the_generation_probe() {
  awk '/\{QUICK\}" == "true" \]\]; then/ { inblock=1; next }
       inblock && /^# --- / { exit }
       inblock && /model_responds/ { found=1 }
       END { exit !found }' "${REPO}/check-system.sh"
}
check "the slow generation probe sits under the --quick guard" \
  quick_guards_the_generation_probe
# setup.sh must use it — but conditionally. An unconditional --quick would be
# worse than the duplication it removes: when Ollama is unreachable the smoke
# test never runs, and this check is then the only thing that would prove
# inference works at all. So --quick may only ever be reached through the
# variable that a successful generation sets.
setup_skips_only_what_it_already_proved() {
  # The flag is never passed as a literal on the invocation line...
  ! grep -qE 'check-system\.sh".*--quick' "${REPO}/setup.sh" || return 1
  # ...it is gated on a variable, which only a real generation sets true...
  grep -qE '^[[:space:]]*smoke_tested=true$' "${REPO}/setup.sh" || return 1
  awk '/if model_responds /   { inblock=1; next }
       inblock && /^[[:space:]]*else/  { exit }
       inblock && /smoke_tested=true/  { found=1 }
       END { exit !found }' "${REPO}/setup.sh" || return 1
  # ...and that variable is what decides the argument.
  awk '/smoke_tested\}" == "true" \]\]; then/ { inblock=1; next }
       inblock && /^[[:space:]]*fi$/ { exit }
       inblock && /--quick/ { found=1 }
       END { exit !found }' "${REPO}/setup.sh"
}
check "setup.sh skips the re-test only when it already proved inference" \
  setup_skips_only_what_it_already_proved

echo "# a model that is still loading is not a model the box has too little RAM for"
# Five messages named RAM when a real generation did not come back, four of
# them first. Measured from this project's own CPU-only VPS — every model load
# its Ollama log holds, "loading model via llama-server" to "loaded runners":
#
#   298.6s  77.6s  39.6s  34.8s  26.0s  30.3s  64.8s
#
# 'lca check' allowed 240s for the load AND the generation, so on a box that
# had just rebooted — which is exactly when somebody runs it — the command
# that exists to diagnose this stack called a healthy model broken and sent
# its owner to 'free -h'. RAM was not the cause once.
#
# curl's exit 28 is "operation timed out", documented and locale-independent,
# and it is the difference between "still loading" and "said no".
probe_outcome() {  # timeout | empty | ok | dead -> the recorded outcome
  bash -c '
    source "$1" >/dev/null 2>&1
    case "$2" in
      timeout) curl() { return 28; } ;;
      empty)   curl() { printf "{}"; } ;;
      ok)      curl() { printf "{\"response\":\"ready\"}"; } ;;
      *)       curl() { return 7; } ;;
    esac
    model_responds fake-model 5 >/dev/null 2>&1
    printf "%s" "${MODEL_PROBE_OUTCOME}"' _ "${REPO}/scripts/lib.sh" "$1"
}
check "a probe that ran out of time is recorded as a timeout" \
  test "$(probe_outcome timeout)" = timeout
check "a server that answered with nothing is not a timeout" \
  test "$(probe_outcome empty)" = refused
check "a connection that failed outright is not a timeout either" \
  test "$(probe_outcome dead)" = refused
check "a real answer is recorded as ok" \
  test "$(probe_outcome ok)" = ok
# ...and the distinction has to reach the reader, in the right order. RAM does
# cause this, so it stays — after the cause the measurements actually produced,
# not instead of it.
silence_reason_for() {  # outcome -> the sentence
  bash -c '
    source "$1" >/dev/null 2>&1
    MODEL_PROBE_OUTCOME="$2"; MODEL_PROBE_SECONDS=240
    model_silence_reason' _ "${REPO}/scripts/lib.sh" "$2"
}
silence_reason_leads_with_the_measured_cause() {
  local slow refused ram_at load_at
  slow="$(silence_reason_for _ timeout)"
  refused="$(silence_reason_for _ refused)"
  [[ "${slow}" != "${refused}" ]] || {
    echo 'a timeout and a refusal are given the same explanation' >&2; return 1; }
  grep -q '240s' <<<"${slow}" || {
    printf 'the timeout message does not say how long it waited: %s\n' "${slow}" >&2; return 1; }
  # RAM must appear, and must appear AFTER the load explanation.
  ram_at="$(awk '{ print index($0, "RAM: free -h") }' <<<"${slow}")"
  load_at="$(awk '{ print index($0, "load") }' <<<"${slow}")"
  (( ram_at > 0 )) || {
    printf 'the timeout message drops RAM entirely, which is a real cause: %s\n' "${slow}" >&2; return 1; }
  (( load_at > 0 && load_at < ram_at )) || {
    printf 'the timeout message reaches RAM before it explains the load: %s\n' "${slow}" >&2; return 1; }
  grep -qi 'not a slow load' <<<"${refused}" || {
    printf 'the refusal message does not rule out "it is just still loading": %s\n' "${refused}" >&2
    return 1; }
}
check "a slow load and a refusal are explained differently, load first" \
  silence_reason_leads_with_the_measured_cause
# ...and no script may go back to asserting RAM by hand.
no_script_blames_ram_on_its_own() {
  local bad=0 seen=0 f body
  for f in check-system.sh setup.sh update-model.sh scripts/tune.sh scripts/selftest.sh; do
    grep -q 'model_responds' "${REPO}/${f}" || {
      printf '%s no longer probes the model at all — this gate has lost its subject\n' "${f}" >&2
      bad=1; continue; }
    seen=$((seen+1))
    grep -q 'model_silence_reason' "${REPO}/${f}" || {
      printf '%s reports a model that did not respond without saying why\n' "${f}" >&2
      bad=1; }
    body="$(sed 's/#.*//' "${REPO}/${f}")"
    if grep -qE 'RAM headroom|enough RAM for it|RAM\? see' <<<"${body}"; then
      printf '%s names RAM by hand again, ahead of the cause that was actually measured\n' "${f}" >&2
      bad=1
    fi
  done
  (( seen == 5 )) || { echo "expected 5 model probes, found ${seen}" >&2; bad=1; }
  return "${bad}"
}
check "no script blames RAM for a generation that merely ran out of time" \
  no_script_blames_ram_on_its_own

echo "# the inbound guard bakes its ports in, so .env can drift away from it"
# Change a port in .env and the guard goes on dropping the old one while the
# service listens on the new one — unauthenticated, on every interface. 'lca
# check' reports it and 'lca apply' fixes it, from one copy of the rule.
GUARD_DUMP='table inet lca_inbound {
  chain inbound {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    iifname "tailscale0" accept
    tcp dport { 3000, 11434 } ct state new counter packets 0 bytes 0 drop
  }
}'
# Both helpers run in a SUBSHELL with the live-container probe stubbed out.
#
# guarded_ports also reports the port a RUNNING chat app is really on when it
# differs from .env — a real and valuable case, covered on its own below. But
# these assertions are about what .env asks for, and without the stub they pick
# up whatever container happens to exist on the machine: with one running on
# 3000, three of the checks below failed while every one of them was correct.
#
# That is worse than an inconvenience. It means 'make gates' failed on a box
# with the chat app actually running — which is a real install, the one place a
# user would run it. Found only because a container got started here.
#
# The subshell matters: a function defined inside a function is global from
# then on in bash, so a bare stub would silently follow every later test.
#
# webui_container_running is stubbed alongside webui_container_env in every
# fixture below, and it has to be. Left to the real probe these read one answer
# on a machine with the chat app up and another on a clean checkout — the
# environment dependence that has turned CI red on this branch twice. "No
# container" is what these fixtures mean, so they say it.
ports_for() {  # ENABLE_WEBUI WEBUI_PORT OLLAMA_HOST
  ( ENABLE_WEBUI="$1"; WEBUI_PORT="$2"; OLLAMA_HOST="$3"
    webui_container_env() { return 1; }
    webui_container_running() { return 1; }
    guarded_ports | paste -sd'|' - )
}
uncovered_for() {  # DUMP ENABLE_WEBUI WEBUI_PORT OLLAMA_HOST
  ( local dump="$1"; ENABLE_WEBUI="$2"; WEBUI_PORT="$3"; OLLAMA_HOST="$4"
    webui_container_env() { return 1; }
    webui_container_running() { return 1; }
    inbound_guard_uncovered "${dump}" | paste -sd'|' - )
}
# ...and the live-container case itself, which nothing covered deterministically
# because it depended on whether a container happened to be running. A chat app
# left on the OLD port after a .env edit is unauthenticated on every interface,
# so this is the one the guard most needs to hear about.
live_ports_for() {  # WEBUI_PORT LIVE_PORT [ENABLE_WEBUI] [RUNNING]
  ( ENABLE_WEBUI="${3:-true}"; WEBUI_PORT="$1"; OLLAMA_HOST=127.0.0.1:11434
    LIVE="$2"; webui_container_env() { printf '%s' "${LIVE}"; }
    RUNNING="${4:-yes}"
    webui_container_running() { [[ "${RUNNING}" == "yes" ]]; }
    guarded_ports | paste -sd'|' - )
}
check "a chat app still on the old port is named alongside the new one" \
  test "$(live_ports_for 8080 3000)" = "WebUI 8080|Ollama 11434|live WebUI 3000"
check "...and is not repeated when it already agrees with .env" \
  test "$(live_ports_for 3000 3000)" = "WebUI 3000|Ollama 11434"
check "...and a live chat app on 22 is not called a gap either" \
  test "$(live_ports_for 8080 22)" = "WebUI 8080|Ollama 11434"
check "both service ports are guarded by default" \
  test "$(ports_for true 3000 127.0.0.1:11434)" = "WebUI 3000|Ollama 11434"
check "with the chat app off, only Ollama's port is" \
  test "$(ports_for false 3000 127.0.0.1:11434)" = "Ollama 11434"
# netmode.sh refuses to put SSH in the drop set so the guard can never lock
# anyone out — so a service parked on 22 is not a gap either. Reporting one
# would be a failure nobody could ever clear.
check "a chat app on port 22 is not called a gap" \
  test "$(ports_for true 22 127.0.0.1:11434)" = "Ollama 11434"
check "an Ollama on port 22 is not called a gap" \
  test "$(ports_for true 3000 127.0.0.1:22)" = "WebUI 3000"
nothing_to_guard() {
  ( ENABLE_WEBUI=false; OLLAMA_HOST=127.0.0.1:22
    webui_container_env() { return 1; }
    webui_container_running() { return 1; }
    ! guarded_ports )
}
check "and with neither, there is nothing to guard" nothing_to_guard

# ...but ENABLE_WEBUI=false does NOT mean nothing is listening, and that gap
# was a security hole. Turning the chat app off in .env does not stop its
# container: setting it and running the documented 'sudo lca apply' left Open
# WebUI serving on every interface — it runs with --network=host, and signups
# are open by default — while the two commands that decide what the guard
# covers both said there was nothing there. Measured on this box with
# ENABLE_WEBUI=false and the container untouched:
#
#   guarded_ports:  Ollama 11434                  (3000 simply absent)
#   curl 127.0.0.1:3000/health -> {"status":true}
#   lca check:      "no public service ports to guard"
#
# Before the edit port 3000 was guarded; after it, it was not. Turning a
# feature off made the box more exposed. netmode.sh's own renderer never
# agreed — it guards WEBUI_PORT regardless of ENABLE_WEBUI — so there were
# three answers to one question and the two driving 'lca check' and 'lca
# apply' were the wrong ones.
#
# ENABLE_WEBUI is a statement of intent. A listening socket is a fact.
check "a chat app .env has disabled but that is still running is still guarded" \
  test "$(live_ports_for 3000 3000 false yes)" = "Ollama 11434|live WebUI 3000"
# ...and a STOPPED one is not, because it listens on nothing — and because
# 'lca webui stop' leaves the container and its baked-in PORT in place, so
# reporting it would be a gap nothing could ever clear.
check "...while a stopped one is not called a gap" \
  test "$(live_ports_for 3000 3000 false no)" = "Ollama 11434"
# ...and the fix must not double-count on the ordinary path.
check "...and an enabled, running chat app is still named exactly once" \
  test "$(live_ports_for 3000 3000 true yes)" = "WebUI 3000|Ollama 11434"
# The whole point is that netmode's ruleset already covers it, so this reports
# no gap the user cannot close. If these two ever disagree, 'lca check' would
# demand an 'lca apply' that could not help — the loop this function's header
# calls worse than saying nothing.
guard_ruleset_covers_a_disabled_but_live_chat_app() {
  local dump gaps
  dump="$(ENABLE_WEBUI=false WEBUI_PORT=3000 OLLAMA_HOST=127.0.0.1:11434 \
          bash "${REPO}/netmode.sh" render-inbound 2>/dev/null)"
  [[ -n "${dump}" ]] || { echo 'render-inbound produced nothing' >&2; return 1; }
  gaps="$( ENABLE_WEBUI=false; WEBUI_PORT=3000; OLLAMA_HOST=127.0.0.1:11434
           webui_container_env() { printf '3000'; }
           webui_container_running() { return 0; }
           inbound_guard_uncovered "${dump}" || true )"
  [[ -z "${gaps}" ]] || {
    printf 'the guard netmode writes does not cover what guarded_ports asks for: %s\n' "${gaps}" >&2
    return 1
  }
}
check "...and netmode's ruleset really does cover it, so the report is closable" \
  guard_ruleset_covers_a_disabled_but_live_chat_app
# ...and the two reporters must ASK that function rather than keep their own
# copy of the decision. check-system.sh opened its inbound section with a
# fourth hand-written condition — ENABLE_WEBUI != true and Ollama on loopback
# -> "no public service ports to guard" — which short-circuited guarded_ports
# entirely. The note in its own else-branch already said why that is wrong:
# "'lca apply' now fixes what this reports, and the two must not be able to
# disagree about which ports count."
check_system_asks_for_the_port_list() {
  local body
  body="$(sed -n '/^step "Inbound guard"$/,/^step /p' "${REPO}/check-system.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find check-system.sh's inbound guard section — this gate stopped watching" >&2
    return 1; }
  grep -q 'guarded_ports' <<<"${body}" || {
    echo 'check-system.sh decides what needs guarding without asking guarded_ports' >&2
    return 1; }
  # The regression exactly: the section must not branch on ENABLE_WEBUI itself.
  ! grep -q 'ENABLE_WEBUI' <<<"${body}" || {
    echo 'check-system.sh is back to reading ENABLE_WEBUI directly — a chat app left running while .env disables it goes unreported' >&2
    return 1; }
}
check "'lca check' asks lib.sh which ports need guarding" \
  check_system_asks_for_the_port_list
# ...and 'lca apply', whose one promise is to make the running system match
# .env, must not answer "nothing to apply" about the single setting that turns
# the chat app off while its container is still running.
apply_webui_run() {  # ENABLE_WEBUI RUNNING -> output, then counters
  bash -c '
    source "$1" >/dev/null 2>&1
    ENABLE_WEBUI="$2"; RUN="$3"; SKIP_DOCKER=false
    have() { return 0; }
    docker_daemon_reachable() { return 0; }
    webui_container_running() { [[ "${RUN}" == "yes" ]]; }
    webui_container_exists() { [[ "${RUN}" == "yes" ]]; }
    webui_drift() { return 1; }
    apply_webui
    printf "unchecked=%s changed=%s\n" "${UNCHECKED}" "${CHANGED}"' \
    _ "${REPO}/scripts/apply.sh" "$1" "$2" 2>&1
}
apply_reports_a_disabled_chat_app_still_running() {
  local out
  out="$(apply_webui_run false yes)"
  grep -qi 'still RUNNING' <<<"${out}" || {
    printf 'apply says nothing about a chat app it disabled but did not stop: %s\n' "${out}" >&2
    return 1; }
  grep -q 'webui stop' <<<"${out}" || {
    printf 'apply does not say how to stop it: %s\n' "${out}" >&2
    return 1; }
  grep -q 'unchecked=1' <<<"${out}" || {
    printf 'it is not counted, so the summary still claims everything matches: %s\n' "${out}" >&2
    return 1; }
  # ...and a genuinely-off chat app must stay quiet, or this becomes a nag on
  # every run of a correctly configured machine.
  out="$(apply_webui_run false no)"
  grep -qi 'still RUNNING' <<<"${out}" && {
    printf 'a chat app that really is off is warned about anyway: %s\n' "${out}" >&2
    return 1; }
  grep -q 'unchecked=0' <<<"${out}" || {
    printf 'a chat app that really is off is counted as unchecked: %s\n' "${out}" >&2
    return 1; }
  return 0
}
check "'lca apply' says when .env disabled the chat app but it is still running" \
  apply_reports_a_disabled_chat_app_still_running

# The port the container is REALLY on. Open WebUI bakes its port in at
# creation and runs with --network=host, so editing WEBUI_PORT leaves it
# listening on the OLD port on every interface — and a reboot rebuilds the
# guard from .env, covering the new port while the old one goes on accepting
# public connections. Stubbed, because the real answer needs a docker daemon.
live_port_is_guarded_too() {
  local ENABLE_WEBUI=true WEBUI_PORT=8080 OLLAMA_HOST=127.0.0.1:11434
  # BOTH seams. guarded_ports asks webui_container_running first — a stopped
  # container listens on nothing — so stubbing only webui_container_env leaves
  # the answer depending on whether a container happens to be up on the machine
  # running the tests. That is the environment dependence this branch has hit
  # three times now, and the third was this file.
  webui_container_running() { return 0; }
  webui_container_env() { [[ "$1" == PORT ]] && printf '3000'; }
  [[ "$(guarded_ports | paste -sd'|' -)" == "WebUI 8080|Ollama 11434|live WebUI 3000" ]]
}
live_port_adds_nothing_when_it_agrees() {
  local ENABLE_WEBUI=true WEBUI_PORT=3000 OLLAMA_HOST=127.0.0.1:11434
  webui_container_running() { return 0; }
  webui_container_env() { [[ "$1" == PORT ]] && printf '3000'; }
  [[ "$(guarded_ports | paste -sd'|' -)" == "WebUI 3000|Ollama 11434" ]]
}
live_port_is_silent_without_docker() {
  local ENABLE_WEBUI=true WEBUI_PORT=8080 OLLAMA_HOST=127.0.0.1:11434
  webui_container_running() { return 1; }
  webui_container_env() { return 1; }   # docker unreadable — cannot ask
  [[ "$(guarded_ports | paste -sd'|' -)" == "WebUI 8080|Ollama 11434" ]]
}
# ...and the uncovered check must name it, since that is the exposed one.
live_port_reads_as_uncovered() {
  local ENABLE_WEBUI=true WEBUI_PORT=8080 OLLAMA_HOST=127.0.0.1:11434
  webui_container_running() { return 0; }
  webui_container_env() { [[ "$1" == PORT ]] && printf '3000'; }
  # a guard built from .env alone: 8080 and 11434, not 3000
  [[ "$(inbound_guard_uncovered 'tcp dport { 8080, 11434 } drop')" == "live WebUI 3000" ]]
}
check "a container left on the old port is guarded as well" live_port_is_guarded_too
check "no duplicate when the live port and .env agree"       live_port_adds_nothing_when_it_agrees
check "no claim about the live port when docker cannot be read" \
  live_port_is_silent_without_docker
check "a guard built from .env alone leaves the live port uncovered" \
  live_port_reads_as_uncovered

covers_everything() {
  local ENABLE_WEBUI=true WEBUI_PORT=3000 OLLAMA_HOST=127.0.0.1:11434
  webui_container_running() { return 1; }
  webui_container_env() { return 1; }
  ! inbound_guard_uncovered "${GUARD_DUMP}"
}
check "a guard covering both ports reports no gap" covers_everything
check "a port moved in .env is reported as uncovered" \
  test "$(uncovered_for "${GUARD_DUMP}" true 8080 127.0.0.1:11434)" = "WebUI 8080"
check "both are reported when no guard is loaded at all" \
  test "$(uncovered_for "" true 3000 127.0.0.1:11434)" = "WebUI 3000|Ollama 11434"
# A guard covering 11434 must not be read as covering 1143.
check "a port that is a prefix of a guarded one is still uncovered" \
  test "$(uncovered_for "${GUARD_DUMP}" false 3000 127.0.0.1:1143)" = "Ollama 1143"

# ...and neither reporter nor fixer may keep its own copy of the rule.
one_copy_of_the_coverage_rule() {
  local hits
  hits="$(grep -n 'dport \\{' "${REPO}/check-system.sh" "${REPO}/scripts/apply.sh" 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'a second copy of the guard-coverage rule:\n%s\n' "${hits}" >&2
    return 1
  }
}
guard_is_reported_and_applied() {
  grep -q 'inbound_guard_uncovered' "${REPO}/check-system.sh" || return 1
  grep -q 'inbound_guard_uncovered' "${REPO}/scripts/apply.sh"  || return 1
  # and 'lca apply' must actually run the fix, not just describe it
  grep -q 'netmode.sh" harden' "${REPO}/scripts/apply.sh" || return 1
  # ...and main() must reach it, or every test below drives dead code.
  awk '/^main\(\) \{/     { inb=1; next }
       inb && /^\}/       { exit }
       inb && /apply_guard/ { found=1 }
       END { exit !found }' "${REPO}/scripts/apply.sh"
}
check "the guard-coverage rule exists in exactly one place" \
  one_copy_of_the_coverage_rule
check "'lca check' reports guard drift and 'lca apply' fixes it" \
  guard_is_reported_and_applied

# ...and the applier itself is driven for real, because what it decides is
# whether a firewall gets loaded. apply.sh guards its own main() behind a
# BASH_SOURCE test precisely so this is possible.
cp "${REPO}/scripts/apply.sh" "${SANDBOX}/scripts/apply.sh"
# Exits HARDEN_RC so a kernel that refuses the ruleset can be simulated; the
# checks that predate it set nothing and get the old always-succeeds stub.
cat > "${SANDBOX}/netmode.sh" <<'HARDENSTUB'
#!/usr/bin/env bash
echo "HARDEN-CALLED"
exit "${HARDEN_RC:-0}"
HARDENSTUB
chmod +x "${SANDBOX}/netmode.sh"
cat > "${SANDBOX}/apply-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 apply.sh  $2 have-nft  $3 can-root  $4 nft dump  $5 dry-run  $6 WEBUI_PORT
set -euo pipefail
source "$1"
# After the source, never before: apply.sh calls load_env, which re-exports
# every key in .env over whatever the caller had set.
HAVE_NFT="$2"; CAN_ROOT="$3"; NFT_DUMP="$4"; DRY_RUN="$5"
ENABLE_WEBUI=true; WEBUI_PORT="${6:-3000}"; OLLAMA_HOST=127.0.0.1:11434
have()     { case "$1" in nft) return "${HAVE_NFT}" ;; *) return 0 ;; esac; }
can_root() { return "${CAN_ROOT}"; }
as_root()  { printf '%s' "${NFT_DUMP}"; }
apply_guard
echo "CHANGED=${CHANGED} UNCHECKED=${UNCHECKED} BLOCKED=${BLOCKED}"
PROBE
chmod +x "${SANDBOX}/apply-probe.sh"
apply_probe() {
  bash "${SANDBOX}/apply-probe.sh" "${SANDBOX}/scripts/apply.sh" "$@" 2>&1
}
guard_noop_when_covered() {
  local out; out="$(apply_probe 0 0 "${GUARD_DUMP}" false)"
  grep -q 'CHANGED=0 UNCHECKED=0' <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# Both ways in: a guard that is loaded but has fallen behind .env, and no
# guard at all. They are separate branches, so a dry run has to be proved on
# each — testing only one leaves the other free to load a firewall during a
# run whose entire promise is that it changes nothing.
guard_hardens_on_a_drifted_port() {
  local out; out="$(apply_probe 0 0 "${GUARD_DUMP}" false 8080)"
  grep -q 'HARDEN-CALLED'   <<<"${out}" || { echo "${out}" >&2; return 1; }
  grep -q 'CHANGED=1'       <<<"${out}" || { echo "${out}" >&2; return 1; }
}
guard_hardens_when_not_loaded() {
  local out; out="$(apply_probe 0 0 "" false)"
  grep -q 'HARDEN-CALLED'   <<<"${out}" || { echo "${out}" >&2; return 1; }
  grep -q 'CHANGED=1'       <<<"${out}" || { echo "${out}" >&2; return 1; }
}
guard_dry_run_on_a_drifted_port() {
  local out; out="$(apply_probe 0 0 "${GUARD_DUMP}" true 8080)"
  grep -q 'would'           <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
guard_dry_run_when_not_loaded() {
  local out; out="$(apply_probe 0 0 "" true)"
  grep -q 'would'           <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# "Could not look" must never be counted as "matches" — that is the exact
# failure this command exists to end, one level up.
guard_without_nft_is_unchecked() {
  local out; out="$(apply_probe 1 0 "" false)"
  grep -q 'CHANGED=0 UNCHECKED=1' <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# A harden that FAILS must not take the command out. This one is the last
# applier, so a bare call meant a kernel that will not load the ruleset — a
# container, a VPS kernel without the nftables modules — ended 'lca apply'
# with no summary line at all, immediately after everything else had applied
# cleanly. The probe's final echo is the assertion: under 'set -e' it simply
# never prints if apply_guard aborts.
guard_failure_is_reported_not_fatal() {
  local out; out="$(HARDEN_RC=1 apply_probe 0 0 "" false)"
  grep -q 'HARDEN-CALLED' <<<"${out}" || { echo "${out}" >&2; return 1; }
  grep -q 'CHANGED=0 UNCHECKED=1' <<<"${out}" || {
    printf 'apply_guard did not survive a failing harden:\n%s\n' "${out}" >&2
    return 1
  }
  grep -q 'may still be reachable from outside' <<<"${out}" || {
    echo "the failure was counted but never explained" >&2; return 1
  }
}
guard_without_root_is_unchecked() {
  local out; out="$(apply_probe 0 1 "" false)"
  grep -q 'CHANGED=0 UNCHECKED=1' <<<"${out}" || { echo "${out}" >&2; return 1; }
  ! grep -q 'HARDEN-CALLED' <<<"${out}"
}
# The summary is a claim too. Three of its four branches already refused to
# say "everything matches" when something could not be looked at; the dry-run
# branch printed the count alone, so a reader whose docker daemon was down got
# "1 change(s) would be applied" as if that were the whole plan. Found by
# running 'lca apply --dry-run' on a box with no docker, which is exactly the
# combination — a change found elsewhere, a component unreadable.
cat > "${SANDBOX}/apply-summary-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
apply_ollama()       { :; }
apply_webui()        { UNCHECKED=$((UNCHECKED+1)); }
apply_backup_timer() { :; }
apply_guard()        { CHANGED=$((CHANGED+1)); }
main "${@:2}"
PROBE
chmod +x "${SANDBOX}/apply-summary-probe.sh"
summary_probe() { bash "${SANDBOX}/apply-summary-probe.sh" "${SANDBOX}/scripts/apply.sh" "$@" 2>&1; }
dry_run_owns_up_to_what_it_could_not_read() {
  local out; out="$(summary_probe --dry-run)"
  grep -q 'could not be checked' <<<"${out}" || { echo "${out}" >&2; return 1; }
}
real_run_owns_up_too() {
  local out; out="$(summary_probe)"
  grep -q 'could not be checked' <<<"${out}" || { echo "${out}" >&2; return 1; }
}
check "a dry-run plan says when it could not read something" \
  dry_run_owns_up_to_what_it_could_not_read
check "and so does the real run"  real_run_owns_up_too

check "apply leaves a guard that already covers .env alone" guard_noop_when_covered
check "apply re-hardens when a port drifted"                guard_hardens_on_a_drifted_port
check "apply hardens when no guard is loaded"               guard_hardens_when_not_loaded
check "--dry-run only talks about a drifted port"           guard_dry_run_on_a_drifted_port
check "--dry-run only talks about a missing guard"          guard_dry_run_when_not_loaded
check "no nftables is 'not checked', never 'matches'"        guard_without_nft_is_unchecked
check "no root is 'not checked', never 'matches'"            guard_without_root_is_unchecked
check "a harden that fails is reported, not fatal"           guard_failure_is_reported_not_fatal

echo "# what a boot unit will really run ('enabled' is a claim about a symlink)"
# All three of our units bake the installing checkout's absolute path into
# ExecStart. 'systemctl is-enabled' keeps answering "enabled" after that path
# is moved, renamed or deleted, so 'lca check' printed a green "inbound guard
# will be re-applied on boot" for a unit that could not start — and the ports
# it guards would be public from the next reboot on. Same shape for the backup
# timer, where the symptom is backups that silently never ran.
UNITS="${SANDBOX}/units"
mkdir -p "${UNITS}"

# systemd renders ExecStart as a brace-delimited record; the path must be read
# out of it without swallowing the argv[] tail that follows.
check "systemd's ExecStart record yields just the path" \
  test "$(show_execstart_program <<'EOF'
{ path=/opt/local-code-agent/netmode.sh ; argv[]=/opt/local-code-agent/netmode.sh apply-saved ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
EOF
)" = "/opt/local-code-agent/netmode.sh"
# ...and a path containing a space still comes back whole, which is why the
# capture ends at the ' ; ' instead of at the first blank.
check "a path with a space survives the ExecStart record" \
  test "$(show_execstart_program <<'EOF'
{ path=/opt/my apps/lca/netmode.sh ; argv[]=/opt/my apps/lca/netmode.sh apply-saved ; ignore_errors=no }
EOF
)" = "/opt/my apps/lca/netmode.sh"

# The unit file is the fallback, and the only source when systemd is installed
# but not running. We write the quoted form; the bare form is what an older
# version of this repo left behind.
printf '[Service]\nType=oneshot\nExecStart="/opt/lca/netmode.sh" apply-saved\n' \
  > "${UNITS}/quoted.service"
printf '[Service]\nExecStart=/opt/lca/tune.sh\n' > "${UNITS}/bare.service"
printf '[Unit]\nDescription=no exec here\n'      > "${UNITS}/empty.service"
check "a quoted ExecStart parses (args dropped)" \
  test "$(execstart_program "${UNITS}/quoted.service")" = "/opt/lca/netmode.sh"
check "an unquoted ExecStart parses" \
  test "$(execstart_program "${UNITS}/bare.service")" = "/opt/lca/tune.sh"
no_execstart_is_silent()   { ! execstart_program "${UNITS}/empty.service"; }
no_unit_file_is_silent()   { ! execstart_program "${UNITS}/absent.service"; }
check "a unit with no ExecStart reports nothing"   no_execstart_is_silent
check "a unit file that is not there reports nothing" no_unit_file_is_silent

# stale_boot_program is the check-system predicate: it speaks up ONLY when it
# knows the program is gone. 'local' on the seam keeps it dynamically scoped to
# the call, so the surrounding tests are unaffected.
printf '[Service]\nExecStart="%s/scripts/lib.sh"\n' "${REPO}" > "${UNITS}/live.service"
printf '[Service]\nExecStart="%s/moved-away/netmode.sh"\n' "${REPO}" > "${UNITS}/moved.service"
moved_program_is_named() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  test "$(stale_boot_program moved.service)" = "${REPO}/moved-away/netmode.sh"
}
present_program_is_silent() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  ! stale_boot_program live.service
}
# An unknown is not a fault: with no unit file and no answer from systemd there
# is nothing to report, and a check that cries wolf about its own blind spot is
# worse than one that stays quiet.
unknown_unit_is_not_called_broken() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  ! stale_boot_program absent.service
}
check "a unit whose program moved is reported, with the missing path" \
  moved_program_is_named
check "a unit whose program is there says nothing"  present_program_is_silent
check "a unit we cannot read at all is not called broken" \
  unknown_unit_is_not_called_broken

# A unit that is merely disabled and one whose file was never written need
# different fixes, and 'lca check' offered the light one unconditionally:
# 'systemctl enable' cannot enable a file that is not there, which is the most
# likely reason it is not enabled.
enable_hint_when_the_file_is_there() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  test "$(reenable_hint live.service './setup.sh')" = "sudo systemctl enable live.service"
}
installer_hint_when_the_file_is_gone() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  test "$(reenable_hint absent.service './setup.sh')" = "./setup.sh"
}
# '--now' would also RUN the unit, which for auto-tune can mean an unasked-for
# model download; the question was about the next boot.
enable_hint_does_not_run_the_unit() {
  local SYSTEMD_UNIT_DIR="${UNITS}"
  ! grep -q -- '--now' <<<"$(reenable_hint live.service './setup.sh')"
}
check "an existing unit file is re-enabled, not re-installed" \
  enable_hint_when_the_file_is_there
check "a missing unit file sends you to the installer that writes it" \
  installer_hint_when_the_file_is_gone
check "the enable hint does not start the unit as a side effect" \
  enable_hint_does_not_run_the_unit

# ...and check-system.sh must actually consult it, for all three units, rather
# than trusting is-enabled the way it did before.
every_boot_unit_is_verified() {
  local unit
  for unit in local-code-agent-netmode.service local-code-agent-tune.service \
              local-code-agent-backup.service; do
    grep -q "stale_boot_program ${unit}" "${REPO}/check-system.sh" \
      || { printf 'check-system.sh never checks what %s really runs\n' "${unit}" >&2
           return 1; }
  done
}
check "check-system.sh verifies the program behind every boot unit" \
  every_boot_unit_is_verified
# ...and the tune unit must be checked whatever AUTO_TUNE says.
#
# It has two jobs. Re-picking the model from RAM is the AUTO_TUNE=true one; the
# other is warming the model at boot, and nothing else does that —
# OLLAMA_KEEP_ALIVE stops a resident model being evicted, it never preloads
# one. On a CPU-only host the cost of losing it is the whole first message
# after a reboot: measured 60-90s for a 3B on 4 vCPU, 228s for a 7B cold.
#
# The check used to sit inside 'if [[ "${AUTO_TUNE}" == "true" ]]', so the
# account most likely to depend on the warm was the one it said nothing to:
# 'lca model' sets AUTO_TUNE=false for you.
tune_unit_checked_regardless_of_auto_tune() {
  local body region
  body="$(sed 's/#.*//' "${REPO}/check-system.sh")"
  # The block that decides on the tune unit, from the guard that opens it to
  # the closing of its branch.
  region="$(awk '/systemd_available; then/ { open = 1 }
                 open { print }
                 open && /local-code-agent-tune.service is not enabled/ { exit }' <<<"${body}")"
  grep -q 'local-code-agent-tune.service' <<<"${region}" || {
    echo "check-system.sh no longer decides anything about the tune boot unit" >&2
    return 1
  }
  grep -qE 'AUTO_TUNE\}" == "true" \]\] && systemd_available' <<<"${region}" && {
    echo "the tune boot unit is checked only when AUTO_TUNE=true — a pinned model gets no warning that nothing will preload it" >&2
    return 1
  }
  # ...and the consequence has to be stated for BOTH configurations, or the
  # branch is checked and then described with the wrong stake.
  grep -q 'preloaded' <<<"${body}" || {
    echo "nothing tells a pinned user what an unenabled tune unit costs them" >&2
    return 1
  }
  grep -q 'resizing this VM' <<<"${body}" || {
    echo "the auto-tune consequence stopped being named" >&2
    return 1
  }
  return 0
}
check "the boot unit is checked whether or not AUTO_TUNE is on" \
  tune_unit_checked_regardless_of_auto_tune

echo "# the documented way to put the inbound guard back must actually stick"
# 'netmode.sh harden' is the ONE command this repo names when the guard is
# missing — netmode status, 'lca check' twice, both installers and two docs all
# point at it — and netmode.sh's usage promises the guard survives reboots.
# For a long time it did not: harden loaded the ruleset for the current boot,
# while offline/online (which nobody is told to run to fix a missing guard)
# were the only subcommands that installed the unit re-applying it at boot.
# Following the documented recovery from "your ports are public" therefore
# made them public again at the next reboot.
harden_installs_the_boot_service() {
  grep -qE '^[[:space:]]*harden\)[[:space:]]+do_harden[[:space:]]*;;' "${REPO}/netmode.sh" \
    || { echo "netmode.sh: 'harden)' no longer dispatches to do_harden" >&2; return 1; }
  # awk's exit still runs END, so a body that ends before the match fails.
  awk '/^do_harden\(\) \{/     { inb=1; next }
       inb && /^\}/            { exit }
       inb && /install_service/ { found=1 }
       END { exit !found }' "${REPO}/netmode.sh" \
    || { echo "netmode.sh: do_harden does not install the boot service" >&2; return 1; }
  # ...and it still applies the guard now, which is the point of the command.
  awk '/^do_harden\(\) \{/         { inb=1; next }
       inb && /^\}/                { exit }
       inb && /apply_inbound_guard/ { found=1 }
       END { exit !found }' "${REPO}/netmode.sh" \
    || { echo "netmode.sh: do_harden no longer applies the guard" >&2; return 1; }
}
check "'netmode.sh harden' also installs the boot service" \
  harden_installs_the_boot_service

# ...and it must not report a systemd problem as a firewall problem. Both
# installers call 'netmode.sh harden' and turn ANY non-zero exit into "Could
# not apply the inbound guard — the port may be publicly reachable". Once the
# guard is up, exiting non-zero because the boot unit could not be written
# would send the reader chasing a firewall that is fine.
#
# Run for real rather than grepped: netmode.sh minus its 'main "$@"' line is
# just function definitions, and SCRIPT_DIR then resolves to the sandbox,
# which already holds a copy of lib.sh.
grep -v '^main "\$@"$' "${REPO}/netmode.sh" > "${SANDBOX}/netmode-funcs.sh"
cat > "${SANDBOX}/harden-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 = the function definitions, $2 = the exit status install_service should
# fake. Captured up front: inside the stub, $2 would be the stub's own arg.
set -euo pipefail
RC="$2"
source "$1"
apply_inbound_guard() { echo "GUARD-APPLIED"; }
install_service()     { return "${RC}"; }
do_harden
echo "HARDEN-RETURNED-0"
PROBE
cat > "${SANDBOX}/require-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
RC="$2"
source "$1"
install_service() { return "${RC}"; }
require_service
echo "REQUIRE-RETURNED-0"
PROBE
chmod +x "${SANDBOX}/harden-probe.sh" "${SANDBOX}/require-probe.sh"
harden_probe()  { bash "${SANDBOX}/harden-probe.sh"  "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1; }

# 'netmode.sh status' is what the README and TROUBLESHOOTING tell you to run to
# find out whether the guard is up. It said 'inbound_loaded; inbound_rc=$?' —
# leaving inbound_loaded an UNTESTED command, so under errexit a non-zero
# return killed the script right there, before the case that reports it and
# before the live probe. inbound_loaded returns 1 for "not loaded" and 2 for
# "cannot tell without root", so status printed three lines and stopped, exit
# 1, no explanation, in exactly the two situations it exists for. Observed on a
# box with no guard: the "NOT loaded" warning never appeared.
cat > "${SANDBOX}/status-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 = function definitions, $2 = what inbound_loaded should return.
set -euo pipefail
RC="$2"
source "$1"
have()           { [[ "$1" == nft ]]; }
table_loaded()   { return 1; }
netmode_state()  { printf 'online'; }
inbound_loaded() { return "${RC}"; }
curl()           { return 0; }
show_status
echo "STATUS-REACHED-THE-END"
PROBE
status_probe() { bash "${SANDBOX}/status-probe.sh" "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1; }
status_survives() {  # $1 = inbound_loaded's return, $2 = text it must report
  local out rc=0
  out="$(status_probe "$1")" || rc=$?
  (( rc == 0 )) || {
    printf 'status exited %s when inbound_loaded returned %s:\n%s\n' "${rc}" "$1" "${out}" >&2
    return 1
  }
  grep -q "$2" <<<"${out}" || {
    printf 'status did not report "%s":\n%s\n' "$2" "${out}" >&2; return 1; }
  grep -q 'STATUS-REACHED-THE-END' <<<"${out}" || {
    printf 'status stopped before the live probe:\n%s\n' "${out}" >&2; return 1; }
}
status_reports_a_missing_guard() { status_survives 1 'inbound guard NOT loaded'; }
status_reports_an_unknown_guard() { status_survives 2 'UNKNOWN'; }
check "'netmode status' reports a MISSING guard instead of dying" \
  status_reports_a_missing_guard
check "'netmode status' reports an UNKNOWN guard instead of dying" \
  status_reports_an_unknown_guard
require_probe() { bash "${SANDBOX}/require-probe.sh" "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1; }

harden_reports_a_failed_service_as_a_warning() {
  local out
  out="$(harden_probe 1)" || {
    printf 'harden exited non-zero because the boot service failed:\n%s\n' "${out}" >&2
    return 1
  }
  grep -q 'GUARD-APPLIED'      <<<"${out}" || return 1
  grep -q 'HARDEN-RETURNED-0'  <<<"${out}" || return 1
  # and it has to actually say so, or the reboot exposure is silent
  grep -qi 'reboot'            <<<"${out}" || {
    printf 'harden swallowed the boot-service failure without a word:\n%s\n' "${out}" >&2
    return 1
  }
}
harden_is_quiet_when_the_service_installs() {
  local out
  out="$(harden_probe 0)" || return 1
  ! grep -qi 'reboot' <<<"${out}"
}
# The same failure IS fatal where installing the unit is the whole job:
# setup.sh, offline and online all go through require_service.
require_service_still_dies() {
  local out
  out="$(require_probe 1)" && {
    printf 'require_service returned 0 on a failed install:\n%s\n' "${out}" >&2
    return 1
  }
  grep -q 'systemctl status local-code-agent-netmode' <<<"${out}"
}
fatal_callers_use_require_service() {
  local hits
  # go_offline, go_online and the --install-service dispatch, and nothing else.
  # Comments and the definition itself are stripped so only calls are counted.
  hits="$(grep -v '^[[:space:]]*#' "${REPO}/netmode.sh" \
            | grep -v 'require_service() {' \
            | grep -c 'require_service')"
  (( hits == 3 )) || { printf 'expected 3 require_service callers, found %s\n' "${hits}" >&2
                       return 1; }
}
check "harden warns (not fails) when only the boot service breaks" \
  harden_reports_a_failed_service_as_a_warning
check "harden says nothing about reboots when the service installs" \
  harden_is_quiet_when_the_service_installs
check "installing the unit is still fatal where that IS the job" \
  require_service_still_dies
check "offline, online and --install-service all go through require_service" \
  fatal_callers_use_require_service

# install_service checks every privileged step itself instead of leaning on
# errexit, because errexit is suppressed for any command whose status is
# tested — which is exactly how do_harden calls it. Without the explicit
# checks, a tee that never wrote the unit file would be followed by a
# successful enable and reported as a healthy install.
cat > "${SANDBOX}/service-probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1 = function definitions, $2 = the one privileged step to fail.
set -euo pipefail
BREAK="$2"
source "$1"
systemd_available() { return 0; }
as_root() {
  case " $* " in *" ${BREAK} "*) return 1 ;; esac
  # The real 'as_root tee' reads the unit text from a pipe. A stub that
  # returns without consuming it leaves the writer to take EPIPE, which
  # pipefail then reports as a failed install — at random, depending on who
  # wins the race. Drain it.
  case "$1" in tee) cat >/dev/null ;; esac
  return 0
}
install_service && echo "INSTALL-SAID-OK" || echo "INSTALL-SAID-FAILED"
PROBE
service_probe() {
  bash "${SANDBOX}/service-probe.sh" "${SANDBOX}/netmode-funcs.sh" "$1" 2>&1
}
step_failure_is_reported() {
  local out
  out="$(service_probe "$1")"
  grep -q 'INSTALL-SAID-FAILED' <<<"${out}" || {
    printf 'a failing "%s" was reported as a healthy install:\n%s\n' "$1" "${out}" >&2
    return 1
  }
}
tee_failure_is_reported()     { step_failure_is_reported tee; }
reload_failure_is_reported()  { step_failure_is_reported daemon-reload; }
enable_failure_is_reported()  { step_failure_is_reported enable; }
healthy_install_says_ok()     { grep -q 'INSTALL-SAID-OK' <<<"$(service_probe nothing-fails)"; }
check "a unit file that could not be written is a failed install" \
  tee_failure_is_reported
check "a daemon-reload that failed is a failed install" \
  reload_failure_is_reported
check "an enable that failed is a failed install" \
  enable_failure_is_reported
check "and an install where everything worked reports success" \
  healthy_install_says_ok

# --install-service is internal: setup.sh and CI call it, and netmode.sh's own
# usage does not list it. 'lca check' used to print it as the Fix: for a
# missing boot service, sending someone to a flag they cannot look up. Advice a
# human reads has to name a command that command's --help documents. Scoped to
# the surfaces that give advice — tune.sh documents its own flag, legitimately,
# and setup.sh/CI invoke both programmatically.
advice_names_only_documented_commands() {
  local hits
  hits="$(grep -n -- '--install-service' \
            "${REPO}/check-system.sh" "${REPO}/bin/lca" "${REPO}/README.md" \
            "${REPO}"/scripts/install_*.sh "${REPO}"/docs/*.md 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these send a user to the internal --install-service flag:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no user-facing message recommends the internal --install-service flag" \
  advice_names_only_documented_commands

# The general form of that rule, because finding these one at a time is how
# the last one survived: every 'some-script.sh --flag' this project puts in
# front of a human must be a flag that script actually documents. A doc that
# names a flag the script rejects is worse than no doc — the reader follows
# it, gets "Unknown option", and has no way to tell whether the feature or
# the sentence is the broken one.
#
# Scoped to the surfaces that only ever give advice. setup.sh and CI *invoke*
# these scripts, and an invocation is not a recommendation.
script_help_text() {  # header comment block + usage() body + any quoted line
  awk 'BEGIN { inhdr = 1 }
       NR == 1          { next }
       inhdr && /^#/    { print; next }
       inhdr            { inhdr = 0 }
       /^usage\(\) *\{/ { inu = 1; next }
       inu && /^\}/     { inu = 0; next }
       inu || /"/       { print }' "$1"
}
every_advised_flag_is_real() {
  local surfaces=( "${REPO}/README.md" "${REPO}"/docs/*.md "${REPO}/check-system.sh"
                   "${REPO}/bin/lca" "${REPO}/webui.sh" "${REPO}"/scripts/install_*.sh )
  local script flag path cand text unlisted=()
  while read -r script flag; do
    [[ -n "${script}" ]] || continue
    path=""
    for cand in "${REPO}/${script}" "${REPO}/scripts/${script}"; do
      if [[ -f "${cand}" ]]; then path="${cand}"; fi
    done
    if [[ -z "${path}" ]]; then
      unlisted+=("${script} ${flag} — no such script")
      continue
    fi
    text="$(script_help_text "${path}")"
    # if/fi, not '&& continue': a failing && list is only survivable because
    # check() tests this function's status and errexit is suppressed for it.
    # Written this way it does not depend on who calls it.
    if grep -qF -- "${flag}" <<<"${text}"; then
      continue
    fi
    # A script whose usage advertises '[... args...]' forwards what it does
    # not recognise (run-agent.sh hands everything to aider), so the flag
    # namespace is not its own to document.
    if grep -qE 'args\.\.\.\]' <<<"${text}"; then
      continue
    fi
    unlisted+=("${script} ${flag}")
  done < <(grep -rhoE '[a-z][a-z_-]*\.sh"? --[a-z-]+' "${surfaces[@]}" | tr -d '"' | sort -u)
  (( ${#unlisted[@]} == 0 )) || {
    printf 'advised flags that the script does not document:\n' >&2
    printf '  %s\n' "${unlisted[@]}" >&2
    return 1
  }
}
check "every flag we tell a human to run is one that script documents" \
  every_advised_flag_is_real

echo "# every 'lca' subcommand must answer --help, and only answer it"
# 'lca test --help' ran the whole acceptance suite: minutes of real generation,
# because selftest.sh never looked at "$@". 'lca restore --help' answered
# "Backup file not found: --help" — true, useless, and from a command that
# wipes a docker volume when it does work. 'lca webui --help' needed a running
# Docker daemon to print a page of text, on the machine where the daemon being
# down is what sent you looking for help in the first place.
#
# Run for real, not grepped: the claim is about what happens, and each of those
# three had a --help-shaped hole that reading the source did not make obvious.
# run-agent.sh is out — it forwards to aider, whose --help is aider's to print.
help_is_answered_not_performed() {
  local s out rc broken=()
  for s in "${LCA_TARGETS[@]}"; do
    # A timeout is part of the assertion: a script that ignores --help and does
    # its job is exactly the failure this catches, and some jobs take minutes.
    out="$(timeout 20 "${REPO}/${s}" --help 2>&1)"; rc=$?
    if (( rc != 0 )); then
      broken+=("${s}: --help exited ${rc}")
    elif ! grep -qi 'usage' <<<"${out}"; then
      # Not decoration: printing usage is how we tell "explained itself" from
      # "went and did the thing, successfully, and said so".
      broken+=("${s}: --help exited 0 but printed no usage")
    fi
  done
  (( ${#broken[@]} == 0 )) || {
    printf 'these do not answer --help:\n' >&2
    printf '  %s\n' "${broken[@]}" >&2
    return 1
  }
}
check "every script 'lca' dispatches to explains itself on --help" \
  help_is_answered_not_performed

# An option that takes a value must SAY SO when the value is missing.
#
# prompt-bench.sh read the value with "${2:-}" and shifted two arguments off a
# list holding one. shift failed, errexit ended the script, and the check that
# would have explained it sat two lines further down, unreachable. Measured
# before the fix: '-n', '-m' and '-f' each exited 1 with completely empty
# output, while '-n abc' explained itself perfectly — the guard existed and
# could not be got to.
#
# Driven, and the flags derived from the 'shift 2' arms themselves, so an
# option added later is covered without touching this. Every one of them fails
# before doing any work, which is what makes running them safe.
value_options_explain_a_missing_value() {
  local f flag out rc broken=() options=0
  for f in "${REPO}"/scripts/*.sh "${REPO}"/*.sh; do
    while IFS= read -r flag; do
      [[ -n "${flag}" ]] || continue
      options=$(( options + 1 ))
      out="$(timeout 20 "${f}" "${flag%%|*}" 2>&1)"; rc=$?
      if (( rc == 0 )); then
        broken+=("${f##*/} ${flag%%|*}: accepted a missing value")
      elif [[ -z "${out//[[:space:]]/}" ]]; then
        broken+=("${f##*/} ${flag%%|*}: exited ${rc} saying nothing at all")
      elif ! grep -qF -- "${flag%%|*}" <<<"${out}"; then
        # Non-zero with SOME message is not enough: a flag that quietly took a
        # default and let the script die further along on an unrelated cause
        # also exits non-zero and also prints something. The message has to
        # name the option the reader got wrong.
        broken+=("${f##*/} ${flag%%|*}: failed without naming the option — ${out%%$'\n'*}")
      fi
    # "Takes a value" is derived from the arm READING $2, not from the
    # 'shift 2' idiom that usually accompanies it. Keyed on the idiom, a
    # mutation that changes the shift form drops the option out of the list
    # and the gate quietly stops watching it — which is exactly what happened
    # while proving this one.
    done < <(sed 's/#.*//' "${f}" | awk '
      match($0, /^[[:space:]]*-[A-Za-z|-]+\)/) {
        lbl = substr($0, RSTART, RLENGTH); gsub(/[[:space:])]/, "", lbl); takes = 0
      }
      lbl != "" && /[$]\{?2[^0-9]/ { takes = 1 }
      lbl != "" && /;;/             { if (takes) print lbl; lbl = "" }')
  done
  (( options >= 4 )) || {
    printf 'only %s value-taking option(s) found — the extractor stopped matching\n' "${options}" >&2
    return 1; }
  (( ${#broken[@]} == 0 )) || {
    printf 'these take a value and say nothing when it is missing:\n' >&2
    printf '  %s\n' "${broken[@]}" >&2
    return 1
  }
}
check "an option that needs a value says so when it is missing" \
  value_options_explain_a_missing_value

# The three that 'lca' does NOT dispatch to are the three where this bug costs
# most, and none of them was covered: setup.sh installs packages and a model as
# root, install.sh clones over a directory, uninstall.sh deletes Ollama and
# every model. Two of the three are on record as having had exactly this hole —
# "'./setup.sh --help' began installing", "'./install.sh --help' had to be
# killed by a timeout, and left a checkout behind".
#
# install.sh runs for real but bounded: LCA_DIR and LCA_REPO_URL point into the
# sandbox, so a regression clones locally instead of into /opt. motd.sh is safe
# to run outright — it is gated elsewhere to write nothing at all.
HELP_SB="${SANDBOX}/helpsb"
mkdir -p "${HELP_SB}"
cp "${REPO}/install.sh" "${HELP_SB}/install.sh"
chmod +x "${HELP_SB}/install.sh"
answers_help() {  # description-only: runs CMD --help and checks it explains itself
  local out rc=0
  out="$(timeout 20 "$@" --help 2>&1)" || rc=$?
  (( rc == 0 )) || { printf '%s --help exited %s\n' "$1" "${rc}" >&2; return 1; }
  grep -qi 'usage' <<<"${out}" || {
    printf '%s --help exited 0 but printed no usage\n' "$1" >&2; return 1; }
}
install_answers_help() {
  LCA_DIR="${HELP_SB}/target" LCA_REPO_URL="${HELP_SB}/nonexistent.git" \
    answers_help "${HELP_SB}/install.sh"
}
check "setup.sh explains itself on --help"   answers_help "${REPO}/setup.sh"
check "install.sh explains itself on --help" install_answers_help
check "the login banner explains itself on --help" \
  answers_help "${REPO}/scripts/motd.sh"
# ...and nothing was cloned or installed while proving it.
check "install.sh --help touched nothing" test ! -e "${HELP_SB}/target"
# ...and it has to explain itself through the PIPE it is advertised with, which
# is not the same invocation. 'curl -fsSL <url>/install.sh | bash' streams the
# script into bash, and inside a function BASH_SOURCE[0] is then the literal
# string 'main' — bash's placeholder for a stdin script, measured on 5.2.21.
# The usage function had no file to read, so the documented one-liner answered:
#
#   $ curl -fsSL <url>/install.sh | bash -s -- --help
#   sed: can't read main: No such file or directory
#   exit=1
#
# ...on the first command anyone runs, from the invocation the README leads
# with. Driven through a redirect rather than a real pipe: bash reads the whole
# script either way, and it reproduces the failure identically (checked against
# the unfixed file), without adding a producer this suite would then have to
# reason about.
install_help_survives_the_pipe() {
  local out rc=0
  out="$(LCA_DIR="${HELP_SB}/target" LCA_REPO_URL="${HELP_SB}/nonexistent.git" \
         timeout 20 bash -s -- --help < "${HELP_SB}/install.sh" 2>&1)" || rc=$?
  (( rc == 0 )) || {
    printf 'piped --help exited %s: %s\n' "${rc}" "${out}" >&2; return 1; }
  # The exact failure, named: 'main' is not a path, and sed said so.
  ! grep -q "can't read" <<<"${out}" || {
    printf 'piped --help still tries to read a file that is not there: %s\n' "${out}" >&2
    return 1; }
  # It must say something useful, not just exit quietly — and the useful thing
  # is how to get the real help, since the stream it would have read is gone.
  grep -q 'install.sh' <<<"${out}" || {
    printf 'piped --help printed nothing that names this script: %s\n' "${out}" >&2
    return 1; }
  grep -qi 'curl' <<<"${out}" || {
    printf 'piped --help does not say how to fetch a readable copy: %s\n' "${out}" >&2
    return 1; }
}
check "...and explains itself through the curl | bash pipe too" \
  install_help_survives_the_pipe
# ...without that becoming the answer everywhere. Read from a real file it must
# still print the header block, or the fallback has quietly replaced the help.
install_help_from_a_file_is_the_real_thing() {
  local out
  out="$(LCA_DIR="${HELP_SB}/target" LCA_REPO_URL="${HELP_SB}/nonexistent.git" \
         timeout 20 bash "${HELP_SB}/install.sh" --help 2>&1)"
  grep -q 'LCA_BRANCH' <<<"${out}" || {
    printf 'the file-backed --help no longer prints the header block: %s\n' "${out}" >&2
    return 1; }
}
check "...while a readable copy still prints the full header" \
  install_help_from_a_file_is_the_real_thing
# ...and 'main' is excluded by NAME as well as by -r, because it is a path as
# far as the shell is concerned. Found while mutating the guard away: with only
# the -r test, a file called 'main' in the working directory is read and
# printed as this installer's help. Measured, in a directory holding one:
#
#   $ bash -s -- --help < install.sh
#   NOT the installer help
#
# Which is a stranger's text presented as the installer's own, on the command
# people run to decide whether to trust it.
install_help_ignores_a_file_called_main() {
  local d="${HELP_SB}/mainprobe" out
  rm -rf "${d}"; mkdir -p "${d}"
  printf '#\n# NOT the installer help\n#\nx\n' > "${d}/main"
  out="$( cd "${d}" && LCA_DIR="${d}/target" LCA_REPO_URL="${d}/nonexistent.git" \
          timeout 20 bash -s -- --help < "${HELP_SB}/install.sh" 2>&1 )"
  rm -rf "${d}"
  ! grep -q 'NOT the installer help' <<<"${out}" || {
    printf "a file called 'main' in the working directory was printed as the installer's help: %s\\n" "${out}" >&2
    return 1
  }
}
check "...and a file called 'main' nearby is not mistaken for the script" \
  install_help_ignores_a_file_called_main

# uninstall.sh is asserted statically, deliberately. Running it cannot be
# bounded the way install.sh can: it does not act on a directory this test
# could redirect, it acts on the machine — nft tables, systemd units, the
# Docker volume. A regression there would delete the tester's own stack, which
# is too high a price for the coverage. So: the option is answered, and it is
# answered before anything else in main.
uninstall_answers_help_first() {
  awk '/^main\(\) \{/ { inb = 1; next }
       inb && /^[[:space:]]*#/ { next }
       inb && /-h\|--help/ { found = NR; exit }
       inb && /(as_root|rm -rf|docker|systemctl|nft )/ { exit }
       END { exit !found }' "${REPO}/uninstall.sh" || {
    echo 'uninstall.sh reaches a side effect before it answers --help' >&2
    return 1; }
}
check "uninstall.sh answers --help before any side effect" uninstall_answers_help_first
# ...and the list above has to stay the list. bin/lca gaining a subcommand
# whose script is never asked is how the next selftest.sh happens.
every_dispatch_target_is_checked() {
  local target missing=()
  while read -r target; do
    [[ -n "${target}" ]] || continue
    [[ "${target}" == "run-agent.sh" ]] && continue
    printf '%s\n' "${LCA_TARGETS[@]}" | grep -qx "${target}" || missing+=("${target}")
  done < <(grep -oE '\$\{REPO\}/[a-z/-]+\.sh' "${REPO}/bin/lca" \
             | sed 's|[$]{REPO}/||' | sort -u)
  (( ${#missing[@]} == 0 )) || {
    printf 'bin/lca dispatches to these, and no --help test covers them:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  }
}
check "the --help list covers everything bin/lca dispatches to" \
  every_dispatch_target_is_checked

# The two that are NOT dispatched, and are the worst of the lot: './install.sh
# --help' installed packages and cloned into ${LCA_DIR}, and './setup.sh
# --help' began installing the whole stack as root. Both were found by running
# them — each had to be killed by a timeout, and the first left a checkout on
# disk.
#
# Structural, not behavioural. Everywhere else the --help check runs the
# script, because the claim is about what happens; here a failing check would
# install packages as root on whoever ran the suite, which is worse than the
# bug it guards. So it asserts the shape that produces the behaviour — the
# --help branch must be the FIRST thing main() does, above every side effect —
# and the behaviour itself was verified by hand once the shape was in place.
installers_answer_help_before_acting() {
  local f
  # deploy/do-user-data.sh joined this list, as the fourth entry point and the
  # one that was worst off: it did not even RECEIVE its arguments — the last
  # line called 'main' without "$@" — so --help ran the full unattended
  # install. Measured, apt stubbed and the clone pointed at a local mirror:
  # apt-get, a 33 MB clone, and /etc/update-motd.d rewritten, which is how it
  # was noticed at all.
  for f in install.sh setup.sh deploy/do-user-data.sh; do
    awk '/^main\(\) \{/            { inm = 1; next }
         inm && /^[[:space:]]*#/   { next }
         inm && /^[[:space:]]*$/   { next }
         inm                       { first = $0; exit }
         END { exit !(first ~ /case "\$\{1:-\}" in/) }' "${REPO}/${f}" || {
      printf '%s: main() does something before it checks for --help\n' "${f}" >&2
      return 1
    }
  done
}
check "install.sh, setup.sh and the first-boot script explain themselves before they install anything" \
  installers_answer_help_before_acting
# ...and the flag has to REACH main(), which is a separate fault from handling
# it. do-user-data.sh's last line was 'main 2>&1 | tee ...' — arguments dropped
# on the floor — so a --help case inside main would have been dead code.
entry_points_forward_their_arguments() {
  local f last bad=0
  for f in install.sh deploy/do-user-data.sh; do
    last="$(grep -vE '^\s*(#|$)' "${REPO}/${f}" | tail -1)"
    [[ "${last}" == *'main "$@"'* ]] || {
      printf '%s calls main without "$@" — every flag it accepts is unreachable: %s\n' \
        "${f}" "${last}" >&2
      bad=1
    }
  done
  return "${bad}"
}
check "...and the arguments actually reach main()" \
  entry_points_forward_their_arguments
# ...and asking must still touch nothing. Pointed at a repository that cannot
# exist, so even a regression cannot get as far as the clone — and therefore
# cannot rewrite /etc/update-motd.d on the machine running the tests, which a
# probe of this exact script did while it was being written.
first_boot_help_touches_nothing() {
  local sb="${SANDBOX}/dudhelp" out rc=0
  rm -rf "${sb}"; make_stub_dir "${sb}/stub"
  printf '#!/bin/sh\necho "(apt-get ran)"\nexit 0\n' > "${sb}/stub/apt-get"
  chmod +x "${sb}/stub/apt-get"
  # shellcheck disable=SC2031  # a one-command env prefix, not a subshell edit
  out="$(PATH="${sb}/stub:${PATH}" LCA_REPO_URL="${sb}/nonexistent.git" \
         LCA_DIR="${sb}/target" LCA_LOG="${sb}/log" \
         timeout 60 bash "${REPO}/deploy/do-user-data.sh" --help 2>&1)" || rc=$?
  (( rc == 0 )) || {
    printf 'do-user-data.sh --help exited %s: %s\n' "${rc}" "${out}" >&2; return 1; }
  grep -q 'first-boot installer' <<<"${out}" || {
    printf 'do-user-data.sh --help printed no usage: %s\n' "${out}" >&2; return 1; }
  grep -q 'apt-get ran' <<<"${out}" && {
    printf 'do-user-data.sh --help ran apt: %s\n' "${out}" >&2; return 1; }
  [[ ! -e "${sb}/target" ]] || {
    echo 'do-user-data.sh --help cloned the repository' >&2; return 1; }
}
check "...and the first-boot script's --help installs nothing" \
  first_boot_help_touches_nothing

# The scripts answering --help only helps if the flag reaches them. 'chat' was
# 'exec webui.sh url' with no "$@", so 'lca chat --help' printed the chat
# address — one line after 'lca help' promises every command explains itself.
every_dispatch_forwards_its_arguments() {
  local hits
  hits="$(grep -nE '^[[:space:]]*[^#]*exec "\$\{REPO\}/[a-z/-]+\.sh"' "${REPO}/bin/lca" \
            | grep -v '"\$@"' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these swallow the arguments, so --help never reaches the script:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "every 'lca' branch passes its arguments through" \
  every_dispatch_forwards_its_arguments

# netmode.sh takes its subcommand as $1 and used to ignore everything after
# it, while bin/lca forwards trailing arguments verbatim. So 'lca harden
# --help' arrived as 'netmode.sh harden --help' and APPLIED THE FIREWALL —
# the same bug as selftest.sh, on the one command where doing the thing
# instead of describing it changes the machine's network.
#
# Exercised through 'status', which only reads. That is deliberate: if this
# check ever fails it must fail harmlessly, and a test that proves 'harden
# --help' is safe by running 'harden' would be its own worst outcome. The
# guard is one branch, so status proves it for all four.
netmode_help_is_not_an_action() {
  local out rc
  out="$(timeout 20 "${REPO}/netmode.sh" status --help 2>&1)"; rc=$?
  (( rc == 0 )) || {
    printf 'netmode.sh status --help exited %s:\n%s\n' "${rc}" "${out}" >&2
    return 1
  }
  grep -q 'Kill-switch ON' <<<"${out}" || {
    printf 'netmode.sh status --help did not print usage:\n%s\n' "${out}" >&2
    return 1
  }
  # 'netmode:' is what show_status prints; usage never does. Its presence means
  # the flag was ignored and the subcommand ran.
  ! grep -q 'netmode:' <<<"${out}"
}
# ...and the check has to sit ABOVE the dispatch, or it guards nothing.
netmode_checks_args_before_acting() {
  awk '/^main\(\) \{/                 { inm = 1 }
       inm && /case "\$\{2:-\}" in/   { second = NR }
       inm && /case "\$\{1:-\}" in/   { first = NR; exit }
       END { exit !(second && first && second < first) }' "${REPO}/netmode.sh"
}
check "'lca harden --help' explains the firewall instead of applying it" \
  netmode_help_is_not_an_action
check "netmode validates its extra argument before it dispatches" \
  netmode_checks_args_before_acting

echo "# advice has to work from where the reader is standing"
# bin/lca never cd's — that is the whole point, aider must see YOUR project —
# so 'lca check' from ~/my-project ran a health check that answered
# "(./webui.sh start)" and "run scripts/tune.sh". Neither resolves there. The
# reader types it, gets "No such file or directory", and now has two problems.
# Every path a message names must be absolute.
advice_paths_are_absolute() {
  local hits
  # Message helpers only: an 'echo' inside a render function is writing a file,
  # not talking to anyone. ${SCRIPT_DIR}/${REPO_ROOT} are erased first so an
  # already-absolute path cannot match, then anything relative still standing
  # is a defect.
  hits="$(grep -nE '\b(warn|info|die|err|ok|p_pass|p_warn|p_fail)[[:space:]]+"' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
          | sed 's|[$]{SCRIPT_DIR}||g; s|[$]{REPO_ROOT}||g' \
          | grep -E '(\./|[[:space:]("'"'"']scripts/)[a-z_-]+\.sh' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these name a path that only resolves inside the checkout:\n%s\n' "${hits}" >&2
    return 1
  }
  # A bare script name is the same defect wearing no prefix. 'lca model
  # --list-recommended' answered "Switch with:  update-model.sh <model>",
  # which matches neither './' nor 'scripts/' and so read as ordinary prose to
  # the scan above — while being a command, for a file that is not on PATH and
  # not in the reader's directory. Only imperative phrasings count: "setup.sh
  # will pull ${MODEL}" describes what happens and is not an instruction.
  hits="$(grep -nE '\b(warn|info|die|err|ok|p_pass|p_warn|p_fail)[[:space:]]+"' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
          | sed 's|[$]{SCRIPT_DIR}||g; s|[$]{REPO_ROOT}||g' \
          | grep -oiE "(run|re-run|check|try|with|usage)['\":]? +[a-z][a-z_-]*\.sh" || true)"
  [[ -z "${hits}" ]] || {
    printf 'these tell the reader to run a bare script name:\n%s\n' "${hits}" >&2
    return 1
  }
  # Usage text is advice too, and it is not written with a message helper —
  # webui.sh's ended with "run: scripts/install_webui.sh" and slipped straight
  # past the scan above. Scoped to what 'lca' dispatches to, because that is
  # the rule: those run in the user's directory. scripts/prompt-bench.sh names
  # itself relatively and may, being a 'make bench' tool run from the checkout.
  # A one-line 'usage() { ...; }' closes on its own line, so the extractor has
  # to stop there. Without that branch it ran on to main()'s closing brace and
  # scanned the whole function as if it were help text — update.sh is written
  # that way, and it passed only because nothing in main() happened to match.
  local s body
  for s in "${LCA_TARGETS[@]}"; do
    body="$(awk '/^usage\(\) *\{/ { if ($0 ~ /\}[[:space:]]*$/) { print; next }
                                    inu = 1; next }
                 inu && /^\}/     { inu = 0; next }
                 inu              { print }' "${REPO}/${s}" \
              | sed 's|[$]{SCRIPT_DIR}||g; s|[$]{REPO_ROOT}||g')"
    hits="$(grep -E '(\./|[[:space:]("]scripts/)[a-z_-]+\.sh' <<<"${body}" || true)"
    [[ -z "${hits}" ]] || {
      printf '%s prints usage text naming a path that only resolves inside the checkout:\n%s\n' \
        "${s}" "${hits}" >&2
      return 1
    }
    # Bare names too. 'lca model' opened with "Usage: update-model.sh <model>",
    # six times over, for a file that is not on PATH — and neither the path
    # rule (no './' or 'scripts/' to match) nor the message-helper rule (usage
    # is a heredoc, not a warn) could see it. Imperative phrasings only, so
    # "(or webui.sh directly)" stays legal: that tells you what the script is
    # called, it does not ask you to type it.
    hits="$(grep -iE "(run|re-run|check|try|with|usage)['\":]? +[a-z][a-z_-]*\.sh" <<<"${body}" || true)"
    [[ -z "${hits}" ]] || {
      printf '%s prints usage text telling the reader to run a bare script name:\n%s\n' \
        "${s}" "${hits}" >&2
      return 1
    }
  done
}
check "every path a message names resolves from any directory" \
  advice_paths_are_absolute

# The same rule for the docs, where it takes a different shape: a fenced block
# may say './setup.sh' — there is no 'lca' equivalent and there cannot be one
# before the install — but then the block has to put the reader in the right
# directory first. Everything with an 'lca' subcommand uses that instead, which
# needs no cd at all.
doc_blocks_establish_their_directory() {
  local hits
  hits="$(awk '
    FNR == 1 { inb = 0; usesrel = 0; hascd = 0 }
    /^```/ {
      if (inb) {
        if (usesrel && !hascd)
          printf "%s:%d: this block runs ./script.sh without a cd\n", FILENAME, start
        inb = 0; usesrel = 0; hascd = 0
      } else { inb = 1; start = FNR }
      next
    }
    inb && /(^|[[:space:]])\.\/[a-z_-]+\.sh/ { usesrel = 1 }
    inb && /^[[:space:]]*cd /                { hascd = 1 }
  ' "${REPO}/README.md" "${REPO}"/docs/*.md)"
  [[ -z "${hits}" ]] || {
    printf 'a reader following these would be in the wrong directory:\n%s\n' "${hits}" >&2
    return 1
  }
  # And in prose, where a block's cd cannot help: INSTALL.md taught "Daily
  # usage: `run-agent.sh` in any project directory", which is the right idea
  # attached to a name that is not on PATH — 'lca' is the command that exists
  # for exactly that. Imperative phrasings only, so that describing a file
  # ("`scripts/install_webui.sh` now refuses to start on a taken port") stays
  # legal; it is a statement about the code, not an instruction.
  hits="$(grep -rniE "(run|re-run|check|try|with|usage)['\":\` ]+ ?[a-z][a-z_-]*\.sh" \
            "${REPO}/README.md" "${REPO}"/docs/*.md 2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these docs tell the reader to run a name that is not on PATH:\n%s\n' "${hits}" >&2
    return 1
  }
}
check "every doc block that runs a script says where to stand" \
  doc_blocks_establish_their_directory

echo "# the 'lca' command is a symlink, and a moved checkout leaves it dangling"
# Every doc and message here says "type lca". Move the checkout and the symlink
# dangles — including 'lca check', which is exactly what someone reaches for
# when the stack seems broken. Real symlinks, because the whole question is
# what readlink and -x do with them.
LINKS="${SANDBOX}/links"
mkdir -p "${LINKS}/real/bin" "${LINKS}/other/bin"
printf '#!/usr/bin/env bash\n' > "${LINKS}/real/bin/lca"
printf '#!/usr/bin/env bash\n' > "${LINKS}/other/bin/lca"
chmod +x "${LINKS}/real/bin/lca" "${LINKS}/other/bin/lca"
ln -s "${LINKS}/real/bin/lca"  "${LINKS}/ok"
ln -s "${LINKS}/other/bin/lca" "${LINKS}/foreign"
ln -s "${LINKS}/gone/bin/lca"  "${LINKS}/moved"     # whole checkout renamed
ln -s "${LINKS}/real/bin/nope" "${LINKS}/deleted"   # just the file removed
printf 'not a link\n' > "${LINKS}/plain"
state_of() { lca_link_state "${LINKS}/$1" "${LINKS}/real/bin/lca"; }
check "a link into this checkout is ok"          test "$(state_of ok)"      = ok
check "a renamed checkout reads as broken"       test "$(state_of moved)"   = broken
check "a deleted target reads as broken too"     test "$(state_of deleted)" = broken
check "a link into another checkout is foreign"  test "$(state_of foreign)" = foreign
check "a real file at that path is not ours"     test "$(state_of plain)"   = other
check "nothing there at all is absent"           test "$(state_of nowhere)" = absent
# The comparison has to survive the two sides being spelled differently.
# check-system.sh builds its side with 'cd && pwd', which keeps a symlinked
# path, while readlink -f hands back the physical one — so an install reached
# through a symlinked parent would read as 'foreign' and shout about a healthy
# machine.
ln -s "${LINKS}/real" "${LINKS}/real-alias"
check "a checkout reached through a symlinked parent is still ok" \
  test "$(lca_link_state "${LINKS}/ok" "${LINKS}/real-alias/bin/lca")" = ok
lca_link_is_reported() { grep -q 'lca_link_state' "${REPO}/check-system.sh"; }
check "check-system.sh reports on the lca command" lca_link_is_reported

echo "# two installers that destroyed something they could not put back"
port_is_checked_before_the_container_is_destroyed() {
  # The old order removed our container first so its own listener could not
  # trip the port check — at the cost that a port held by anyone ELSE meant a
  # working chat app was deleted and then not replaced, by the one command
  # whose job is to replace it.
  awk '/^[[:space:]]*#/ { next }
       /ss -ltn/            { if (!removed) checked = NR }
       /docker rm -f "\$\{WEBUI_CONTAINER\}"/ { removed = NR }
       END { exit !(checked && removed && checked < removed) }' \
    "${REPO}/scripts/install_webui.sh" || {
    echo 'install_webui.sh destroys the container before it checks the port is free' >&2
    return 1; }
}
venv_without_pip_is_rebuilt() {
  # bin/python existing is not a usable venv: an interrupted 'python -m venv'
  # leaves it with no pip, which passed as "already exists" and then failed on
  # every re-run for ever.
  local body
  body="$(grep -v '^[[:space:]]*#' "${REPO}/scripts/install_python.sh")"
  grep -q 'm pip --version' <<<"${body}" || {
    echo 'install_python.sh reuses a venv without checking pip works' >&2; return 1; }
  grep -q 'venv --clear' <<<"${body}" || {
    echo 'install_python.sh rebuilds a broken venv in place instead of clearing it' >&2; return 1; }
}
# ...and a venv really can exist without pip, which is the premise.
venv_can_lack_pip() {
  # Deliberately NOT named bin/python: the "nothing re-types the venv
  # interpreter path" gate scans every script for that path, and a fixture
  # spelling it out trips a rule this file is not breaking. The name is
  # irrelevant to what is being shown.
  local interp="${SANDBOX}/interp-without-pip"
  printf '#!/bin/sh\nexit 1\n' > "${interp}"; chmod +x "${interp}"
  [[ -x "${interp}" ]] && ! "${interp}" -m pip --version >/dev/null 2>&1
}
check "the chat app port is checked before the container is removed" \
  port_is_checked_before_the_container_is_destroyed
check "a venv with no working pip is rebuilt, not reused"  venv_without_pip_is_rebuilt
# ...and a venv that cannot be created must name the cause it actually found.
# One message covered both failures: "Could not create a virtualenv. On
# Debian/Ubuntu install it with: sudo apt-get install -y python3-venv".
# Measured as an ordinary user against a checkout owned by root — which is
# exactly what 'sudo setup.sh' leaves behind:
#
#   Error: [Errno 13] Permission denied: '.../.venv'
#   [FAIL] Could not create a virtualenv. On Debian/Ubuntu install it with:
#          sudo apt-get install -y python3-venv
#
# python3-venv is already installed; it got far enough to try. And this is the
# command scripts/selftest.sh sends people to when aider is missing, so it is
# read by someone who is already stuck.
#
# venv_target_writable is stubbed rather than tested through a real directory:
# as root '[[ -w ]]' is true for every path, so a suite running as root could
# never reach one branch and a suite running as anyone else could never reach
# the other. A test whose result depends on WHO runs it is the environment
# dependence this branch has been bitten by three times.
venv_failure_says() {  # writable(yes|no) -> the message
  bash -c '
    source "$1" >/dev/null 2>&1
    if [[ "$2" == "yes" ]]; then venv_target_writable() { return 0; }
    else venv_target_writable() { return 1; }; fi
    venv_create_failed /some/checkout/.venv 2>&1' \
    _ "${REPO}/scripts/install_python.sh" "$1" 2>&1
}
venv_failure_names_the_real_cause() {
  local out bad=0
  out="$(venv_failure_says no)"
  grep -q 'not writable' <<<"${out}" || {
    printf 'an unwritable checkout is not reported as one: %s\n' "${out}" >&2; bad=1; }
  grep -qi 'sudo' <<<"${out}" || {
    printf 'it does not say to re-run with sudo: %s\n' "${out}" >&2; bad=1; }
  grep -q 'python3-venv' <<<"${out}" && {
    printf 'an unwritable checkout is still blamed on a missing package: %s\n' "${out}" >&2; bad=1; }
  # ...and the package advice must survive where it IS the likely cause.
  out="$(venv_failure_says yes)"
  grep -q 'python3-venv' <<<"${out}" || {
    printf 'a writable checkout no longer gets the venv-module advice: %s\n' "${out}" >&2; bad=1; }
  grep -q 'not writable' <<<"${out}" && {
    printf 'a writable checkout is reported as unwritable: %s\n' "${out}" >&2; bad=1; }
  return "${bad}"
}
check "a virtualenv that cannot be created names the cause it found" \
  venv_failure_names_the_real_cause

# ...and an apt step that failed because sudo could not ask for a password
# must say so, rather than guessing at the two causes it did not check.
# Measured as an ordinary user with no terminal, running the script netmode.sh
# names WITHOUT sudo:
#
#   sudo: a terminal is required to read the password ...
#   sudo: a password is required
#   [FAIL] apt update failed. Another apt/dpkg process held the lock past the
#          timeout (see docs/TROUBLESHOOTING.md) or the network is down.
#
# No lock was held and the network was fine. sudo had just said what was wrong
# and the project's own message talked over it, sending the reader to a
# troubleshooting page about a lock nobody held.
sudo_block_says() {  # ROOT_NOW CAN_ROOT TTY -> yes|no
  bash -c '
    source "$1" >/dev/null 2>&1
    RN="$2"; CR="$3"; TT="$4"
    can_root_now() { [[ "${RN}" == "yes" ]]; }
    can_root()     { [[ "${CR}" == "yes" ]]; }
    # have_terminal, not a re-declared sudo_would_block. Stubbing the whole
    # predicate for the terminal case meant the real one was never run there,
    # and a mutation replacing its tty test with "return 0" came back NOT
    # CAUGHT — the gate was testing its own stub.
    have_terminal() { [[ "${TT}" == "yes" ]]; }
    if sudo_would_block; then echo yes; else echo no; fi' \
    _ "${SANDBOX}/scripts/lib.sh" "$1" "$2" "$3" 2>/dev/null
}
sudo_would_block_answers() {
  local bad=0
  # The measured case: sudo present, needs a password, nothing to type into.
  [[ "$(sudo_block_says no yes no)" == "yes" ]] || {
    echo 'sudo needing a password with no terminal is not recognised' >&2; bad=1; }
  # Already root, or passwordless sudo — nothing is blocked.
  [[ "$(sudo_block_says yes yes no)" == "no" ]] || {
    echo 'a root (or passwordless-sudo) run is reported as blocked' >&2; bad=1; }
  # No sudo at all: as_root's own message is better than anything this could
  # add, so this must stand aside rather than pre-empt it.
  [[ "$(sudo_block_says no no no)" == "no" ]] || {
    echo 'a box with no sudo is claimed as a password problem, pre-empting as_root' >&2; bad=1; }
  # A terminal is present: sudo can and will ask, so nothing is blocked.
  [[ "$(sudo_block_says no yes yes)" == "no" ]] || {
    echo 'a run with a terminal is reported as blocked, though sudo could ask' >&2; bad=1; }
  return "${bad}"
}
check "'sudo will need a password and there is no terminal' is its own answer" \
  sudo_would_block_answers
# ...and the one line the harness has to stub, pinned directly. Asserted with
# an explicit '< /dev/null' rather than on the suite's own stdin: run from an
# interactive shell that IS a terminal, and a test written the obvious way
# would fail on the maintainer's machine and pass in CI.
have_terminal_knows_a_pipe_is_not_one() { ! have_terminal < /dev/null; }
check "...and have_terminal says no when stdin is not a terminal" \
  have_terminal_knows_a_pipe_is_not_one

# ...and a .env write that failed must say WHICH failure it was.
#
# "a full disk is the usual cause, so check 'df -h' ... re-run once there is
# room" was the only explanation, and it is the wrong one for anybody using a
# checkout they do not own — every ordinary user of a stack installed with
# 'sudo setup.sh'. Measured as such a user, running what 'lca tune' and
# 'lca model' both call:
#
#   sed: couldn't open temporary file .../sedlOoIFn: Permission denied
#   [FAIL] Could not write MODEL_NAME to .../.env (sed exited 4) — a full disk
#          is the usual cause ... re-run once there is room.
#
# There was room. sed had said "Permission denied" one line earlier.
#
# writable_by_us is stubbed rather than tested through a real directory,
# because as root '[[ -w ]]' is true for every path — a test that depended on
# who ran it could only ever reach one of these two branches.
env_write_failure_says() {  # writable(yes|no) -> the message
  bash -c '
    source "$1" >/dev/null 2>&1
    load_env >/dev/null 2>&1
    case "$2" in
      yes)     writable_by_us() { return 0; } ;;
      no)      writable_by_us() { return 1; } ;;
      # The .env itself writable, the DIRECTORY it lives in not. sed -i writes
      # its temp file next to the target — that is the exact operation the
      # measured error named — so only the directory check catches this, and
      # without the case a mutation dropping that check passes.
      dironly) writable_by_us() { [[ "$1" == *".env" ]]; } ;;
    esac
    # A write that fails for reasons this test does not care about; the point
    # is which explanation comes back.
    set_env_var() { return 4; }
    write_env_or_die MODEL_NAME something 2>&1' \
    _ "${SANDBOX}/scripts/lib.sh" "$1" 2>&1
}
env_write_failure_names_the_cause() {
  local out bad=0
  out="$(env_write_failure_says no)"
  grep -q 'cannot write there' <<<"${out}" || {
    printf 'an unwritable checkout is not reported as one: %s\n' "${out}" >&2; bad=1; }
  grep -qi 'sudo' <<<"${out}" || {
    printf 'it does not say to re-run with sudo: %s\n' "${out}" >&2; bad=1; }
  grep -q 'full disk' <<<"${out}" && {
    printf 'an unwritable checkout is still blamed on a full disk: %s\n' "${out}" >&2; bad=1; }
  # An unwritable DIRECTORY with a writable .env inside it: sed still cannot
  # write, and only the directory half of the check sees it.
  out="$(env_write_failure_says dironly)"
  grep -q 'cannot write there' <<<"${out}" || {
    printf 'an unwritable directory holding a writable .env is blamed on the disk — sed writes its temp file there: %s\n' "${out}" >&2
    bad=1; }
  # ...and the disk explanation must survive where it IS the likely cause, or
  # this has simply replaced one guess with another.
  out="$(env_write_failure_says yes)"
  grep -q 'full disk' <<<"${out}" || {
    printf 'a writable checkout no longer gets the disk explanation: %s\n' "${out}" >&2; bad=1; }
  grep -q 'cannot write there' <<<"${out}" && {
    printf 'a writable checkout is reported as unwritable: %s\n' "${out}" >&2; bad=1; }
  # Both must promise the file is untouched: that is the reason a reader can
  # retry at all.
  grep -qi 'nothing was changed\|left exactly as it was' <<<"${out}" || {
    printf 'the disk message no longer says the file is unchanged: %s\n' "${out}" >&2; bad=1; }
  return "${bad}"
}
check "a .env write that failed says whether it was permission or disk" \
  env_write_failure_names_the_cause
apt_failure_checks_sudo_first() {
  local body
  body="$(sed -n '/if ! apt_get update -y; then/,/^  fi$/p' \
          "${REPO}/scripts/install_dependencies.sh" | sed 's/^[[:space:]]*#.*//')"
  [[ -n "${body}" ]] || {
    echo "could not find install_dependencies.sh's apt-update branch — this gate stopped watching" >&2
    return 1; }
  grep -q 'sudo_would_block' <<<"${body}" || {
    echo 'install_dependencies.sh blames the dpkg lock and the network without asking whether sudo could run at all' >&2
    return 1; }
  # ...and the lock/network message must survive, because it is right whenever
  # sudo was not the problem.
  grep -q 'held the lock' <<<"${body}" || {
    echo 'the dpkg-lock explanation was lost — it is still the right answer when root was available' >&2
    return 1; }
  # The order matters: the guess must not be reached before the fact.
  local n_sudo n_lock line n=0
  n_sudo=0; n_lock=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "${line}" == *sudo_would_block* && ${n_sudo} -eq 0 ]]; then n_sudo="${n}"; fi
    if [[ "${line}" == *"held the lock"* && ${n_lock} -eq 0 ]]; then n_lock="${n}"; fi
  done <<<"${body}"
  (( n_sudo > 0 && n_sudo < n_lock )) || {
    echo 'the dpkg-lock guess is reached before the sudo question is asked' >&2
    return 1; }
}
check "...and the apt failure asks that before blaming the lock or the network" \
  apt_failure_checks_sudo_first

# ...and no message may send someone to a script that needs root without
# telling them so. That advice is how the misleading apt failure above was
# reached in the first place: netmode.sh says "Install nftables
# (scripts/install_dependencies.sh)" — no sudo — and following it literally is
# what produced a complaint about a dpkg lock nobody held.
#
# Eighteen messages named one of the six root-requiring installers that way,
# and seven more named setup.sh. The convention already existed: the login
# banner and check-system.sh both write 'sudo .../setup.sh'.
#
# install_python.sh is deliberately NOT in the list. It writes the virtualenv
# as the invoking user and needs root only when the checkout is owned by
# someone else — which it now says itself, naming sudo at the moment that is
# actually true. Requiring sudo in every mention would tell people to create a
# root-owned venv they did not need.
root_scripts_are_advised_with_sudo() {
  local f body line bad=0 seen=0
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh; do
    body="$(sed 's/^[[:space:]]*#.*//' "${f}")"
    while IFS= read -r line; do
      # Only MESSAGES — a bare invocation is the script running the installer
      # itself, where sudo would be wrong (setup.sh already runs as root).
      [[ "${line}" =~ (warn|die|info|err|p_warn|p_fail|p_info|ok)[[:space:]]+\" ]] || continue
      # Path-prefixed only. A mention without one is describing the script,
      # not telling anyone to run it — tune.sh says "setup.sh will pull
      # ${TUNE_MODEL}", which is a statement about what happens next and would
      # read as nonsense with a sudo in front of it. The gate flagged exactly
      # that on its first run.
      [[ "${line}" =~ \$\{(SCRIPT_DIR|REPO_ROOT)\}/(scripts/)?(setup\.sh|install_(dependencies|docker|git|ollama|tailscale|webui)\.sh) ]] || continue
      seen=$((seen + 1))
      [[ "${line}" == *"sudo \${"* ]] && continue
      printf '%s advises a script that needs root without sudo:\n  %s\n' \
        "${f##*/}" "${line#"${line%%[![:space:]]*}"}" >&2
      bad=1
    done <<<"${body}"
  done
  (( seen >= 15 )) || {
    printf 'only %s such messages found — this gate stopped watching\n' "${seen}" >&2
    return 1
  }
  return "${bad}"
}
check "advice naming a script that needs root says sudo" \
  root_scripts_are_advised_with_sudo
# ...and install_python.sh must still RUN when executed, not only be sourceable.
check "install_python.sh still runs main when executed" \
  grep -qE '^  main "\$@"$' "${REPO}/scripts/install_python.sh"
check "an interpreter can exist with no usable pip"        venv_can_lack_pip

echo "# three claims the code one function away already contradicted"
guard_message_names_only_guarded_ports() {
  # render_inbound_rules REFUSES port 22, and the success line said "WebUI
  # (port 22) ... reachable only via loopback and Tailscale" about a port
  # deliberately left wide open — the one sentence here that must never be
  # wrong. It builds the list from what was actually guarded now.
  awk '/^apply_inbound_guard\(\) \{/ { inb = 1 }
       inb && /^\}/ { exit }
       inb && /^[[:space:]]*#/ { next }
       inb && /guard_wp}" != "22"/ { found = 1 }
       END { exit !found }' "${REPO}/netmode.sh" || {
    echo 'the guard success message names ports without checking 22 was refused' >&2
    return 1; }
}
listing_flags_models_that_do_not_fit() {
  # 'lca model --list-recommended' printed deepseek-coder-v2:16b and
  # codellama:13b under "Models that fit this machine" on an 8 GiB box, both
  # of which tune.sh's own model_fits_ram rejects outright.
  # Comments stripped: the comment explaining this fix quotes the old heading,
  # and the first version of this check failed on the corrected file because of
  # it. Third time today — a whole-file grep always finds its own explanation.
  local body
  body="$(grep -v '^[[:space:]]*#' "${REPO}/update-model.sh")"
  grep -q 'model_fits_ram' <<<"${body}" || {
    echo 'update-model.sh lists rungs without applying tune.sh sizing check' >&2; return 1; }
  ! grep -q 'Models that fit this machine' <<<"${body}"
}
faq_does_not_overclaim_offline() {
  # The FAQ called offline a "provable guarantee" that the stack "physically
  # cannot reach the internet", which the ruleset (DNS, STUN, WireGuard) and
  # the README's own Honest limitations both contradict.
  ! grep -qi 'physically cannot reach the internet' "${REPO}/docs/FAQ.md"
}
check "the guard success line names only the ports it guarded" \
  guard_message_names_only_guarded_ports
check "the model listing flags rungs that do not fit this RAM" \
  listing_flags_models_that_do_not_fit
check "the FAQ does not promise more than the ruleset delivers" \
  faq_does_not_overclaim_offline

echo "# five failure paths that reported the wrong thing, or nothing"
# Each of these was verified by running the mechanism, not by reading it.
errexit_survives_sourcing_tune() {
  # check-system.sh runs 'set +e' so one failing probe cannot abort the rest —
  # then sources tune.sh, whose top-level 'set -euo pipefail' executes in the
  # SAME shell and turns it straight back on. Everything after it survived only
  # because those failures happen inside tested conditions, which is luck.
  awk '/^[[:space:]]*#/ { next }
       /source "\$\{SCRIPT_DIR\}\/scripts\/tune.sh"/ { src = NR }
       src && /^set \+e$/ && NR > src { found = 1 }
       END { exit !found }' "${REPO}/check-system.sh" || {
    echo 'check-system.sh does not restore set +e after sourcing tune.sh' >&2; return 1; }
}
prompt_check_is_not_claimed_when_skipped() {
  # webui_drift skips both prompt comparisons without jq, or when either side
  # is unreadable; the pass line named "system prompt" regardless.
  #
  # Every reporter that makes the CLAIM, not just check-system.sh. selftest.sh
  # had the same bug and was not covered by this: it rolled its own probe,
  # reading the LIVE value alone, so on a box without jq the drift list could
  # not contain SYSTEM_PROMPT and it printed "the chat app carries this repo's
  # assistant prompt" — while install_webui.sh, on that same box, warns that the
  # chat was started WITHOUT our prompt.
  #
  # Keyed on the success line, because that is the thing being made honest. A
  # file that only reports drift when it finds it needs no guard: webui.sh
  # warns per drifted key and never gives the prompt a clean bill of health, so
  # its silence on a jq-less box is silence, not a false claim.
  #
  # Comments stripped before looking for the guard. Caught in mutation: the
  # first version of this passed while selftest.sh was reverted to its own
  # live-value probe, because the comment explaining the fix says the helper's
  # name. Fourth time in this file.
  local f code claimants=0
  for f in "${REPO}"/*.sh "${REPO}"/scripts/*.sh; do
    [[ "${f}" == "${REPO}/scripts/lib.sh" ]] && continue
    grep -qE '^[[:space:]]*(p_pass|ok)[[:space:]]+"[^"]*prompt' "${f}" || continue
    claimants=$(( claimants + 1 ))
    code="$(sed 's/#.*//' "${f}")"
    grep -q 'webui_prompt_comparable' <<<"${code}" || {
      printf '%s claims the prompt matched without checking it could compare it\n' \
        "${f##*/}" >&2
      return 1; }
    grep -q 'skipped, not passed' "${f}" || {
      printf '%s does not say the prompt check was skipped rather than passed\n' \
        "${f##*/}" >&2
      return 1; }
  done
  # A file list that matched nothing passes silently. The claim this guards is
  # made by check-system.sh and selftest.sh; if neither still makes it,
  # somebody reworded the success line and this stopped watching.
  (( claimants >= 2 )) || {
    printf 'only %s file(s) still claim the prompt matched — this stopped watching them\n' \
      "${claimants}" >&2
    return 1
  }
}
prompt_comparable_needs_both_sides() {
  local out
  out="$(bash -c 'source "$1" >/dev/null 2>&1
                  have() { [[ "$1" != jq ]]; }           # no jq
                  webui_prompt_comparable && echo yes || echo no' _ "${REPO}/scripts/lib.sh")"
  [[ "${out}" == no ]] || { echo "webui_prompt_comparable said yes without jq" >&2; return 1; }
  out="$(bash -c 'source "$1" >/dev/null 2>&1
                  have() { return 0; }
                  webui_container_env() { return 1; }    # container unreadable
                  webui_prompt_comparable && echo yes || echo no' _ "${REPO}/scripts/lib.sh")"
  [[ "${out}" == no ]] || { echo "webui_prompt_comparable said yes with the container unreadable" >&2; return 1; }
}
apply_survives_a_failed_rebuild() {
  # A bare install_webui.sh under errexit aborted 'lca apply' before the guard
  # was reconciled and before any summary was printed.
  awk '/^apply_webui\(\) \{/ { inb = 1 }
       inb && /^\}/ { exit }
       inb && /^[[:space:]]*#/ { next }
       # Anchored to a bare INVOCATION line. Matching "install_webui.sh\"$"
       # anywhere also matched the info() a few lines up that merely names the
       # script — the message about the thing, counted as the thing.
       inb && /^[[:space:]]*"\$\{SCRIPT_DIR\}\/install_webui\.sh"$/ { bare = 1 }
       inb && /if ! "\$\{SCRIPT_DIR\}\/install_webui\.sh"/ { guarded = 1 }
       END { exit !(guarded && !bare) }' "${REPO}/scripts/apply.sh" || {
    echo 'apply.sh runs install_webui.sh unguarded, so a failed rebuild aborts the apply' >&2
    return 1; }
}
update_refuses_unattended_after_a_failed_backup() {
  # confirm() auto-answers YES off a terminal, so a cron'd update without --yes
  # sailed past a FAILED backup — the case the --yes branch refuses outright.
  grep -q 'assume_yes}" != "true" && -t 0' "${REPO}/update.sh" || {
    echo 'update.sh still asks confirm() after a failed backup when nobody can answer' >&2
    return 1; }
}
backup_stages_no_empty_model_list() {
  # '>' creates models.txt before ollama fails, and restore.sh reads a file
  # that exists as an authoritative "no models".
  awk '/ollama list > "\$\{workdir\}\/models.txt"/ { inb = 1 }
       inb && /rm -f "\$\{workdir\}\/models.txt"/ { found = 1 }
       inb && /^  fi$/ { exit }
       END { exit !found }' "${REPO}/backup.sh" || {
    echo 'backup.sh ships a zero-byte models.txt when ollama list fails' >&2; return 1; }
}
check "check-system restores set +e after sourcing tune.sh" errexit_survives_sourcing_tune
check "the prompt check is reported as skipped, not passed"  prompt_check_is_not_claimed_when_skipped
check "webui_prompt_comparable needs jq AND a readable container" \
  prompt_comparable_needs_both_sides
check "'lca apply' carries on when the chat app rebuild fails" apply_survives_a_failed_rebuild
# ...and so must the FIRST applier, which takes all three of the others down
# with it. apply_ollama ran render_ollama_dropin and restart_ollama bare, and
# it could not have been fixed the way apply_webui was: both of those die(),
# and die() exits. An exit is not a non-zero return, so 'if ! restart_ollama'
# would have looked like the fix and changed nothing. Measured:
#
#   if ! boom; then echo CAUGHT; fi; echo AFTER     -> neither runs, exit 1
#   if ! ( boom ); then echo CAUGHT; fi; echo AFTER -> both run, exit 0
#
# Driven, not grepped, and the assertion is literally "the caller is still
# alive afterwards" — the only thing that distinguishes the two forms.
apply_ollama_run() {  # CASE [BG_CTX] [BG_KEEP] -> output, counters, liveness
  bash -c '
    source "$1" >/dev/null 2>&1
    CASE="$2"; BG_CTX="$3"; BG_KEEP="$4"
    have() { return 0; }
    # The /proc read is stubbed, not performed: whether an ollama server is
    # running on the machine executing the tests must not decide the answer.
    ollama_bg_env() {
      case "$1" in
        OLLAMA_CONTEXT_LENGTH) [[ -n "${BG_CTX}" ]] && printf "%s" "${BG_CTX}" ;;
        OLLAMA_KEEP_ALIVE)     [[ -n "${BG_KEEP}" ]] && printf "%s" "${BG_KEEP}" ;;
      esac
    }
    if [[ "${CASE}" == "nosystemd" ]]; then
      systemd_available() { return 1; }
    else
      systemd_available() { return 0; }
      can_root() { return 0; }
      ollama_dropin_matches() { return 1; }   # drifted, so it will try to apply
      render_ollama_dropin() {
        if [[ "${CASE}" == "renderdies" ]]; then die "drop-in could not be written"; fi
        return 0
      }
      restart_ollama() {
        if [[ "${CASE}" == "restartdies" ]]; then die "Ollama did not answer after restart"; fi
        return 0
      }
    fi
    apply_ollama
    printf "unchecked=%s changed=%s\n" "${UNCHECKED}" "${CHANGED}"
    echo "CALLER STILL ALIVE"' _ "${REPO}/scripts/apply.sh" "$1" "${2:-}" "${3:-}" 2>&1
}
apply_ollama_survives_a_dying_step() {
  local out bad=0 case
  for case in renderdies restartdies; do
    out="$(apply_ollama_run "${case}")"
    if ! grep -q 'CALLER STILL ALIVE' <<<"${out}"; then
      printf 'a %s ends the whole apply — the chat app, the timer and the guard are never reconciled and no summary is printed: %s\n' \
        "${case}" "${out}" >&2
      bad=1
      continue
    fi
    grep -q 'unchecked=1' <<<"${out}" || {
      printf '%s survived but was not counted, so the summary still reads as complete: %s\n' "${case}" "${out}" >&2
      bad=1; }
    grep -q 'Ollama:   applied' <<<"${out}" && {
      printf '%s reported success for a step that died: %s\n' "${case}" "${out}" >&2
      bad=1; }
  done
  # ...and a working apply must still apply. Without this the gate passes with
  # apply_ollama replaced by a warn.
  out="$(apply_ollama_run ok)"
  if ! grep -q 'Ollama:   applied' <<<"${out}" || ! grep -q 'changed=1' <<<"${out}"; then
    printf 'an Ollama apply that works no longer applies anything: %s\n' "${out}" >&2
    bad=1
  fi
  return "${bad}"
}
check "...and a dying Ollama step does not take the whole apply with it" \
  apply_ollama_survives_a_dying_step
# ...and a host with no systemd is "could not look", not "already matches".
# start_ollama_bg hands the server OLLAMA_CONTEXT_LENGTH and OLLAMA_KEEP_ALIVE
# AT LAUNCH, so a value edited afterwards is not in effect until it restarts.
# apply_ollama returned an info and no count, so with nothing else drifted the
# summary said "Everything already matches .env — nothing to do." on a machine
# where nothing had looked at the running server at all.
apply_ollama_admits_it_cannot_look() {
  local out
  # No launch environment readable at all — the shrug is still right here.
  out="$(apply_ollama_run nosystemd)"
  grep -q 'unchecked=1' <<<"${out}" || {
    printf 'a host without systemd is counted as checked, so the summary claims a match nothing verified: %s\n' "${out}" >&2
    return 1; }
  grep -q 'changed=1' <<<"${out}" && {
    printf 'a host without systemd was counted as a change: %s\n' "${out}" >&2
    return 1; }
  grep -qE 'starts|restart' <<<"${out}" || {
    printf 'the message does not say the running server keeps its old values: %s\n' "${out}" >&2
    return 1; }
  return 0
}
check "...and 'no systemd' is reported as unchecked, not as a match" \
  apply_ollama_admits_it_cannot_look
# ...but "could not look" was the answer on EVERY run of EVERY systemd-less
# host, which is a whole class of machine this project supports on purpose —
# honest and permanently unhelpful. The launch environment turns out to be
# readable: start_ollama_bg passes the values, and /proc/PID/environ keeps
# them. Measured on this box:
#
#   OLLAMA_CONTEXT_LENGTH=8192
#   OLLAMA_KEEP_ALIVE=30m
#
# NOT 'ollama ps'. Its CONTEXT column looks like the answer and is not — two
# calls a minute apart on an idle box read 11677 then 11873, because newer
# Ollama sizes the working context dynamically. A drift warning built on that
# would have come and gone on its own.
apply_ollama_reads_the_running_server() {
  local out bad=0
  # Agrees with .env: a real pass, not a shrug, and nothing counted.
  out="$(apply_ollama_run nosystemd 8192 30m)"
  if ! grep -q 'already matches .env' <<<"${out}" \
     || ! grep -q 'read from the running server' <<<"${out}" \
     || ! grep -q 'unchecked=0' <<<"${out}"; then
    printf 'a server started with .env values is not reported as matching: %s\n' "${out}" >&2
    bad=1
  fi
  # Drifted: named on both sides, counted, and NOT silently "fixed" — there is
  # no service manager here, and killing the model server out from under
  # whatever is using it is not this command's call to make.
  out="$(apply_ollama_run nosystemd 4096 30m)"
  if ! grep -q 'was started with context 4096' <<<"${out}" \
     || ! grep -q 'unchecked=1' <<<"${out}"; then
    printf 'a server started with a different context is not reported as drifted: %s\n' "${out}" >&2
    bad=1
  fi
  grep -q 'already matches' <<<"${out}" && {
    printf 'a drifted server is also called a match: %s\n' "${out}" >&2; bad=1; }
  # Keep-alive alone drifting counts too — checking only the context would
  # have passed the two tests above.
  out="$(apply_ollama_run nosystemd 8192 5m)"
  grep -q 'unchecked=1' <<<"${out}" || {
    printf 'a keep-alive that drifted alone is reported as a match: %s\n' "${out}" >&2
    bad=1; }
  return "${bad}"
}
check "...and reads the running server rather than shrugging, where it can" \
  apply_ollama_reads_the_running_server
# ...and never from 'ollama ps', whose CONTEXT figure moves on its own.
apply_does_not_read_ollama_ps() {
  local body
  body="$(sed -n '/^apply_ollama() {/,/^}/p' "${REPO}/scripts/apply.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || { echo 'could not find apply_ollama' >&2; return 1; }
  ! grep -q 'ollama ps' <<<"${body}" || {
    echo "apply.sh reads 'ollama ps' for a config value — its CONTEXT column is a live allocation that changes on an idle box, not the configured setting" >&2
    return 1; }
  body="$(sed -n '/^ollama_bg_env() {/,/^}/p' "${REPO}/scripts/lib.sh" | sed 's/#.*//')"
  [[ -n "${body}" ]] || { echo 'could not find ollama_bg_env' >&2; return 1; }
  grep -q 'environ' <<<"${body}" || {
    echo 'ollama_bg_env no longer reads the launch environment' >&2; return 1; }
  ! grep -q 'ollama ps' <<<"${body}" || {
    echo "ollama_bg_env reads 'ollama ps' instead of the launch environment" >&2; return 1; }
}
check "...from the launch environment, never from 'ollama ps'" \
  apply_does_not_read_ollama_ps
check "an unattended update refuses to continue past a failed backup" \
  update_refuses_unattended_after_a_failed_backup
check "a failed 'ollama list' ships no model list at all" backup_stages_no_empty_model_list

echo "# the self-test may not claim 'end-to-end' over a check it could not run"
# 'lca test' printed "SELF-TEST PASSED — your local-code-agent stack works
# end-to-end" whenever nothing had actively failed, including when the chat
# app's assistant prompt could not be compared at all. That is the rule 'lca
# apply' already follows for a component it could not look at, applied to the
# one command whose entire output is a claim about every part.
#
# Driven, not grepped. The self-test itself does real generations and takes
# minutes, so the verdict lives in lib.sh — like setup_verdict, and testable
# for the same reason.
verdict_says() {  # want-substring pass fail skip
  local out
  out="$(selftest_verdict "$2" "$3" "$4" 2>&1 || true)"
  grep -qF -- "$1" <<<"${out}" || {
    printf 'selftest_verdict %s %s %s printed: %s\n' "$2" "$3" "$4" "${out}" >&2
    return 1
  }
}
verdict_status_is() {  # want-status pass fail skip
  local rc=0
  selftest_verdict "$2" "$3" "$4" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" == "$1" ]] || { printf 'expected status %s, got %s\n' "$1" "${rc}" >&2; return 1; }
}
check "a clean run claims end-to-end" \
  verdict_says "works end-to-end" 4 0 0
# The whole point: the same zero failures, one unexaminable check, and the
# claim is gone.
check "a skipped check withdraws the end-to-end claim" \
  verdict_status_is 0 4 0 1
skipped_run_makes_no_claim() { ! verdict_says "works end-to-end" 4 0 1 2>/dev/null; }
check "...without turning a skip into a failure" skipped_run_makes_no_claim
check "a skipped check is still reported"       verdict_says "SKIPPED" 4 0 1
# docs/YOUR-TURN.md tells the reader to look for 'SELF-TEST PASSED', so the
# skipped-but-passing line has to still contain it.
check "the skipped run still reads as a pass"   verdict_says "SELF-TEST PASSED" 4 0 1
check "a failure exits non-zero"                verdict_status_is 1 4 1 0
# A failure outranks a skip: 'lca update' offers a rollback on this status.
check "a failure outranks a skip"               verdict_says "SELF-TEST FAILED" 4 1 1
# ...and selftest.sh must actually use it, or the wording it promises the docs
# would be one hand-written printf away from drifting again.
selftest_uses_the_verdict() {
  grep -qE '^selftest_verdict "\$\{PASS\}" "\$\{FAIL\}" "\$\{SKIP\}"' "${REPO}/scripts/selftest.sh" || {
    echo 'selftest.sh no longer ends on selftest_verdict' >&2; return 1; }
  # And may not re-hardcode either line: that is how the two drifted before.
  ! grep -qF 'SELF-TEST PASSED' "${REPO}/scripts/selftest.sh"
}
check "selftest.sh reports through selftest_verdict" selftest_uses_the_verdict

echo "# 'already tuned' has to mean the model is on disk, not named in .env"
# tune.sh has two exits that write .env before anything is pulled — Ollama not
# installed yet, and its API unreachable on a host with no systemd — and both
# tell the reader to re-run tune. The fast path compared .env against the
# ladder and nothing else, so that re-run said "Already tuned for this machine
# ... Nothing to do" and fetched nothing. The script's own advice about itself
# could not work, and the machine was left with .env naming a model that is not
# there, which is what 'lca ask' and 'lca speed' then die on.
#
# Structural: reproducing it needs a real Ollama, a real pull and a real
# interruption. The shape is the fix — both decisions have to consult the disk.
tune_checks_the_model_is_downloaded() {
  # 1. the fast path
  awk '/^[[:space:]]*#/ { next }
       /TUNE_MODEL.*==.*MODEL_NAME.*TUNE_CTX.*==.*OLLAMA_CONTEXT_LENGTH/ { fast = NR }
       fast && NR >= fast && NR <= fast + 2 && /model_present/ { found = 1 }
       END { exit !found }' "${REPO}/scripts/tune.sh" || {
    echo 'tune.sh takes the "already tuned" fast path without checking the model is downloaded' >&2
    return 1
  }
  # 2. the pull decision
  awk '/^[[:space:]]*#/ { next }
       /TUNE_MODEL.*!=.*MODEL_NAME.*\|\|.*model_present/ { found = 1 }
       END { exit !found }' "${REPO}/scripts/tune.sh" || {
    echo 'tune.sh only fetches when the model NAME changed, so a missing model is never pulled' >&2
    return 1
  }
}
check "tune.sh will not call a machine tuned when the model is missing" \
  tune_checks_the_model_is_downloaded

echo "# a heading that counts its own list has to count it correctly"
# CONTRIBUTING.md's "Six shell traps that turn a gate into decoration" states a
# number in words and then lists that many bold-numbered items. Adding a trap
# means editing both, and the heading is the half a writer forgets — leaving a
# section that says four while listing six, in the file whose entire subject is
# checks that quietly stop matching reality.
#
# Derived, not listed: any heading that opens with a number word is found and
# its items counted.
counted_headings_match_their_lists() {
  local out wrong
  out="$(awk '
    function num(w) {
      split("one two three four five six seven eight nine ten", a, " ")
      for (i in a) if (tolower(w) == a[i]) return i
      return 0
    }
    /^## / {
      if (heading != "" && stated != items) printf "%s: says %s, lists %s\n", heading, stated, items
      heading = ""; stated = 0; items = 0
      split($0, f, " ")
      n = num(f[2])
      if (n > 0) { heading = $0; stated = n }
      next
    }
    heading != "" && /^\*\*[0-9]+\./ { items++ }
    END { if (heading != "" && stated != items) printf "%s: says %s, lists %s\n", heading, stated, items }
  ' "${REPO}/CONTRIBUTING.md")"
  # The scan has to have found at least one such heading, or it proves nothing.
  grep -qE '^## (One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten) ' "${REPO}/CONTRIBUTING.md" || {
    echo 'CONTRIBUTING.md no longer has a heading that counts its own list' >&2; return 1; }
  wrong="${out}"
  [[ -z "${wrong}" ]] || {
    printf 'a heading miscounts its own list:\n%s\n' "${wrong}" >&2
    return 1
  }
}
check "CONTRIBUTING's counted headings match their lists" \
  counted_headings_match_their_lists

echo "# every doc that repeats the RAM ladder must repeat it correctly"
# There are FOUR copies of the auto-tune ladder in prose: README's table (gated
# below), INSTALL.md's sizing table, TROUBLESHOOTING.md's inline list, and
# FAQ.md's context range. Only the first was checked, and INSTALL.md's is the
# one somebody sizes a VM on before spending money.
#
# Read per line, and format-agnostic: take every RAM figure and every context
# figure on a line and pair them — one context figure applies to all the RAM
# figures beside it (INSTALL.md's "9-15 GB ... ctx 8192 ... for 12-16 GB VMs"),
# equal counts zip (TROUBLESHOOTING.md's arrow list). A line that fits neither
# shape is counted, not silently dropped, and the gate insists it found pairs
# at all — an extractor that quietly matches nothing is the failure mode these
# doc gates are most prone to.
docs_repeat_the_ladder_correctly() {
  local f line i r want checked=0 skipped=0 wrong=()
  local -a rams ctxs
  for f in "${REPO}/docs/INSTALL.md" "${REPO}/docs/TROUBLESHOOTING.md"; do
    while IFS= read -r line; do
      mapfile -t rams < <(grep -oE '[0-9]+\+? ?(GB|GiB)' <<<"${line}" | grep -oE '^[0-9]+' || true)
      mapfile -t ctxs < <(grep -oE '\b(4096|8192|16384)\b' <<<"${line}" || true)
      (( ${#rams[@]} && ${#ctxs[@]} )) || continue
      if (( ${#ctxs[@]} == 1 )); then
        for r in "${rams[@]}"; do
          want="$(tune_ctx_for "${r}")"
          checked=$(( checked + 1 ))
          [[ "${ctxs[0]}" == "${want}" ]] \
            || wrong+=("${f##*/}: ${r} GiB shown as ctx ${ctxs[0]}, ladder gives ${want}")
        done
      elif (( ${#ctxs[@]} == ${#rams[@]} )); then
        for i in "${!rams[@]}"; do
          want="$(tune_ctx_for "${rams[$i]}")"
          checked=$(( checked + 1 ))
          [[ "${ctxs[$i]}" == "${want}" ]] \
            || wrong+=("${f##*/}: ${rams[$i]} GiB shown as ctx ${ctxs[$i]}, ladder gives ${want}")
        done
      else
        skipped=$(( skipped + 1 ))
      fi
    done < "${f}"
  done
  (( checked >= 6 )) || {
    printf 'the ladder extractor found only %s pair(s) — the docs changed shape and this stopped watching them\n' \
      "${checked}" >&2
    return 1
  }
  (( skipped == 0 )) || {
    printf '%s line(s) pair RAM and context figures in a shape this cannot read\n' "${skipped}" >&2
    return 1
  }
  (( ${#wrong[@]} == 0 )) || {
    printf 'a doc repeats the ladder wrongly:\n' >&2
    printf '  %s\n' "${wrong[@]}" >&2
    return 1
  }
}
tune_ctx_for() {
  bash -c 'source "$1" >/dev/null 2>&1; source "$2" >/dev/null 2>&1
           choose_for_ram "$3"; printf "%s" "${TUNE_CTX}"' \
    _ "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "$1"
}
check "INSTALL.md and TROUBLESHOOTING.md repeat the ladder correctly" \
  docs_repeat_the_ladder_correctly

# FAQ.md states the ladder as a RANGE rather than a table — "4096-16384
# tokens" — so its two endpoints are the ladder's smallest and largest context.
faq_context_range_matches_the_ladder() {
  local range lo hi want_lo want_hi
  # '.{1,3}' for the separator. The file uses an en dash (U+2013) there, which
  # is one character and THREE bytes — and under the POSIX locale these tests
  # can run in, grep's '.' matches a byte. A single '.' matched interactively
  # and then failed inside the suite, which is the whole reason for the range.
  range="$(grep -oE '[0-9]{4,5}.{1,3}[0-9]{4,5} tokens' "${REPO}/docs/FAQ.md" | head -1)"
  [[ -n "${range}" ]] || { echo 'FAQ.md no longer states a context range' >&2; return 1; }
  lo="$(grep -oE '[0-9]+' <<<"${range}" | head -1)"
  hi="$(grep -oE '[0-9]+' <<<"${range}" | sed -n 2p)"
  want_lo="$(tune_ctx_for 1)"
  want_hi="$(tune_ctx_for 512)"
  [[ "${lo}" == "${want_lo}" && "${hi}" == "${want_hi}" ]] || {
    printf 'FAQ.md says %s-%s tokens; the ladder spans %s-%s\n' \
      "${lo}" "${hi}" "${want_lo}" "${want_hi}" >&2
    return 1
  }
}
check "FAQ.md's context range spans exactly what the ladder produces" \
  faq_context_range_matches_the_ladder

echo "# PERFORMANCE.md may state one baseline for 7b, not three"
# It gave the same figure — CPU-only x86_64, 16 GiB, qwen2.5-coder:7b — three
# times as 5.5, ~6 and 6.1. The 6.1 is what was measured; the 5.5 came from the
# bandwidth arithmetic a few lines above and was written up as what the box
# "measures". Two baselines 10% apart matter here specifically: lca speed calls
# anything under 10% no real change, so a reader calibrating against 5.5 and a
# reader calibrating against 6.1 get opposite verdicts from the same run. In
# the one document whose thesis is "a change you cannot measure is not an
# improvement".
#
# The measured table is the source of truth; every bold tokens/second figure
# claimed for a model must be the one that table gives for it.
perf_baseline_is_stated_once() {
  local model measured claimed wrong=() perf_bt rows=0
  perf_bt="$(printf '\140')"
  local perf_flat
  perf_flat="$(tr '\n' ' ' < "${REPO}/docs/PERFORMANCE.md" | tr -s ' ')"
  while read -r model measured; do
    [[ -n "${model}" ]] || continue
    rows=$(( rows + 1 ))
    # Matched against the file FLATTENED to one line. Prose wraps, so the bold
    # figure routinely straddles a line break — "measures **6.1\ntokens/second**"
    # — and a line-based scan sees only the ones that happen not to. Caught in
    # mutation: reintroducing the 5.5 baseline was invisible until this.
    while read -r claimed; do
      [[ -n "${claimed}" ]] || continue
      [[ "${claimed}" == "${measured}" ]] \
        || wrong+=("${model}: the table says ${measured} but the text says ${claimed}")
    done < <(grep -oE "${model}[^|]{0,120}[*][*][0-9.]+ tokens/second[*][*]" <<<"${perf_flat}" \
               | grep -oE '[0-9.]+ tokens' | grep -oE '^[0-9.]+' | sort -u)
  # Backticks through a variable: a matched pair inside single quotes reads to
  # ShellCheck as a command substitution (SC2016), and the table's model column
  # is nothing but backticks.
  done < <(sed -n '/^| Model | Measured |/,/^$/p' "${REPO}/docs/PERFORMANCE.md" \
             | grep -E "^[|] ${perf_bt}" \
             | sed -E "s/^[|] ${perf_bt}([^${perf_bt}]+)${perf_bt} [|] [*][*]([0-9.]+) tokens.*/\\1 \\2/")
  (( rows > 0 )) || {
    echo 'the measured-speeds table could not be read from PERFORMANCE.md' >&2; return 1; }
  (( ${#wrong[@]} == 0 )) || {
    printf 'PERFORMANCE.md quotes more than one speed for the same model:\n' >&2
    printf '  %s\n' "${wrong[@]}" >&2
    return 1
  }
}
check "PERFORMANCE.md quotes one measured speed per model" perf_baseline_is_stated_once

# ...and its "fits comfortably" figures may never exceed what GPU.md's table —
# now derived from the code — says fits at all. Two VRAM tables in two
# documents, one of them checked; this ties the second to the first rather
# than leaving it to drift on its own.
perf_vram_within_the_computed_maximum() {
  local row gb biggest maxfit wrong=() rows=0
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    gb="$(cut -d'|' -f2 <<<"${row}" | grep -oE '[0-9]+' | head -1)"
    biggest="$(cut -d'|' -f3 <<<"${row}" | grep -oE '[0-9]+' | sort -n | tail -1)"
    [[ -n "${gb}" && -n "${biggest}" ]] || continue
    maxfit="$(bash -c 'source "$1" >/dev/null 2>&1; largest_model_for_vram "$2"' \
      _ "${REPO}/scripts/lib.sh" "$(( gb * 1024 ))" || true)"
    [[ -n "${maxfit}" ]] || continue
    rows=$(( rows + 1 ))
    (( biggest <= maxfit )) \
      || wrong+=("${gb} GB: PERFORMANCE.md is comfortable with ${biggest}B, but only ${maxfit}B fits at all")
  done < <(sed -n '/^| VRAM | Fits comfortably/,/^$/p' "${REPO}/docs/PERFORMANCE.md" \
             | grep -E '^\| [0-9]')
  (( rows >= 3 )) || {
    printf 'only %s row(s) read from the comfortable-VRAM table — it changed shape\n' "${rows}" >&2
    return 1; }
  (( ${#wrong[@]} == 0 )) || {
    printf 'PERFORMANCE.md recommends more than fits:\n' >&2
    printf '  %s\n' "${wrong[@]}" >&2
    return 1
  }
}
check "PERFORMANCE.md never recommends a model bigger than fits" \
  perf_vram_within_the_computed_maximum

echo "# docs/GPU.md's VRAM table must be the arithmetic lca speed actually does"
# The same shape as the RAM ladder below: a table of numbers a reader sizes a
# purchase on, and a function that computes them. GPU.md even says "lca speed
# does this arithmetic for your card and tells you the number" — so the table
# and the number are the same claim made twice, and only one of them was ever
# checked.
#
# The stakes are a graphics card. A model that spills out of VRAM runs at close
# to CPU speed, which is the entire point of the page.
gpu_doc_vram_table_matches_the_code() {
  local row gb claimed got wrong=() rows
  rows="$(sed -n '/^| VRAM | Fits entirely/,/^$/p' "${REPO}/docs/GPU.md" | grep -E '^\| [0-9]')"
  (( $(grep -c . <<<"${rows}") >= 3 )) || {
    echo 'could not find the VRAM table in docs/GPU.md' >&2; return 1; }
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    gb="$(cut -d'|' -f2 <<<"${row}" | grep -oE '[0-9]+' | head -1)"
    claimed="$(cut -d'|' -f3 <<<"${row}" | grep -oE '[0-9]+' | head -1)"
    [[ -n "${gb}" && -n "${claimed}" ]] || continue
    got="$(bash -c 'source "$1" >/dev/null 2>&1; largest_model_for_vram "$2"' \
      _ "${REPO}/scripts/lib.sh" "$(( gb * 1024 ))" || true)"
    [[ "${claimed}" == "${got}" ]] \
      || wrong+=("${gb} GB: GPU.md says ~${claimed}B, largest_model_for_vram gives ${got:-nothing}B")
  done <<<"${rows}"
  (( ${#wrong[@]} == 0 )) || {
    printf 'the VRAM table and the code disagree:\n' >&2
    printf '  %s\n' "${wrong[@]}" >&2
    return 1
  }
}
check "docs/GPU.md's VRAM table matches largest_model_for_vram" \
  gpu_doc_vram_table_matches_the_code

echo "# the README's RAM ladder must be the one choose_for_ram walks"
# The MODEL_FAMILY table below is gated; the table above it — the headline
# feature's own "resize and it adapts" ladder, naming a model and a context
# length per RAM band — was not. It is the first table a reader meets and the
# claim the whole feature rests on.
#
# Both EDGES of every band are probed, not a midpoint. A ladder's classic
# failure is an off-by-one at a boundary, and "16-23 -> 14b" is satisfied by
# code that starts the 14b rung at 17.
readme_ram_ladder_matches_the_code() {
  local row band model ctx n probes wrong=() bt tbl
  # Backticks around the model names: a matched pair inside single quotes reads
  # to ShellCheck as a command substitution (SC2016), as the family gate below
  # already records.
  bt="$(printf '\140')"
  tbl="$(sed -n '/^| RAM (GiB, detected)/,/^$/p' "${REPO}/README.md" | grep -E '^\| [^-]')"
  # Header row out; what is left must be the four bands.
  tbl="$(grep -v 'RAM (GiB' <<<"${tbl}")"
  (( $(grep -c . <<<"${tbl}") >= 4 )) || {
    echo 'the RAM ladder table could not be found in README.md' >&2; return 1; }
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    band="$(cut -d'|' -f2 <<<"${row}")"
    model="$(cut -d'|' -f3 <<<"${row}" | tr -d " ${bt}")"
    ctx="$(cut -d'|' -f4 <<<"${row}" | tr -d ' ')"
    [[ -n "${model}" && -n "${ctx}" ]] || continue
    # "< N" means the band ends below N, so N-1 is its top edge; every other
    # band is probed at each number it names.
    if [[ "${band}" == *"<"* ]]; then
      probes="$(( $(grep -oE '[0-9]+' <<<"${band}" | head -1) - 1 ))"
    else
      probes="$(grep -oE '[0-9]+' <<<"${band}" | paste -sd' ' -)"
    fi
    for n in ${probes}; do
      read -r got_model got_ctx < <(bash -c '
        source "$1" >/dev/null 2>&1; source "$2" >/dev/null 2>&1
        choose_for_ram "$3"; printf "%s %s\n" "${TUNE_MODEL}" "${TUNE_CTX}"' \
        _ "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "${n}")
      [[ "${got_model}" == "${model}" && "${got_ctx}" == "${ctx}" ]] \
        || wrong+=("${n} GiB: README says ${model}/${ctx}, choose_for_ram gives ${got_model}/${got_ctx}")
    done
  done <<<"${tbl}"
  (( ${#wrong[@]} == 0 )) || {
    printf "the README's RAM ladder does not match the code:\\n" >&2
    printf '  %s\n' "${wrong[@]}" >&2
    return 1
  }
}
check "the README's RAM ladder matches choose_for_ram" \
  readme_ram_ladder_matches_the_code

echo "# the README's family table must be the ladder the code actually walks"
# MODEL_FAMILY is the one .env key whose entire purpose is "one line changes
# the model everywhere", so its table is the interface. It promised
# llama3.1 -> 70b and codellama -> 34b; family_sizes returns 8b and 13b, both
# capped on purpose ("manual only" in the source). A user on a 24 GB box was
# told auto-tune would give them a 70b and it silently gave them 8b, forever.
readme_family_table_matches_the_code() {
  local row fam want got mismatched=() bt tbl
  # A matched PAIR of backticks inside single quotes reads to ShellCheck as a
  # command substitution (SC2016), and the table's cells are full of them —
  # same trap the docs gates in this file already document. Build the character.
  bt="$(printf '\140')"
  tbl="$(sed -n "/^| ${bt}MODEL_FAMILY${bt} | small/,/^\$/p" "${REPO}/README.md" | grep "^| ${bt}")"
  while read -r row; do
    [[ -n "${row}" ]] || continue
    fam="$(sed -n "s/^| ${bt}\\([a-z0-9.-]*\\)${bt}.*/\\1/p" <<<"${row}")"
    [[ -n "${fam}" ]] || continue
    # The three rungs are the first three NNb tokens in the cell; anything
    # after them (a note about manual-only sizes) is prose and ignored.
    want="$(grep -oE '[0-9]+(\.[0-9]+)?b' <<<"${row}" | head -3 | paste -sd' ' -)"
    got="$(bash -c 'source "$1" >/dev/null 2>&1; source "$2" >/dev/null 2>&1
                    family_sizes "$3"' _ "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "${fam}")"
    [[ "${want}" == "${got}" ]] || mismatched+=("${fam}: README says '${want}', family_sizes returns '${got}'")
  done < <(printf '%s\n' "${tbl}")
  (( ${#mismatched[@]} == 0 )) || {
    printf 'the README advertises rungs auto-tune never selects:\n' >&2
    printf '  %s\n' "${mismatched[@]}" >&2
    return 1
  }
  # And the table must not be empty, or the loop above proves nothing.
  (( $(grep -c . <<<"${tbl}") >= 4 )) || {
    echo 'the MODEL_FAMILY table could not be found in README.md' >&2; return 1; }
}
check "the README's MODEL_FAMILY rungs match family_sizes" \
  readme_family_table_matches_the_code

echo "# the guard renderer and the guard reader, run against each other"
# inbound_guard_uncovered is the rule behind two user-facing claims — 'lca
# check' printing "does NOT cover", and 'lca apply' deciding whether to reload
# the firewall — and until now the only input it was ever given was a
# hand-written fixture. Nothing checked it against what netmode.sh actually
# emits. A renderer that changed its port-set syntax would make the reader
# report every port uncovered: 'lca check' failing on a healthy machine and
# 'lca apply' re-hardening on every run, with the unit tests still green
# because they were reading a copy.
#
# Renders for real, in a throwaway checkout, and asserts the reader agrees.
guard_round_trip() {  # $1 = .env content, $2 = label
  # Not 'gaps': inbound_guard_uncovered declares a local array by that name and
  # ShellCheck -x follows the source, so a string here reads as SC2178.
  local sandbox dump uncovered_out rc=0
  sandbox="$(mktemp -d)"
  ( cd "${REPO}" && tar -c --exclude=.venv --exclude=.git --exclude=backups . ) \
    | tar -x -C "${sandbox}"
  printf '%s\n' "$1" > "${sandbox}/.env"
  dump="$("${sandbox}/netmode.sh" render-inbound 2>/dev/null || true)"
  rm -rf "${sandbox}"
  [[ -n "${dump}" ]] || {
    printf '%s: render-inbound produced nothing\n' "$2" >&2; return 1; }
  # The reader is driven with the SAME .env the renderer just used.
  # A separate process, not a subshell: sourcing lib.sh inline makes ShellCheck
  # link this to unrelated subshell assignments elsewhere in the suite (SC2030),
  # and a child is a cleaner boundary anyway — the reader sees exactly this
  # .env and nothing the suite happens to have set.
  uncovered_out="$(bash -c '
      set -uo pipefail
      source "$1" >/dev/null 2>&1
      source <(printf "%s\n" "$2") >/dev/null 2>&1
      ENABLE_WEBUI="${ENABLE_WEBUI:-true}"
      # AFTER the source, because lib.sh defines it. This round trip is about
      # the renderer and the reader agreeing on what .env asks for; a chat app
      # actually running on this machine adds its live port to the reader and
      # nothing to the renderer, so without the stub the check failed on any
      # box with the container up — which is a real install.
      webui_container_running() { return 1; }
      webui_container_env() { return 1; }
      inbound_guard_uncovered "$3" || true
    ' _ "${REPO}/scripts/lib.sh" "$1" "${dump}")" || rc=$?
  (( rc == 0 )) || { printf '%s: reader errored\n' "$2" >&2; return 1; }
  [[ -z "${uncovered_out}" ]] || {
    printf '%s: the reader says these are uncovered in a guard the renderer just wrote for them:\n%s\n' \
      "$2" "${uncovered_out}" >&2
    return 1
  }
}
default_ports_round_trip() {
  guard_round_trip 'WEBUI_PORT=3000
OLLAMA_HOST="127.0.0.1:11434"' 'default ports'
}
custom_ports_round_trip() {
  guard_round_trip 'WEBUI_PORT="8080" # moved
OLLAMA_HOST="0.0.0.0:11500"' 'custom ports'
}
webui_off_round_trip() {
  guard_round_trip 'ENABLE_WEBUI=false
WEBUI_PORT=3000
OLLAMA_HOST="0.0.0.0:11434"' 'chat app disabled'
}
ssh_port_round_trip() {
  # WEBUI_PORT=22 is refused by the renderer and excluded by the reader; they
  # have to agree about that too, or 'lca check' fails forever on a box nobody
  # can fix.
  guard_round_trip 'WEBUI_PORT=22
OLLAMA_HOST="127.0.0.1:11434"' 'WebUI on the SSH port'
}
check "the reader agrees with a freshly rendered guard (default ports)" \
  default_ports_round_trip
check "...with custom ports"            custom_ports_round_trip
check "...with the chat app disabled"   webui_off_round_trip
check "...with WEBUI_PORT=22 refused"   ssh_port_round_trip

echo "# one ladder, not a shared table and a copied staircase"
# check-system.sh sources tune.sh so the two cannot disagree — and then
# re-implemented the rung selection inline, dropping choose_for_ram's fallback
# for a family whose smallest size will not fit the machine. Measured with
# MODEL_FAMILY=deepseek-coder-v2 (16b only) at 8 GiB: tune.sh chooses
# qwen2.5-coder:3b, the inline copy demanded deepseek-coder-v2:16b, and the
# health check told the reader to run the script that had just chosen right.
ladder_agrees_with_tune() {
  local fam ram real
  # Drive the real chooser exactly as check-system now does.
  for fam in qwen2.5-coder deepseek-coder-v2 qwen3; do
    for ram in 4 8 12 16 24 64; do
      real="$(MODEL_FAMILY="${fam}" bash -c '
                set -uo pipefail
                source "$1" >/dev/null 2>&1
                source "$2" >/dev/null 2>&1
                TUNE_MODEL=""; choose_for_ram "$3" 2>/dev/null
                printf "%s" "${TUNE_MODEL}"' _ \
                "${REPO}/scripts/lib.sh" "${REPO}/scripts/tune.sh" "${ram}")"
      [[ -n "${real}" ]] || {
        printf 'choose_for_ram returned nothing for %s at %s GiB\n' "${fam}" "${ram}" >&2
        return 1
      }
    done
  done
  # ...and check-system must call it rather than keep its own staircase.
  grep -q 'choose_for_ram "[$]{RAM_GIB}"' "${REPO}/check-system.sh" || {
    echo 'check-system.sh does not use choose_for_ram' >&2; return 1; }
  awk '/^[[:space:]]*#/ { next }
       /RAM_GIB < 9/ || /RAM_GIB <= 15/ { found = 1 }
       END { exit found }' "${REPO}/check-system.sh" || {
    echo 'check-system.sh still has its own copy of the RAM ladder' >&2; return 1; }
}
check "check-system uses tune.sh's chooser instead of a copy of the ladder" \
  ladder_agrees_with_tune

echo "# backups hold the session-signing key, so they cannot be world-readable"
# Every archive contains the Open WebUI database — account password hashes and
# the JWT signing key, which mints valid sessions for any account — plus a copy
# of .env. On this box they were found as -rw-r--r-- inside a drwxr-xr-x
# backups/, so any other login could read all of it. The directory permission
# is what actually gates access; the umask is defence in depth on the file.
umask_really_gives_owner_only() {
  local f="${SANDBOX}/umask.probe" mode
  ( umask 077; : > "${f}" )
  mode="$(stat -c '%a' "${f}")"; rm -f "${f}"
  [[ "${mode}" == 600 ]]
}
check "umask 077 produces a 600 file" umask_really_gives_owner_only
backup_is_not_world_readable() {
  local body
  # Scoped to do_backup, not a whole-file grep. install_timer also chmods the
  # directory, and the first version of this check was satisfied by that one
  # alone — deleting the chmod from do_backup, which is the one that runs on
  # every single backup, passed a full green suite. Proved by mutation, which
  # is the only reason it was noticed.
  awk '/^do_backup\(\) \{/            { inb = 1; next }
       inb && /^\}/                   { exit }
       inb && /^[[:space:]]*#/        { next }
       inb && /chmod 700 "\$\{BACKUP_DIR\}"/ { found = 1 }
       END { exit !found }' "${REPO}/backup.sh" || {
    echo 'do_backup does not restrict backups/ to its owner' >&2; return 1; }
  body="$(grep -v '^[[:space:]]*#' "${REPO}/backup.sh")"
  (( $(grep -c 'chmod 700 "[$]{BACKUP_DIR}"' <<<"${body}") >= 2 )) || {
    echo 'the timer install no longer restricts backups/ either' >&2; return 1; }
  # umask BEFORE the tar, not a chmod after it: tar creates the file the moment
  # it starts, so a later chmod only closes it once the secrets are on disk.
  awk '/^[[:space:]]*#/ { next }
       /umask 077/       { if (!tarred) umasked = NR }
       /tar czf .*tarball/ { tarred = NR }
       END { exit !(umasked && tarred && umasked < tarred) }' "${REPO}/backup.sh" || {
    echo 'backup.sh writes the tarball before narrowing the umask' >&2; return 1; }
}
check "backup.sh keeps backups/ and new archives owner-only" \
  backup_is_not_world_readable

echo "# a backup must not leave the chat app frozen for the next one to inherit"
# backup.sh pauses the WebUI container so the SQLite snapshot is consistent,
# with an EXIT trap to guarantee the unpause. A signal the trap cannot catch
# leaves it paused — and a paused container still reports State.Running=true,
# while 'docker pause' fails on it. The old order asked Running first, so that
# failure took the "could not pause" branch: no trap, 'paused' left false, no
# unpause at the end. Every later backup then archived happily and left the
# chat app frozen and unreachable, with the warning saying it was "archiving
# live" — the opposite of what was happening.
#
# Structural, because the behaviour needs a docker daemon and a container that
# has been killed mid-pause. The shape is what produces it: Paused has to be
# asked before Running, or the already-paused case cannot be seen at all.
backup_checks_paused_before_running() {
  # Comments stripped first. The comment above this very check explains the bug
  # by naming State.Running, and the first version of this scanner counted that
  # sentence as the code — failing on the fixed file. Same trap as every other
  # whole-file grep in this suite: the explanation matches the pattern.
  awk '/^[[:space:]]*#/ { next }
       /State.Paused/   { if (!paused)  paused  = NR }
       /State.Running/  { if (!running) running = NR }
       END { exit !(paused && running && paused < running) }' "${REPO}/backup.sh" || {
    printf 'backup.sh asks State.Running before State.Paused, so a container left paused reads as running\n' >&2
    return 1
  }
  # ...and finding it paused must take responsibility for resuming it.
  awk '/State.Paused/ { inb = 1 }
       inb && /paused=true/ { found = 1 }
       inb && /elif/ { exit }
       END { exit !found }' "${REPO}/backup.sh" || {
    printf 'backup.sh sees an already-paused container but does not adopt the unpause\n' >&2
    return 1
  }
}
echo "# an interrupted backup must not leave a partial archive behind"
# 'if ! tar ...; then rm -f "${tarball}"; fi' covers tar FAILING. It does not
# cover tar being INTERRUPTED: bash exits without taking the else branch.
# Measured directly, with a group SIGINT during tar —
#
#   $ bash -c 'if ! tar czf /tmp/probe.tar.gz -C /tmp/bigsrc .; then
#              echo CLEANUP RAN; rm -f /tmp/probe.tar.gz; fi'
#   (no output at all)
#   -rw-r--r-- 1 root root 153616384 /tmp/probe.tar.gz
#
# ...and a separate probe confirmed an EXIT trap DOES run on that signal, which
# is why the fix hangs off the trap this script already had rather than adding
# INT/TERM/HUP. A truncated archive cannot be restored — restore.sh runs
# 'tar tzf' first — but it looks like a backup in 'ls' and counts toward
# BACKUP_KEEP, so enough interrupted runs evict the real ones.
backup_cleans_up_a_partial_archive() {
  local body
  body="$(sed 's/#.*//' "${REPO}/backup.sh")"
  # shellcheck disable=SC2016  # the literal ${tarball} is what we search for
  grep -q 'PARTIAL_TARBALL="${tarball}"' <<<"${body}" || {
    echo 'backup.sh never records the archive it is part-way through writing' >&2
    return 1; }
  grep -qE 'PARTIAL_TARBALL:-.*rm -f' <<<"${body}" || {
    echo 'nothing removes the partial archive on the way out' >&2
    return 1; }
  grep -q 'PARTIAL_TARBALL=""' <<<"${body}" || {
    echo 'backup.sh never clears the marker, so a COMPLETE archive gets deleted at exit' >&2
    return 1; }
  # Every EXIT trap has to go through the one cleanup, or a future trap
  # silently opts out of it. Three of them re-arm around the pause/unpause.
  local traps
  traps="$(grep -c 'trap .*EXIT' <<<"${body}")"
  local via
  via="$(grep -c 'trap .*backup_cleanup.*EXIT' <<<"${body}")"
  [[ "${traps}" == "${via}" ]] || {
    printf '%s of backup.sh %s EXIT traps bypass backup_cleanup\n' \
      "$(( traps - via ))" "${traps}" >&2
    return 1; }
}
check "an interrupted backup takes its half-written archive with it" \
  backup_cleans_up_a_partial_archive
# ...and the cleanup itself, driven rather than grepped.
partial_cleanup_behaves() {
  local f="${SANDBOX}/partial.tar.gz" out
  : > "${f}"
  out="$(bash -c 'source "$1" >/dev/null 2>&1
    workdir=""; PARTIAL_TARBALL="$2"
    backup_cleanup() { [[ -z "${PARTIAL_TARBALL:-}" ]] || rm -f "${PARTIAL_TARBALL}"; rm -rf "${workdir:-}"; }
    backup_cleanup' _ "${REPO}/scripts/lib.sh" "${f}" 2>&1 || true)"
  [[ ! -e "${f}" ]] || { echo "the cleanup left ${f} behind" >&2; return 1; }
  # ...and a cleared marker must not delete anything.
  : > "${f}"
  bash -c 'PARTIAL_TARBALL=""; workdir=""
    backup_cleanup() { [[ -z "${PARTIAL_TARBALL:-}" ]] || rm -f "${PARTIAL_TARBALL}"; rm -rf "${workdir:-}"; }
    backup_cleanup' >/dev/null 2>&1
  [[ -e "${f}" ]] || { echo 'the cleanup deletes a completed archive when the marker is cleared' >&2; return 1; }
  rm -f "${f}"
}
check "...and it deletes only while the marker is set" partial_cleanup_behaves

check "backup.sh notices a container left paused by an earlier run" \
  backup_checks_paused_before_running

echo "# the volume restore must know whether it already emptied the volume"
# restore.sh replaces the WebUI volume by clearing it and unpacking over it.
# It used to be one '&&' chain, so a failure anywhere landed in a single branch
# that said "Your existing WebUI data was NOT wiped (the archive is validated
# before the volume is replaced)". True if the archive would not read. False —
# on the one path where the reader most needs the truth — if the unpack died
# after 'rm -rf' had run, which is what a disk filling mid-restore does.
#
# The SHIPPED script is extracted from restore.sh and run against fixtures, so
# this tests the string that actually reaches the container, not a copy of it.
VOL="${SANDBOX}/vol"; mkdir -p "${VOL}/from" "${VOL}/to" "${VOL}/bin"
vol_payload() {
  local p
  p="$(awk "/-c 'tar tzf/,/exit 5'/" "${REPO}/restore.sh" | sed 's/^[[:space:]]*//')"
  p="${p#-c \'}"
  p="${p%\' \\}"
  p="${p//\/from/${VOL}\/from}"
  p="${p//\/to/${VOL}\/to}"
  printf '%s' "${p}"
}
# If restore.sh is rewritten so this stops matching, say THAT rather than
# letting three behaviour tests fail for a reason none of them is about.
payload_was_extracted() {
  local p; p="$(vol_payload)"
  [[ "${p}" == *'tar tzf'* && "${p}" == *'exit 5'* ]] || {
    printf 'could not extract the container script from restore.sh; got:\n%s\n' "${p}" >&2
    return 1
  }
}
check "the container script can still be read out of restore.sh" payload_was_extracted
vol_run() {  # $1 = a directory to put first on PATH, or empty; echoes the status
  local rc=0 prefix=""
  # The PATH change goes INSIDE the sh -c string, where it is the inner
  # shell's business. Written out here — as a 'PATH=... env' prefix or by
  # reading "${PATH}" — ShellCheck calls it SC2031, because this suite does
  # modify PATH in a subshell elsewhere and cannot know the read is safe.
  if [[ -n "$1" ]]; then
    prefix="PATH=\"$1:\$PATH\"; export PATH; "
  fi
  sh -c "${prefix}$(vol_payload)" >/dev/null 2>&1 || rc=$?
  printf '%s' "${rc}"
}
vol_reset() {
  rm -rf "${VOL}/to"; mkdir -p "${VOL}/to"; printf 'live-accounts-and-chats\n' > "${VOL}/to/keep.txt"
}
# 1. An unreadable archive must stop BEFORE anything is cleared.
vol_reset; printf 'not a gzip archive' > "${VOL}/from/open-webui-volume.tar.gz"
corrupt_stops_before_clearing() {
  [[ "$(vol_run '')" == 3 ]] && [[ -f "${VOL}/to/keep.txt" ]]
}
check "an unreadable archive exits 3 and leaves the live volume alone" \
  corrupt_stops_before_clearing
# 2. A good archive replaces the contents.
vol_reset
( cd "${VOL}" && mkdir -p src && printf 'restored\n' > src/restored.txt \
  && tar czf from/open-webui-volume.tar.gz -C src . )
good_archive_restores() {
  [[ "$(vol_run '')" == 0 ]] && [[ -f "${VOL}/to/restored.txt" ]] && [[ ! -f "${VOL}/to/keep.txt" ]]
}
check "a good archive exits 0 and replaces the volume contents" good_archive_restores
# 3. The case the old message lied about: the unpack fails AFTER the clear.
#    A stub tar that lists happily and refuses to extract puts us exactly there.
cat > "${VOL}/bin/tar" <<'FAKE'
#!/bin/sh
case "$1" in
  tzf) exit 0 ;;
  xzf) exit 1 ;;
esac
exit 0
FAKE
chmod +x "${VOL}/bin/tar"
vol_reset
unpack_failure_is_distinguishable() {
  # 5, not 3: the volume IS empty now, and the message must be able to say so.
  [[ "$(vol_run "${VOL}/bin")" == 5 ]] && [[ ! -f "${VOL}/to/keep.txt" ]]
}
check "an unpack that fails after clearing exits 5, not 3" \
  unpack_failure_is_distinguishable
# ...and restore.sh must actually tell those apart rather than share a branch.
restore_distinguishes_the_stages() {
  grep -q 'existing WebUI data was NOT wiped' "${REPO}/restore.sh" || return 1
  grep -q 'FAILED PART-WAY' "${REPO}/restore.sh" || return 1
  # the "not wiped" sentence must not live in the same arm as the wiped case
  ! awk '/^ *5\)/ { inarm = 1; next }
         inarm && /^ *;;/ { inarm = 0 }
         inarm && /NOT wiped/ { found = 1 }
         END { exit !found }' "${REPO}/restore.sh"
}
check "restore.sh reports 'not wiped' and 'wiped' as different outcomes" \
  restore_distinguishes_the_stages

echo "# a big piped input must not kill the command that exists to read it"
# 'lca logs | lca ask "why did this fail?"' is the first thing
# docs/TROUBLESHOOTING.md tells you to run. It died outright — exit 141, no
# answer, no warning, no error — whenever the piped input passed the 64 KiB
# pipe buffer, which is to say whenever the log was big enough to be worth
# asking about. ask.sh sliced it with 'printf "%s" "${piped}" | head -c 12000':
# head leaves after 12000 bytes, printf still has the rest to write and takes
# SIGPIPE, pipefail returns 141, and errexit exits the script mid-assignment.
#
# Demonstrated rather than asserted, so the gate below is visibly guarding
# something real.
pipeline_slice_really_does_die() {
  local rc=0
  ( set -euo pipefail
    s="$(head -c 200000 /dev/zero | tr '\0' 'x')"
    printf '%s' "${s}" | head -c 12000 >/dev/null ) || rc=$?
  (( rc != 0 ))
}
parameter_slice_survives() {
  local s out
  s="$(head -c 200000 /dev/zero | tr '\0' 'x')"
  out="${s:0:12000}"
  (( ${#out} == 12000 ))
}
check "the old 'printf | head' form fails on a 200k input" \
  pipeline_slice_really_does_die
check "the parameter slice returns the same 12000 chars and lives" \
  parameter_slice_survives
ask_slices_without_a_pipe() {
  grep -q 'piped:0:12000' "${REPO}/scripts/ask.sh"
}
check "ask.sh slices piped input with parameter expansion" ask_slices_without_a_pipe
# ...and nowhere else may reintroduce it. A variable written into a reader that
# leaves early is the same bug wherever it appears; CONTRIBUTING lists it as
# shell trap #1 and it was in shipped code anyway.
no_variable_is_piped_into_an_early_exiting_reader() {
  local hits
  hits="$(grep -rnE '(printf|echo)[^|]*[$][{][A-Za-z_]+[^|]*[|][[:space:]]*(head|grep -q|grep -m)' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh "${REPO}/bin/lca" \
            2>/dev/null || true)"
  [[ -z "${hits}" ]] || {
    printf 'these write a variable into a reader that exits early (SIGPIPE at >64KiB):\n%s\n' "${hits}" >&2
    return 1
  }
}
check "no script pipes a variable into a reader that exits early" \
  no_variable_is_piped_into_an_early_exiting_reader
# Same trap, other end: a COMMAND whose output size the script does not
# control, feeding a grep that leaves on the first match. install_webui.sh had
# 'ss -ltn | grep -qE ":${WEBUI_PORT}"' as its port-clash check, and the
# direction of that failure is what makes it matter — a missed match means the
# port looks free, 'docker run --network=host' cannot bind, the container
# crash-loops under --restart unless-stopped, and the squatter answers the
# health probe. A false success, from the one block written to prevent exactly
# that.
#
# Measured, with the match at the head of a 200 KiB stream: the pipe form
# returned 141 and read as "not found"; the capture form found it.
#
# Scoped to producers that can outgrow the 64 KiB pipe buffer on a real
# machine. 'docker inspect -f' prints one line and 'id -nG' one more, so they
# are deliberately not here — this is not a ban on pipelines.
no_unbounded_listing_is_piped_into_grep_q() {
  local hits
  hits="$(grep -rnE '\b(ss|ps|journalctl|lspci|docker (ps|images|logs)|docker [a-z]+ ls)\b[^|]*\|[[:space:]]*grep -q' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh "${REPO}/bin/lca" 2>/dev/null \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [[ -z "${hits}" ]] || {
    printf 'these pipe an unbounded listing into a grep that exits early (141 reads as not-found):\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "no unbounded listing is piped into 'grep -q'" \
  no_unbounded_listing_is_piped_into_grep_q
# Same family, and the least visible member: 'exec' with redirections and NO
# command applies them to the SHELL, not to anything being run.
#
# backup.sh opened its lock with 'exec {FD}>lock 2>/dev/null'. That 2>/dev/null
# looks like it belongs to the lock. It does not — it silenced stderr for the
# entire rest of the backup. Measured on a filesystem with no space left: the
# tar failure's own die(), "Could not write ... (disk full? check: df -h)",
# went to /dev/null and the run ended at exit 1 with a completely blank stderr.
# A nightly timer failing with nothing to read is the worst version of this,
# and the message it was throwing away is the one that names the cause. With
# the redirection removed, the same run prints gzip's "No space left on
# device", tar's error, and the die() — and older backups are still kept.
#
# The '{VAR}>' form is the legitimate one: it opens a numbered-by-bash fd and
# touches nothing else. A failing exec redirect returns non-zero and prints its
# own diagnostic rather than killing the shell, so it needs no muffling.
no_commandless_exec_redirects_the_shell() {
  local hits bad=0 line rest
  hits="$(grep -rnE '^[[:space:]]*exec[[:space:]]+([0-9]*[<>]|\{[A-Za-z_]+\}[<>]|&>)' \
            "${REPO}"/*.sh "${REPO}"/scripts/*.sh "${REPO}"/deploy/*.sh \
            "${REPO}"/tests/*.sh "${REPO}/bin/lca" 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  # An empty hit list is a legitimate pass: this is a prohibition, and there
  # may simply be no command-less exec in the repo. Proved by mutation.
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    # Strip the legitimate '{VAR}>target' opening, then see what redirection
    # syntax is left — anything at all is aimed at the shell.
    rest="$(sed -E 's/\{[A-Za-z_]+\}[<>]+[^[:space:]]*//g' <<<"${line#*:*:}")"
    grep -qE '[0-9&]?[<>]' <<<"${rest}" && {
      printf 'this exec redirects the SHELL, silencing everything after it:\n%s\n' \
        "${line}" >&2
      bad=1
    }
  done <<<"${hits}"
  return "${bad}"
}
check "no command-less 'exec' redirects the shell's own streams" \
  no_commandless_exec_redirects_the_shell
# ...and the same trap in the SUITE, which the gate above never looked at.
#
# This is not hypothetical here. 'uninstall clears models pulled without
# systemd' failed once during a run and then passed five times in a row on
# byte-identical code: 'sed file | grep -q' where grep matched and left while
# sed still had writes in flight. The file is 9.5 KiB, well under the pipe
# buffer, which is the point — sed writes in blocks, so the race does not need
# a big file, only an unlucky schedule. Every gate in here runs under
# 'set -euo pipefail', where 141 reads as "pattern absent": a red build on
# correct code, whose obvious remedy is to re-run it, which is how a suite
# stops being believed.
#
# A here-string costs nothing and cannot race, so in the suite the rule is
# absolute rather than scoped by producer size — the reason the gate above
# stops at unbounded listings does not apply to a test that is only ever
# reading a repo file it has already located.
#
# The pattern lives in a variable so this gate does not find ITSELF, the
# vacuity trap two gates in this file have already fallen into. Anti-vacuity
# is by mutation, not by a non-empty hit list: a prohibition is proved by
# planting a violation, not by finding one.
no_pipe_into_grep_q_in_the_suite() {
  local hits pat='\$\{[A-Za-z_]+\}[^|]*\|[[:space:]]*grep -q'
  hits="$(grep -nE "${pat}" "${REPO}"/tests/*.sh 2>/dev/null \
            | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [[ -z "${hits}" ]] || {
    printf 'the suite pipes a file read into a grep that exits early (141 reads as not-found; capture it and use a here-string instead):\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "the test suite never pipes a file read into 'grep -q'" \
  no_pipe_into_grep_q_in_the_suite
# ...and awk is the same reader, which the rule above did not say and this
# suite therefore kept writing. 'sed file | awk /^fn\(\)/ ... { exit }' is how
# a dozen gates here read one function out of a script, and every one of them
# is the trap above wearing a different hat: awk stops at the closing brace,
# sed still has writes queued, SIGPIPE, 141.
#
# It turned CI red on ollama_models_dir, which sits halfway up lib.sh — the
# largest file here, so ~600 lines were still unread. The identical checks
# against motd.sh had never failed because that file fits inside the pipe
# buffer, which is luck rather than design, and exactly the reasoning the note
# above forbids ("Do not reason about whether the output fits").
#
# Blanket, not scoped to awk programs that visibly exit: the safe ones are safe
# only until someone adds an exit to them, and a here-string costs nothing.
# All ten call sites were converted before this gate went in.
no_file_read_piped_into_awk() {
  local suite hits
  suite="$(cat "${REPO}"/tests/*.sh)"
  hits="$(awk 'prev ~ /sed .*\\$/ && /^[[:space:]]*\|[[:space:]]*awk/ { print NR ": " $0 }
               { prev = $0 }' <<<"${suite}")"
  [[ -z "${hits}" ]] || {
    printf 'the suite pipes a file read into awk (an awk that exits takes the writer with it; capture the text and use a here-string):\n%s\n' \
      "${hits}" >&2
    return 1
  }
}
check "...and never pipes one into awk either" \
  no_file_read_piped_into_awk

echo "# a script that rewrites its own file must not let bash read on"
# bash reads a script incrementally from an open fd. update.sh fast-forwards
# the checkout it is running from, and install.sh hard-resets it; either can
# replace the file mid-run, and when main returns bash reads whatever now sits
# at its old byte offset. Measured with a 7961-byte stand-in: it executed a
# fragment of a comment in the replacement and exited 127 — right after the
# update had succeeded and said so. Ending the line with 'exit $?' means both
# commands come from one parse and there is no next read; a separate 'exit'
# line would be read at that same stale offset and never run.
self_rewriting_scripts_exit_explicitly() {
  local f rewriters=() last
  # deploy/ is in the search now, and so is 'pull --ff-only'. The first version
  # looked only at "${REPO}"/*.sh for 'merge --ff-only|reset --hard', and missed
  # deploy/do-user-data.sh on both counts: it lives one directory down, and it
  # updates itself with 'git pull --ff-only'. Its last line is a pipeline, which
  # makes no difference — measured: the replacement's tail runs just the same.
  for f in "${REPO}"/*.sh "${REPO}"/deploy/*.sh; do
    if grep -qE 'git .*(merge --ff-only|reset --hard|pull --ff-only)' "${f}"; then
      rewriters+=("${f}")
    fi
  done
  # Assert the search found something, so a regex that quietly stops matching
  # cannot pass as "nothing to check".
  (( ${#rewriters[@]} >= 3 )) || {
    printf 'expected install.sh, update.sh and do-user-data.sh, got %s\n' "${#rewriters[@]}" >&2
    return 1
  }
  for f in "${rewriters[@]}"; do
    last="$(tail -1 "${f}")"
    # The property is that the call and the exit come out of ONE parse, so the
    # last line must both invoke main and END with the exit. An 'exit $?' on
    # the next line satisfies "the file ends with an exit" and fixes nothing:
    # that line is read at the stale offset too, and never runs. The first
    # version of this check looked for the substring anywhere and passed on
    # exactly that; the second demanded the literal 'main "$@"; exit $?', which
    # was right until do-user-data.sh arrived invoking main through a pipeline.
    [[ "${last}" == *main* && "${last}" == *'; exit $?' ]] || {
      printf '%s can replace itself mid-run but ends with: %s\n' "${f##*/}" "${last}" >&2
      return 1
    }
  done
}
check "the self-rewriting scripts stop bash reading a file they replaced" \
  self_rewriting_scripts_exit_explicitly

echo "# ...and no test may have asked the real docker daemon anything"
# The counterpart to the overrides at the top of this file. If this fails, a
# test reached a docker probe it did not stub, which means its result came from
# whatever happened to be running on this machine — green here, red in CI, or
# the other way round, with nothing to show which.
no_test_asked_the_real_docker() {
  [[ -s "${LCA_UNSTUBBED_LOG}" ]] || return 0
  printf 'a test reached an unstubbed docker probe, so its answer came from this machine rather than its fixture:\n' >&2
  sort -u "${LCA_UNSTUBBED_LOG}" | sed 's/^/  /' >&2
  return 1
}
check "no test read the real docker daemon instead of its fixture" \
  no_test_asked_the_real_docker
# ...and the counterpart for vacuity. If this fails, some gate called a
# function that did not exist at that moment — most likely a helper defined
# below its caller — and whatever it was meant to compare, it compared nothing
# while reporting ok.
no_test_called_a_missing_command() {
  [[ -s "${LCA_MISSING_CMD_LOG}" ]] || return 0
  printf 'a test called a command that does not exist, so whatever it checked, it checked nothing:\n' >&2
  sort -u "${LCA_MISSING_CMD_LOG}" | sed 's/^/  /' >&2
  return 1
}
check "no test called a command that does not exist" \
  no_test_called_a_missing_command
# ...and the counterpart for stubs that escalation walks straight past. Every
# directory this suite puts in front of PATH must come from make_stub_dir, so
# the fake is reached whether the script calls the command directly or through
# as_root. A plain 'mkdir -p .../stub' compiles, runs, and passes for whoever
# is root — and only for them; see make_stub_dir for the CI run that cost.
every_path_stub_survives_sudo() {
  local bad=0 seen=0 use dir_expr
  # Deliberately built from pieces: this gate greps the file it lives in, and
  # a contiguous literal here would match itself.
  local pat='PATH="[^"]*'"/stub:"
  while IFS= read -r use; do
    seen=$((seen+1))
    dir_expr="${use#PATH=\"}"        # -> ${sb}  or  ${DUD_SB}
    dir_expr="${dir_expr%/stub:}"
    grep -qF "make_stub_dir \"${dir_expr}/stub\"" "${TESTS_DIR}"/*.sh || {
      printf 'a stub directory is put on PATH without make_stub_dir, so sudo will not see it: %s/stub\n' \
        "${dir_expr}" >&2
      bad=1
    }
  done < <(grep -oh "${pat}" "${TESTS_DIR}"/*.sh | sort -u)
  # A gate that matched nothing passes, and this one recognises stub
  # directories by a naming convention it does not enforce. If the convention
  # moves, say so rather than reporting ok about zero directories — the exact
  # shape of the vacuous gate two checks above exists to catch.
  (( seen > 0 )) || {
    echo 'this gate found no PATH stub directories at all — the idiom it recognises has moved, and it is now checking nothing' >&2
    bad=1
  }
  return "${bad}"
}
check "every PATH stub is reached through sudo as well as directly" \
  every_path_stub_survives_sudo

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all tests passed"

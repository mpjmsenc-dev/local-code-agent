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
# Where deploy/do-user-data.sh tees the first-boot install. Both 'lca logs
# setup' and the login banner read it to answer "is it still installing?".
# do-user-data.sh cannot source this file — it runs before the clone exists —
# so it keeps its own literal, and a test holds the two together.
# Read by scripts/logs.sh and scripts/motd.sh, not here — ShellCheck analyses
# one file at a time and cannot see a sourcing consumer.
# shellcheck disable=SC2034
SETUP_LOG="${LCA_LOG:-/var/log/local-code-agent-setup.log}"
# Likewise: check-system.sh, uninstall.sh and scripts/motd.sh. The filename
# must stay free of dots — run-parts --lsbsysinit, which is how pam_motd runs
# these, skips any name containing one.
# shellcheck disable=SC2034
MOTD_FILE="/etc/update-motd.d/99-local-code-agent"

# The Open WebUI image, named once. Three scripts use it and only one owned
# the string: install_webui.sh created the container with it, while backup.sh
# and restore.sh hardcoded the same literal to borrow a tar binary next to the
# volume. Pin or move that tag and two of the three would go on using the old
# one — tarring a volume with a different image than the app runs.
WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"

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
    have "$cmd" || die "Required command '${cmd}' not found. Run ${REPO_ROOT}/setup.sh (or ${REPO_ROOT}/scripts/install_dependencies.sh) first."
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
#
# THE RULE, and there is a gate on it (tests/test-lib.sh):
#   an ACTION the user asked for   -> can_root.     A password prompt is fair:
#                                     they typed 'lca apply', 'webui.sh start'.
#   a PROBE that only reports      -> can_root_now. A prompt here is a stall in
#                                     something nobody asked to run.
# Getting this backwards is not a style question. It cost a login banner that
# hung for ever and two health-check lines that were confidently wrong; see
# can_root_now directly below.
can_root() {
  [[ "${EUID}" -eq 0 ]] || have sudo
}

# can_root_now — can this process become root WITHOUT prompting?
#
# can_root above answers "is the sudo binary installed", which is the right
# question for a step that is allowed to ask for a password. It is the wrong
# question for a PROBE, and the difference produced a false security alarm:
# 'lca check' as a user who is not a sudoer took the can_root branch, ran
# 'sudo nft list table', got nothing, and reported "inbound guard NOT loaded —
# WebUI/Ollama ports may be publicly reachable" on a machine whose guard may be
# perfectly loaded. It then advised 'sudo netmode.sh harden', which that user
# cannot run either. Measured on this box with a freshly created account.
#
# 'sudo -n' also means a probe can never sit waiting for a password inside a
# health check that setup.sh runs unattended. That is not a theoretical
# nicety: an interactive sudo on a real terminal does not fail, it WAITS.
# Measured from an account that is not a sudoer, the login banner printed two
# lines and then sat on "[sudo] password for ..." for as long as it was left —
# every SSH login, and the bounding 'timeout' was inside the sudo, so it never
# got to start. With this function: 0.10s.
can_root_now() {
  [[ "${EUID}" -eq 0 ]] && return 0
  have sudo || return 1
  sudo -n true >/dev/null 2>&1
}

# LCA_MAY_PROMPT / root_for_probe — who decides, for the SHARED helpers.
#
# The rule above is a property of the CALLER, not of the function. The three
# docker helpers further down are asked the same question by both kinds of
# caller: docker_daemon_reachable is a reporter's question inside the login
# banner and an action's question inside 'lca backup'. Deciding it inside the
# helper is wrong in one direction or the other every single time, and this
# project has now shipped BOTH mistakes:
#
#   can_root everywhere      -> 'lca check' and the banner stopped dead on a
#                               password prompt (measured: indefinitely).
#   can_root_now everywhere  -> 'lca backup' run without sudo by an ordinary
#                               sudoer skipped the chat history and called a
#                               perfectly healthy daemon "not usable".
#
# The second is the worse one: a backup that quietly omits the accounts and
# chat history is only discovered when it is restored.
#
# So the caller says, once, next to where it sources this file. The default is
# the strict answer, because the default caller is a reporter and a reporter
# that stops for a password is the bug all of this exists to prevent — a new
# script gets the safe behaviour by saying nothing.
: "${LCA_MAY_PROMPT:=false}"
root_for_probe() {
  if [[ "${LCA_MAY_PROMPT}" == "true" ]]; then
    can_root
  else
    can_root_now
  fi
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
    if [[ "${LCA_ENV_READONLY:-false}" == "true" ]]; then
      # Deliberately create nothing: see load_env_readonly below.
      :
    elif [[ -f "${ENV_EXAMPLE}" ]]; then
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
  SKIP_TAILSCALE="${SKIP_TAILSCALE:-false}"
  ENABLE_WEBUI="${ENABLE_WEBUI:-true}"
  WEBUI_PORT="${WEBUI_PORT:-3000}"
  WEBUI_CONTAINER="${WEBUI_CONTAINER:-open-webui}"
  WEBUI_NAME="${WEBUI_NAME:-local-code-agent}"
  WEBUI_ENABLE_SIGNUP="${WEBUI_ENABLE_SIGNUP:-true}"
  BACKUP_KEEP="${BACKUP_KEEP:-7}"
  BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-*-*-* 03:30:00}"
}

# env_file_is_inert FILE — true when FILE is settings and nothing else:
# comments, blank lines, and plain KEY=VALUE assignments with no expansion, no
# command substitution and no second command on the line.
#
# load_env SOURCES .env, so every line in it is shell that runs with the
# privileges of whoever called. That is fine for the file the user edits on
# their own machine. It is not fine for restore.sh, which copies a .env
# straight out of a tarball named on the command line and then calls load_env
# — as root, because a restore recreates docker volumes. docs/MIGRATE.md is
# built on moving that tarball between machines, so "it is your own backup" is
# an assumption about a file that has been off-box and back.
#
# Deliberately a whitelist. A blacklist of dangerous constructs is a list
# someone has to keep complete forever, and a real .env has never needed
# anything outside this shape — see .env.example, where the most exotic line is
# a double-quoted OnCalendar spec.
env_file_is_inert() {
  local file="$1" line
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # load_env strips CR before sourcing; match it, or a CRLF file would be
    # rejected here and accepted there.
    line="${line%$'\r'}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*= ]] || return 1
    # One character class rather than a list of constructs, so there is nothing
    # to keep complete: anything that could expand, substitute, start a second
    # command, redirect, or join this line to the next is out. The backslash
    # matters as much as the rest — a line ending in one continues, which would
    # hide a rejected construct on a line this loop reads separately.
    case "${line}" in
      *[\$\`\;\&\|\<\>\\]*) return 1 ;;
    esac
  done < "${file}"
  return 0
}

# The install's final verdict. Everything that reports on an install keys off
# these two lines: docs/YOUR-TURN.md and docs/DO.md tell the user to watch for
# them, deploy/do-user-data.sh documents them as its outcomes, and the login
# banner classifies the log by them. They live here so that the wording, and
# the exit status that must accompany it, cannot drift apart.
SETUP_DONE_LINE="SETUP COMPLETE — local-code-agent is ready."
SETUP_FAIL_LINE="SETUP FINISHED WITH ERRORS — run ${REPO_ROOT}/check-system.sh and see docs/TROUBLESHOOTING.md"

# setup_verdict OK — print the final line and RETURN THE MATCHING STATUS.
#
# The status is the point. setup.sh used to print SETUP FINISHED WITH ERRORS
# and then exit 0, which made deploy/do-user-data.sh's failure branch dead
# code — a droplet whose model never downloaded reported a successful
# first-boot install. A verdict nobody can act on programmatically is not a
# verdict.
setup_verdict() {
  if [[ "${1:-false}" == "true" ]]; then
    printf '\n%b%s%b\n' "${C_GREEN}${C_BOLD}" "${SETUP_DONE_LINE}" "${C_RESET}"
    return 0
  fi
  printf '\n%b%s%b\n' "${C_YELLOW}${C_BOLD}" "${SETUP_FAIL_LINE}" "${C_RESET}"
  return 1
}

# selftest_verdict PASS FAIL SKIP — the self-test's final line AND its exit
# status, here for the same reason setup_verdict is: docs/YOUR-TURN.md tells the
# reader to look for the line, 'lca update' rolls back on the status, and the
# two must not drift apart. Living in lib.sh also makes all three arms testable
# without doing the real generations the self-test does.
#
# The SKIP arm is why this exists. "Works end-to-end" is a claim about every
# part, and it may not be made while a part went unexamined — the rule 'lca
# apply' already follows when a component could not be checked. It still exits
# 0: a check that could not RUN is not a failed check, and update.sh treats a
# non-zero self-test as reason to offer a rollback.
selftest_verdict() {
  local pass="${1:-0}" fail="${2:-0}" skip="${3:-0}"
  info "PASS=${pass}  FAIL=${fail}  SKIPPED=${skip}"
  if (( fail > 0 )); then
    printf '%b%s%b\n' "${C_YELLOW}${C_BOLD}" \
      "SELF-TEST FAILED (${fail}) — see the failing checks above and docs/TROUBLESHOOTING.md." "${C_RESET}"
    return 1
  fi
  if (( skip > 0 )); then
    printf '%b%s%b\n' "${C_YELLOW}${C_BOLD}" \
      "SELF-TEST PASSED, WITH ${skip} CHECK(S) SKIPPED — everything that could be tested works; see the skipped one(s) above before trusting this end-to-end." "${C_RESET}"
    return 0
  fi
  printf '%b%s%b\n' "${C_GREEN}${C_BOLD}" \
    "SELF-TEST PASSED — your local-code-agent stack works end-to-end." "${C_RESET}"
  return 0
}

# load_env_readonly — load_env's values without load_env's side effect.
#
# load_env creates .env from .env.example when it is missing, which is right
# for a command the user ran. It is wrong for the login banner: that runs as
# ROOT on every SSH login, so merely logging into a box where setup has not
# finished would silently leave a root-owned .env in the repo — and the next
# non-root setup.sh or 'lca' run would then fail to write it. Reading through
# load_env rather than re-parsing .env keeps the defaults in one place.
load_env_readonly() {
  LCA_ENV_READONLY=true load_env
}

# git_identity_user — whose git config actually matters here.
#
# Under sudo that is the human, not root: aider runs as them, and root's empty
# identity would be the wrong answer to report.
git_identity_user() { printf '%s\n' "${SUDO_USER:-$(id -un)}"; }

# git_identity — "Name <email>" from that user's GLOBAL git config, or nothing
# (and non-zero) when either half is unset.
#
# One copy, because two reporters ask the same question. install_git.sh warns
# about it at install time — inside a 20-30 minute log nobody reads twice — and
# 'lca check' is where anyone looks afterwards. Without it:
#
#   - aider still commits, but stamps the work with a placeholder author.
#     Measured on a HOME with no gitconfig: 'Your Name <you@example.com>'.
#   - a 'git commit' the user runs themselves in that project refuses outright:
#     "Author identity unknown ... Please tell me who you are." Measured on a
#     host whose hostname has no domain, which is every fresh droplet.
#
# The chat's handover sends people into a brand-new git repo, so this is the
# first thing many of them will do.
git_identity() {
  local who name email
  have git || return 1
  who="$(git_identity_user)"
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]] && have sudo; then
    name="$(sudo -u "${who}" git config --global user.name 2>/dev/null || true)"
    email="$(sudo -u "${who}" git config --global user.email 2>/dev/null || true)"
  else
    name="$(git config --global user.name 2>/dev/null || true)"
    email="$(git config --global user.email 2>/dev/null || true)"
  fi
  [[ -n "${name}" && -n "${email}" ]] || return 1
  printf '%s <%s>\n' "${name}" "${email}"
}

# set_env_var KEY VALUE — update KEY in .env in place, or append it, so that a
# following load_env reads the value back unchanged.
#
# The old note here said values "never contain spaces", and every caller today
# honours that (MODEL_NAME, AUTO_TUNE, OLLAMA_CONTEXT_LENGTH). But .env holds
# one setting that legitimately does — BACKUP_SCHEDULE="*-*-* 03:30:00" — and
# writing that unquoted CORRUPTS the file: 'source' takes the remainder as a
# command ("05:00:00: command not found") and the variable ends up EMPTY. Since
# tune.sh calls this on every boot, that is not a footgun to leave armed.
#
# Quoting is applied only when the value actually contains whitespace, so every
# write made today is byte-for-byte what it was before and the boot path cannot
# change behaviour.
# write_env_or_die KEY VALUE [EXTRA] — set_env_var, but a failure explains
# itself instead of leaving sed to do it.
#
# Every caller outside load_env's back-fill was a bare 'set_env_var', so under
# 'set -e' a failed write ended the script with nothing to read but sed's own
#
#   sed: couldn't flush <unknown>: No space left on device
#
# Measured on a full filesystem, and that is the likeliest moment for it: the
# disk fills with models at gigabytes each, and 'lca model' — which writes
# MODEL_NAME — is exactly what someone runs to fix that.
#
# The promise in the message is real: sed -i writes a temp file and renames, so
# a failed write leaves .env byte for byte as it was. Verified on the same full
# filesystem, 59 bytes before and after.
write_env_or_die() {
  local rc=0
  set_env_var "$1" "$2" || rc=$?
  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 2 )); then
    # A refused value: set_env_var has already said exactly what was wrong
    # with it, and repeating that in different words helps nobody. Only 2 —
    # 1 is what a failed append returns, which is a write failure and needs
    # the message below.
    exit 1
  fi
  die "Could not write ${1} to ${ENV_FILE} (sed exited ${rc}) — a full disk is the usual cause, so check 'df -h'. ${ENV_FILE} was left exactly as it was; re-run once there is room.${3:+ $3}"
}

set_env_var() {
  local key="$1" value="$2" written="$2" bt bs
  # Built with printf rather than written inline: a literal backtick or
  # backslash inside a quoted pattern is either unreadable or SC1003.
  bt="$(printf '\140')"          # `
  bs="$(printf '\134')"          # \
  # Characters that cannot survive the round trip through the double quotes
  # below, or that would RUN inside them: a quote ends the string, '$' and a
  # backtick both expand, a backslash is eaten by 'source' ("a\\b" reads back
  # as a\b), and a newline is a second line. Refused rather than written as
  # something that reads back differently — or executes.
  #
  # The backtick and the backslash were not on this list. Nothing writes either
  # today, so this was never live; but the whole point of the list is that the
  # next caller does not have to know, and .env is a file load_env SOURCES.
  if [[ "${value}" == *'"'* || "${value}" == *'$'* || "${value}" == *"${bt}"* \
     || "${value}" == *"${bs}"* || "${value}" == *$'\n'* ]]; then
    err "Refusing to write ${key} to .env: the value contains a quote, backtick, backslash, '\$' or newline."
    # 2, not 1, and the distinction is load-bearing: the append below returns 1
    # when it cannot write, so a shared code would let write_env_or_die read a
    # genuinely failed write as "already explained" and exit saying nothing.
    # A refusal is about the VALUE; anything else is about the FILE.
    return 2
  fi
  # Quoted unless EVERY character is one 'source' reads back literally.
  #
  # The trigger was whitespace alone, and that is not the same question. An
  # unquoted A&B is two commands to the shell, not a value; so are A;B and A|B.
  # Every value written today — model tags, true/false, numbers, host:port — is
  # made only of the characters below, so each is still written unquoted, byte
  # for byte as before.
  if [[ "${value}" =~ [^A-Za-z0-9_.:/,@%+-] ]]; then
    written="\"${value}\""
  fi
  if [[ ! -f "${ENV_FILE}" ]]; then
    touch "${ENV_FILE}"
  fi
  if grep -q "^${key}=" "${ENV_FILE}"; then
    # sed's REPLACEMENT has its own two special characters, and '&' is the one
    # that bites: it means "everything the pattern matched". Measured before
    # this escaping existed —
    #     set_env_var WEBUI_NAME 'A&B'
    #     WEBUI_NAME=AWEBUI_NAME=local-code-agentB
    # — written, returned 0, and read back as that. A '|' would instead end the
    # s||| expression early and fail the write outright. A backslash cannot
    # reach here: it is refused above.
    local escaped="${written//&/\\&}"
    escaped="${escaped//|/\\|}"
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${written}" >> "${ENV_FILE}"
  fi
}

# sync_env_keys — add settings that exist in .env.example but not yet in .env.
#
# .env is created from .env.example exactly ONCE, on first run, and nothing has
# ever backfilled it. An install made before a setting existed therefore never
# learns that the setting exists: on this project's own build box, .env had 13
# keys against .env.example's 20. Behaviour was already correct — load_env
# supplies a default for anything missing — so this is about discoverability. A
# knob you cannot see in your own config is a knob you do not know you have.
#
# Existing values are NEVER touched; only absent keys are appended, each with
# the value that was already in force, so nothing changes behaviour.
sync_env_keys() {
  [[ -f "${ENV_FILE}" && -f "${ENV_EXAMPLE}" ]] || return 0
  local line key value added=()
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    # .env.example quotes values containing spaces (BACKUP_SCHEDULE); strip
    # that here because set_env_var re-adds quoting exactly when it is needed,
    # and doubling it would write a literal quote into the value.
    value="${value%\"}"; value="${value#\"}"
    if ! grep -q "^${key}=" "${ENV_FILE}"; then
      set_env_var "${key}" "${value}" && added+=( "${key}" )
    fi
  done < <(grep -E '^[A-Z_]+=' "${ENV_EXAMPLE}")
  if (( ${#added[@]} )); then
    info "Added ${#added[@]} setting(s) to .env that this install predates: ${added[*]}"
    info "Each was already in effect as a default — see .env.example for what they do."
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
# unique_backup_path DIR STAMP — a tarball path under DIR for STAMP that does
# not already exist.
#
# The stamp is second-granular, and a backup finishes inside one second
# whenever there is no WebUI volume to archive — a documented configuration
# (ENABLE_WEBUI=false), not a corner. Two runs then landed on the SAME path,
# and both said "Backup written and verified" while only one file survived.
# Measured, with two concurrent runs: two success lines, one tarball.
#
# The suffix is '_N', not '-N', and that is not cosmetic. backups_to_prune
# sorts these names lexically and treats the tail as newest, which works only
# because the embedded YYYYmmdd-HHMMSS makes lexical order chronological. '-'
# is 0x2D and '.' is 0x2E, so 'stamp-2.tar.gz' would sort BEFORE 'stamp.tar.gz'
# and retention would delete the newer file first. '_' is 0x5F, after '.', so
# the order holds.
unique_backup_path() {
  local dir="$1" stamp="$2" path n=2
  path="${dir}/local-code-agent-backup-${stamp}.tar.gz"
  while [[ -e "${path}" ]]; do
    path="${dir}/local-code-agent-backup-${stamp}_${n}.tar.gz"
    n=$(( n + 1 ))
  done
  printf '%s' "${path}"
}

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

# ensure_ollama_up_announced TIMEOUT — ensure_ollama_up, but say so when it is
# going to take a while.
#
# The quiet form spends up to a minute starting the server with every word
# suppressed, which is indistinguishable from a hung terminal. That landed in
# the worst two places: 'lca ask', the command people type most, and
# 'lca speed', which people reach for precisely when the box already feels
# slow — where a silent minute is the least helpful answer available.
#
# The notice goes to STDERR because in 'lca ask' the model's answer is stdout,
# and progress must not end up inside a piped or redirected answer (load_env's
# ".env created" notice is on stderr for the same reason). Nothing is printed
# at all when Ollama is already up, which is the normal case.
ensure_ollama_up_announced() {
  local timeout="${1:-60}"
  wait_for_ollama 2 >/dev/null 2>&1 && return 0
  info "Ollama is not answering — starting it (this can take up to ${timeout}s)..." >&2
  ensure_ollama_up "${timeout}" >/dev/null 2>&1 || true
  wait_for_ollama 2 >/dev/null 2>&1
}

# model_present MODEL — true if MODEL is already downloaded.
model_present() {
  ollama show "$1" >/dev/null 2>&1
}

# pull_model MODEL — download MODEL with progress, with a clear failure.
# pull_model MODEL — download MODEL, retrying a transient registry failure.
#
# install_ollama.sh has retried the *installer* download since a CDN reset cost
# a whole run; the model pull had none, despite being the far bigger download —
# gigabytes on a real machine against ~400 MB here. CI then caught the exact
# failure it needed: the registry answered 503 at 396 MB of 397 MB, throwing
# the entire download away. On a droplet that aborts the first-boot install and
# the user is told their box is not ready.
#
# Retrying is cheap and safe because 'ollama pull' resumes: completed blobs are
# already in the local store, so a second attempt re-fetches only what is
# missing rather than starting over.
# ollama_models_dir — where Ollama keeps its blobs, for a free-space question.
# OLLAMA_MODELS wins if set; otherwise the systemd service account's store,
# then the invoking user's. The last branch is a best guess rather than a
# failure, because the answer only feeds a warning.
ollama_models_dir() {
  local d
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then printf '%s' "${OLLAMA_MODELS}"; return 0; fi
  for d in /usr/share/ollama/.ollama/models "${HOME}/.ollama/models"; do
    [[ -d "${d}" ]] && { printf '%s' "${d}"; return 0; }
  done
  printf '%s' "${HOME}/.ollama/models"
}

# free_gb PATH — whole GB free on PATH's filesystem, walking up to the nearest
# directory that exists (the models dir is created by the first pull).
free_gb() {
  local p="${1:-/}"
  while [[ ! -d "${p}" && "${p}" != "/" ]]; do p="$(dirname "${p}")"; done
  df -Pk "${p}" 2>/dev/null | awk 'NR == 2 { printf "%d\n", $4 / 1048576 }'
}

# model_disk_gb TAG — roughly what TAG will occupy, in whole GB.
#
# The same ~0.6 GB per billion parameters at q4 that model_fits_ram and
# largest_model_for_vram already use, so a fourth estimate cannot drift from
# the other three, plus 1 GB for the manifest and rounding. Nothing (exit 1)
# for a tag with no parseable parameter count — an unknown size must not be
# turned into a confident refusal.
model_disk_gb() {
  local params
  params="$(model_params_b "$1" 2>/dev/null)" || return 1
  awk -v p="${params}" 'BEGIN { printf "%d\n", p * 0.6 + 1 }'
}

pull_model() {
  local model="$1" attempt need="" free_now="" store
  store="$(ollama_models_dir)"
  # Asked BEFORE the download, not after it. Every other disk message in this
  # project is a post-mortem — "disk full? check df -h" — which on a pull means
  # finding out after several gigabytes have already crossed the wire, on a VPS
  # whose disk is fixed. Skipped silently when either number is unknown: a
  # guess must not become a refusal.
  if need="$(model_disk_gb "${model}")" && free_now="$(free_gb "${store}")" \
     && [[ -n "${free_now}" ]] && (( free_now < need )); then
    err "'${model}' needs about ${need} GB and only ${free_now} GB is free on ${store}. Nothing has been downloaded. Free some space — 'ollama list' shows what is already there, 'ollama rm <model>' removes one — then retry."
    return 1
  fi
  info "Pulling model '${model}' (this can take several minutes on first download)..."
  for attempt in 1 2 3; do
    if ollama pull "${model}"; then
      ok "Model '${model}' is available locally."
      return 0
    fi
    if (( attempt < 3 )); then
      # A pull that ran the disk out will not succeed on a retry, and retrying
      # re-downloads gigabytes — twice, at five and ten seconds' notice. Asked
      # by re-measuring rather than by reading ollama's output, because
      # capturing that would hide the progress a multi-GB download needs to
      # show. The retry is for a transient registry error; a full disk is not
      # one of those.
      if [[ -n "${need}" ]] && (( $(free_gb "${store}") < need )); then
        err "'${model}' ran ${store} out of space part way through — not retrying, because the next attempt would download it all again. Free some space ('ollama rm <model>') and re-run."
        return 1
      fi
      warn "Pull attempt ${attempt}/3 for '${model}' failed (transient registry error?) — retrying in $((attempt * 5))s; finished parts are kept."
      sleep "$((attempt * 5))"
    fi
  done
  err "Failed to pull '${model}' after 3 attempts. Check your internet connection (is netmode offline? run: sudo ${REPO_ROOT}/netmode.sh status)."
  return 1
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
  # Captured, then matched against a here-string. 'lspci | grep -qi' is the
  # shape that returns 141 under pipefail when grep exits on an early match
  # while the producer is still writing — measured with a match at the head of
  # a 200 KiB stream: the pipe form reported NOT FOUND, the capture form found
  # it. A PCI listing is small enough that this has probably never fired, and
  # that is exactly the argument that keeps a footgun loaded.
  local devices
  devices="$(lspci 2>/dev/null || true)"
  [[ -n "${devices}" ]] && grep -qi 'nvidia' <<<"${devices}"
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
    # Normalised to base 10 ONCE, here, rather than at each comparison. Bash
    # reads a leading zero as OCTAL, so a zero-padded reading does not compare
    # wrong — it ERRORS: measured with '08192', bash printed
    #   ((: 08192: value too great for base (error token is "08192")
    # from inside a function whose whole job is to answer a question quietly,
    # then dropped the reading and reported no VRAM at all.
    #
    # Fixing only the comparison below is not enough, which is why this
    # normalises instead: '(( best > 0 ))' at the end hits the same trap, and
    # the padded string would be printed back to the caller to trip over next.
    # nvidia-smi does not pad today; not depending on that costs one line.
    line=$(( 10#${line} ))
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

# gpu_state_for_placement PLACEMENT — classify_gpu against this machine, for a
# placement string the caller has ALREADY read out of 'ollama ps'.
#
# Both reporters used to read that string themselves and then decide what it
# meant from its shape alone: "it contains a slash, therefore the model is
# split across CPU and GPU". On a machine with no NVIDIA card that is a
# conclusion about a device which does not exist — and Ollama 0.32.5 prints
# exactly that string on a CPU-only box. Measured here, on a host with no
# /dev/dri, no display device and no nvidia-smi:
#
#   qwen2.5-coder:7b   5.1 GB   13%/87% CPU/GPU   4096
#
# at 5.3 tokens/second, which is CPU speed for 7b on this machine and matches
# docs/PERFORMANCE.md's CPU-only figure. 'lca check' printed "no NVIDIA GPU —
# CPU inference" and then, three lines later, told the reader their model was
# "only partially on the GPU" and to pick one that fits their VRAM. 'lca speed'
# said the same. classify_gpu has always got this right — it refuses to reach
# the placement branches without a card AND a driver — and neither caller
# asked it.
#
# Taking the placement as an argument keeps each caller to one 'ollama ps', and
# means the string a message quotes is the same one that was classified.
gpu_state_for_placement() {
  local card=false driver=false
  gpu_hardware_present && card=true
  have nvidia-smi && nvidia-smi -L >/dev/null 2>&1 && driver=true
  classify_gpu "${card}" "${driver}" "${1:-}"
}

# gpu_state — the same, reading the placement for MODEL itself.
gpu_state() {
  gpu_state_for_placement "$(ollama_processor "${1:-${MODEL_NAME:-}}" 2>/dev/null || true)"
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
  # The NAME column, matched EXACTLY — not a substring of the row.
  #
  # 'ollama ps' lists every model currently resident, and 'grep -F' on the
  # whole line matched 'qwen2.5-coder:7b-instruct' when asked about
  # 'qwen2.5-coder:7b'. Measured: asked about the 7b sitting at 100% GPU, it
  # answered 100% CPU — the instruct model's row, which happened to come first.
  # Two models are resident whenever 'lca ask -m OTHER' has run inside
  # OLLAMA_KEEP_ALIVE, and :7b alongside :7b-instruct is an ordinary pair of
  # tags rather than a contrived one.
  #
  # The wrong answer is not cosmetic: this is what 'lca check' reports about
  # whether YOUR model is on the GPU, on the machine someone paid for a GPU.
  #
  # No 'exit' in the awk, deliberately. Stopping at the first match would close
  # the pipe while 'ollama ps' is still writing, and 141 under pipefail reads
  # as "model not loaded" — the trap this file gates against elsewhere. It
  # reads to the end and keeps the first hit.
  #
  # ENVIRON rather than -v: -v processes backslash escapes in the value, and a
  # model tag is user-supplied text.
  line="$(m="${model}" awk '$1 == ENVIRON["m"] && !seen { line = $0; seen = 1 }
                            END { if (seen) print line }' || true)"
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
# write_root_file DEST [MODE] — install stdin at DEST without ever leaving a
# half-written file there.
#
# Replaces 'producer | as_root tee DEST'. tee opens DEST and TRUNCATES it
# before the producer has written a byte, so anything that goes wrong part way
# through replaces a working file with a fragment. Demonstrated: an unbound
# variable inside render_ollama_dropin_content left the drop-in holding its
# header and '[Service]' and nothing else — the OLLAMA_HOST and context-length
# lines simply gone, on a file that had been correct a moment earlier.
#
# For the systemd units that matters more than it sounds. systemd will not load
# a unit it cannot parse, and one of them is the service that re-applies the
# inbound guard at boot: a truncated copy means the WebUI and Ollama ports come
# back PUBLIC at the next reboot — the exact failure the rest of this project
# spends paragraphs preventing.
#
# The temp sits beside DEST so the last step is a rename within one filesystem:
# atomic, and impossible to half-do. DEST is not opened at all until the whole
# content is on disk, so a full disk costs the temp and nothing else.
#
# Callers must still check the PIPELINE status, or better, materialise the
# content first — nothing downstream can tell a producer that died early from
# one that simply had little to say.
write_root_file() {
  local dest="$1" mode="${2:-0644}" tmp="$1.lca-new"
  if ! as_root tee "${tmp}" >/dev/null; then
    as_root rm -f "${tmp}" 2>/dev/null || true
    return 1
  fi
  if as_root chmod "${mode}" "${tmp}" && as_root mv -f "${tmp}" "${dest}"; then
    return 0
  fi
  as_root rm -f "${tmp}" 2>/dev/null || true
  return 1
}

render_ollama_dropin() {
  # Rendered into a variable FIRST, so a failure inside the renderer is caught
  # while the existing drop-in is still untouched. Piping the renderer straight
  # at the destination is what let a mid-render error truncate it.
  local content
  content="$(render_ollama_dropin_content)" \
    || die "Could not render the Ollama settings — ${OLLAMA_DROPIN} is unchanged."
  as_root mkdir -p "${OLLAMA_DROPIN_DIR}"
  printf '%s\n' "${content}" | write_root_file "${OLLAMA_DROPIN}" \
    || die "Could not write ${OLLAMA_DROPIN} — a full disk is the usual cause, so check 'df -h'. The previous settings are still in place."
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
#
# "with nothing after it" is there because it was measured. On the 3b rung,
# asked the starter question the empty screen offers — "which tasks need the
# terminal agent instead? give me the exact command" — the previous wording
# named the bare word only 6 times in 10, and the misses handed out 'lca
# apply': a real command that does something else and needs sudo. Adding that
# one clause took it to 9 in 10, with all four other bench questions
# unchanged at n=6.
#
# The variant that did NOT work is worth more than the one that did. Naming
# the wrong answer as a counter-example — "every 'lca <word>' is a server
# command, not the agent: 'lca ask' prints text, 'lca apply' changes
# settings" — measured 1 in 10. Mentioning 'lca apply' taught it 'lca apply'.
# So: state what the command IS, and do not enumerate what it is not.
#
# "a service that will not start" is in the server-question list for the same
# kind of reason, from the other side. That starter question — "walk me through
# diagnosing it, starting with the exact commands" — has the SHAPE of a build
# request while being a question about this box, and the handover fired on it
# 13 times in 20. Naming the case in the list of things that are NOT a build
# request took it to 6 in 20, and did not cost the handover elsewhere: at the
# same seeds, build held at 18/20 against 19/20 with tutorials 2/20 against
# 3/20, and the terminal starter improved from 12/20 to 16/20. Adding to the
# list of RIGHT answers is safe in a way that naming a wrong one is not.
#
# One more thing that measurement showed, and it is worth knowing before
# editing anything here: re-wrapping that same sentence — identical words, one
# line break moved — took service from 9/20 to 6/20. About one standard error
# at n=20, which is the scale of wobble to expect from any edit at all.
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

You are a chat box: no filesystem, no shell, no sight of the user's project.
You have NO tools — never emit a function or tool call, and never claim to be
performing an action. Answer with text, including complete code to copy.

Only aider writes files, and it runs as the bare word 'lca' with nothing
after it — not 'lca ask', which prints text and touches no file. When asked to build, create, make or
add anything that spans more than one file, do not walk the user through it.
Open with exactly:

  # in a terminal on the server (SSH in from your phone)
  mkdir -p ~/my-project && cd ~/my-project && lca

Add one line: aider writes those files for you, on this same model. Then offer
to write any single file's contents here.

Questions about this server itself — backups, logs, speed, disk, a service
that will not start, an error message — are NOT that. Answer those directly
with the 'lca' command that does the job, and never send them to aider.

The server manages itself through one command, 'lca':
  lca            start the coding agent (aider) — the ONLY one that writes files
  lca apply      make the running system match .env edits (needs sudo)
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

# run_reader PROBE_CMD... -- REAL_CMD... — decide once, with a cheap probe,
# whether a log reader needs root, then run the real command directly.
#
# The obvious shape ("run it; if that fails, retry under sudo") is wrong for a
# follow: `journalctl -f` only ends when the user presses Ctrl-C, which exits
# non-zero, so the retry would silently restart the follow under sudo. Probing
# first also avoids a sudo password prompt on the many setups where reading the
# journal or Docker already works unprivileged (journal/docker group).
run_reader() {
  local -a probe=() real=()
  local seen=false arg
  for arg in "$@"; do
    if [[ "${arg}" == "--" && "${seen}" == "false" ]]; then seen=true; continue; fi
    if [[ "${seen}" == "false" ]]; then probe+=( "${arg}" ); else real+=( "${arg}" ); fi
  done
  (( ${#probe[@]} > 0 && ${#real[@]} > 0 )) || return 2
  if "${probe[@]}" >/dev/null 2>&1; then
    "${real[@]}"
    return 0
  fi
  # Passwordless first, interactive second, and the second says so — the same
  # order as webui.sh's select_docker, for the same measured reason: 'lca logs'
  # printed its ollama section and then sat on a bare "[sudo] password for ..."
  # under the next header. A typed command may ask; it may not ask silently.
  # elif, not a second if: exactly one escalation attempt, and the sentence
  # about a password is printed only where a password can actually be asked
  # for. Root reaching this point has simply failed the probe.
  if can_root_now; then
    if as_root "${probe[@]}" >/dev/null 2>&1; then
      as_root "${real[@]}"
      return 0
    fi
  elif can_root; then
    # stderr, so it cannot land inside a log stream someone is piping.
    warn "Reading this needs root — sudo may ask for your password."
    if as_root "${probe[@]}" >/dev/null 2>&1; then
      as_root "${real[@]}"
      return 0
    fi
  fi
  return 1
}

# warm_model [MODEL] — best-effort, DETACHED: pull MODEL into RAM so the first
# real request does not pay the load.
#
# Worth doing because nothing else loads the model at boot. tune.sh only
# validates when the model is CHANGING, and when it does change it restarts
# Ollama immediately afterwards, dropping what it just loaded — so after every
# reboot the first message pays full price. OLLAMA_KEEP_ALIVE does not help:
# it stops a loaded model being evicted, it never preloads one.
#
# Detached on purpose. Measured on a cold page cache, loading a 7B model took
# 228 seconds, against 0.3s once resident. A bounded wait is worse than
# useless there: a 300s timeout was measured timing out and leaving the model
# still UNloaded, having spent the entire five minutes. Backgrounding lets the
# boot oneshot finish at once (measured: 0.007s to return) while the load
# proceeds; if the user beats it to the first message they are no worse off
# than they are today.
warm_model() {
  local model="${1:-${MODEL_NAME}}" payload
  have curl && have jq || return 0
  [[ -n "${model}" ]] || return 0
  payload="$(jq -n --arg m "${model}" \
    '{model:$m, prompt:"hi", stream:false, options:{num_predict:1}}')" || return 0
  info "Warming ${model} in the background so the first message is not slow."
  ( curl -sS --max-time 1800 -X POST "$(ollama_url)/api/generate" \
      -H 'Content-Type: application/json' -d "${payload}" >/dev/null 2>&1 & ) </dev/null
  return 0
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

# --- applied state -----------------------------------------------------------
# Three settings in .env are not read fresh: they are baked into a systemd
# drop-in, a docker container and a systemd timer when each is created. Reading
# back what was actually applied is therefore its own job, and one that has now
# been got wrong three separate times — so it lives here once.

# webui_container_env KEY — the value KEY was baked into the running container
# with. Non-zero (and prints nothing) when the container or the key is absent.
webui_container_env() {
  local env_lines out fmt runner=()
  have docker || return 1
  # Bounded, because 'docker inspect' is not. The CLI waits for ever on a
  # daemon that accepts the socket connection and then answers nothing, and
  # every caller of this function is a REPORTER — 'lca check', 'lca test',
  # 'lca apply', the login banner. A reporter that hangs is strictly worse
  # than one that says "cannot tell", and the banner runs on every SSH login:
  # there, a hang is a machine you cannot get into to fix the daemon.
  #
  # Callers that must answer fast lower it (LCA_INSPECT_TIMEOUT=2). Not an
  # .env key on purpose: it is a property of the caller, not of the install.
  if have timeout; then runner=(timeout "${LCA_INSPECT_TIMEOUT:-15}"); fi
  fmt='{{range .Config.Env}}{{println .}}{{end}}'
  # root_for_probe, and the timeout above is why the default MATTERS here.
  # 'sudo timeout 15 docker inspect' bounds docker, not sudo: the password
  # prompt happens before timeout is ever exec'd, so it is outside the bound.
  # Measured on this box with an account that is not a sudoer: the login
  # banner printed its first two lines, then sat on "[sudo] password for ..."
  # for as long as it was left running. Every SSH login, on the one code path
  # whose comment above says it must never hang. The banner sets nothing, so
  # it gets the strict default; 'lca apply' opts in and may ask.
  env_lines="$("${runner[@]}" docker inspect -f "${fmt}" "${WEBUI_CONTAINER}" 2>/dev/null \
    || { root_for_probe && as_root "${runner[@]}" docker inspect -f "${fmt}" "${WEBUI_CONTAINER}" 2>/dev/null; } \
    || true)"
  [[ -n "${env_lines}" ]] || return 1
  out="$(sed -n "s/^$1=//p" <<<"${env_lines}" | head -1)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}"
}

# docker_daemon_reachable — true when docker commands can actually run here.
#
# Needed because "no container" and "cannot ask" are different answers that
# every docker probe collapses into the same non-zero exit. Telling someone
# their chat app was never created, when the truth is that dockerd is down,
# sends them to an install command that cannot work either.
# root_for_probe, not can_root or can_root_now: every caller of this asks the
# same question and means a different thing by it. 'lca backup' may ask for a
# password; the login banner may not.
docker_daemon_reachable() {
  have docker || return 1
  docker info >/dev/null 2>&1 && return 0
  root_for_probe && as_root docker info >/dev/null 2>&1
}

# webui_container_exists — true when the chat app's container is present, in
# any state. Deliberately distinct from "matches .env": a container that does
# not exist has not drifted, it is simply absent, and reporting that as
# "already matches your settings" is the kind of confidently-wrong line this
# project keeps taking out.
webui_container_exists() {
  have docker || return 1
  docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1 && return 0
  root_for_probe && as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1
}

# webui_drift — echo the .env keys whose value has not reached the running
# container, one per line; return non-zero when nothing has drifted.
#
# The comparison lives in exactly one place on purpose. It was written out
# three times inline, and the third — signups — was simply never added, which
# left people believing they had closed their chat app when they had not.
webui_drift() {
  local drifted=() live want
  live="$(webui_container_env PORT || true)"
  [[ -z "${live}" || "${live}" == "${WEBUI_PORT}" ]] || drifted+=("WEBUI_PORT")
  live="$(webui_container_env DEFAULT_MODELS || true)"
  [[ -z "${live}" || "${live}" == "${MODEL_NAME}" ]] || drifted+=("MODEL_NAME")
  live="$(webui_container_env ENABLE_SIGNUP || true)"
  [[ -z "${live}" || "${live}" == "${WEBUI_ENABLE_SIGNUP}" ]] || drifted+=("WEBUI_ENABLE_SIGNUP")
  # Not cosmetic, and the worst of the set: this is how the chat app reaches
  # Ollama. docs/TROUBLESHOOTING.md tells people to move OLLAMA_HOST to another
  # port and re-run install_ollama.sh — which does not touch the container — so
  # following our own instructions leaves the phone talking to a port nothing
  # listens on, with the drop-in perfectly correct and no error anywhere.
  live="$(webui_container_env OLLAMA_BASE_URL || true)"
  [[ -z "${live}" || "${live}" == "$(ollama_url)" ]] || drifted+=("OLLAMA_HOST")
  # Cosmetic, but the same silence: renaming the app in .env appears to do
  # nothing at all.
  live="$(webui_container_env WEBUI_NAME || true)"
  [[ -z "${live}" || "${live}" == "${WEBUI_NAME}" ]] || drifted+=("WEBUI_NAME")
  # The assistant's own instructions, and the starter questions beside them.
  # Neither is an .env key — they live in lib.sh and config/ — which is exactly
  # why they were missed: the gate below scanned install_webui.sh for lines
  # beginning '-e KEY=', and these two are baked in from inside an array
  # literal as '-e "KEY=..."'. So the two settings that decide what the
  # assistant will and will not do were the only two nothing compared.
  #
  # That is not a theoretical gap. Pulling a repo with a better prompt and
  # running 'lca apply' answered "already matches .env" and changed nothing —
  # the same silence as the signup bug, on the setting a real user had just
  # been bitten by.
  #
  # Both are skipped without jq, because without jq the installer never baked
  # them in either; there is nothing to differ from. The prompt comparison
  # itself is webui_prompt_drifted, one function down — the login banner asks
  # that question alone and must not pay for the six values above to do it.
  if have jq; then
    if webui_prompt_drifted; then drifted+=("SYSTEM_PROMPT"); fi
    want=""
    if [[ -r "${REPO_ROOT}/config/prompt-suggestions.json" ]]; then
      want="$(jq -c . "${REPO_ROOT}/config/prompt-suggestions.json" 2>/dev/null || true)"
    fi
    live="$(webui_container_env DEFAULT_PROMPT_SUGGESTIONS || true)"
    [[ -z "${want}" || -z "${live}" || "${live}" == "${want}" ]] \
      || drifted+=("PROMPT_SUGGESTIONS")
  fi
  (( ${#drifted[@]} )) || return 1
  printf '%s\n' "${drifted[@]}"
}

# webui_prompt_drifted — true ONLY when the assistant's own instructions baked
# into the running container are DIFFERENT from this repo's.
#
# Its own predicate so a caller can ask that one question with a single docker
# inspect instead of the seven webui_drift needs. The login banner is that
# caller, and it runs on every SSH login.
#
# Positive answers only, the same asymmetry as motd.sh's model_missing: no jq,
# no container, an unreadable value — all of them are "cannot tell" and return
# non-zero. A banner that cried "out of date" whenever it could not look would
# be ignored inside a week, and being ignored is the one failure mode that
# makes the line worthless.
webui_prompt_drifted() {
  local want live
  have jq || return 1
  want="$(lca_system_prompt | jq -Rsc '{system: .}' 2>/dev/null || true)"
  live="$(webui_container_env DEFAULT_MODEL_PARAMS || true)"
  [[ -n "${want}" && -n "${live}" ]] || return 1
  [[ "${live}" != "${want}" ]]
}

# webui_prompt_comparable — true when webui_drift could actually compare the
# assistant prompt and starter questions. It skips both without jq, and when
# either side cannot be read; a caller that reports "matches" without knowing
# this is claiming a check it never made.
webui_prompt_comparable() {
  have jq || return 1
  [[ -n "$(lca_system_prompt 2>/dev/null || true)" ]] || return 1
  [[ -n "$(webui_container_env DEFAULT_MODEL_PARAMS 2>/dev/null || true)" ]] || return 1
  return 0
}

# --- the inbound guard's idea of .env vs .env's ------------------------------
#
# The guard bakes the ports in when it is applied, so it is drift in exactly
# the same way the ollama drop-in and the WebUI container are: change a port
# in .env and the guard goes on protecting the old one while the service
# listens on the new one, unauthenticated, on every interface.
#
# One copy of the rule on purpose. 'lca check' reports this and 'lca apply'
# fixes it, and two copies of a coverage rule is how one of them ends up
# calling a port safe that the other knows is exposed.

# valid_bool VALUE — exactly the two words every switch in .env is documented
# to take. Everything here compares against the literal string "true", so any
# other spelling silently means false: AUTO_TUNE=yes turns the headline feature
# off and nothing says so.
valid_bool() { [[ "${1:-}" == "true" || "${1:-}" == "false" ]]; }

# boolean_settings — the .env keys that ARE switches, read out of .env.example
# rather than listed here, so a new one is covered the day it ships.
boolean_settings() {
  [[ -r "${ENV_EXAMPLE}" ]] || return 1
  grep -oE '^[A-Z_]+=(true|false)$' "${ENV_EXAMPLE}" | cut -d= -f1 | sort -u
}

# valid_port PORT — a number a service can actually listen on.
#
# Not pedantry: netmode's own extractors already refuse a non-numeric
# WEBUI_PORT and fall back to 3000, while guarded_ports took whatever .env
# said. Those two disagreeing is what turns a typo into a loop — see below.
valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# guarded_ports — the service ports .env says must not be publicly reachable,
# as "Label port" lines. Returns 1 when there is nothing to guard.
guarded_ports() {
  local oport out=()
  oport="$(ollama_url)"; oport="${oport##*:}"
  # Port 22 is never guarded: netmode.sh refuses to put SSH in the drop set so
  # the guard can never lock anyone out. A service parked there is therefore
  # not a gap either — reporting it would be an unfixable failure, which is
  # worse than saying nothing.
  # Only ports that could BE guarded. A value that is not a port number is not
  # a gap in the guard, it is a broken setting — and treating it as a gap is
  # worse than saying nothing, because it cannot be closed. Measured with
  # WEBUI_PORT=abc: netmode's extractor falls back to 3000 and guards that,
  # this list asked for "WebUI abc", and inbound_guard_uncovered therefore
  # reported the guard stale for ever. 'lca check' said "run sudo lca apply",
  # apply re-applied the same guard and reported success, and the next check
  # said it again — a loop with no exit, and never once the word "abc".
  # check-system.sh names the real fault; this function stays quiet about it.
  if [[ "${ENABLE_WEBUI}" == "true" && "${WEBUI_PORT}" != "22" ]] \
     && valid_port "${WEBUI_PORT}"; then
    out+=("WebUI ${WEBUI_PORT}")
  fi
  if [[ "${oport}" != "22" ]] && valid_port "${oport}"; then
    out+=("Ollama ${oport}")
  fi
  # The port the container is REALLY on, when that is not the one .env names.
  #
  # Open WebUI's port is baked in at creation and it runs with --network=host,
  # so editing WEBUI_PORT leaves the running chat app listening on the old port
  # on every interface. The guard is rebuilt from .env — by a reboot, or by
  # 'harden' on its own — and covers the NEW port, leaving the old one, which
  # is the one actually accepting connections, reachable from the public IP.
  #
  # Reporting it does not create an unfixable failure: 'lca apply' re-creates
  # the container before it reconciles the guard, so by the time apply looks
  # here the live port and .env agree again. Where docker cannot be read at
  # all this yields nothing, which is the right answer to a question we cannot
  # ask.
  local live
  live="$(webui_container_env PORT 2>/dev/null || true)"
  if [[ "${live}" =~ ^[0-9]+$ && "${live}" != "22" && "${live}" != "${WEBUI_PORT}" ]]; then
    out+=("live WebUI ${live}")
  fi
  (( ${#out[@]} )) || return 1
  printf '%s\n' "${out[@]}"
}

# inbound_guard_uncovered DUMP — given the output of
# 'nft list table inet lca_inbound', print the guarded_ports it does NOT drop.
# Returns 1 when the guard covers everything (or there is nothing to cover).
inbound_guard_uncovered() {
  local dump="$1" entry port gaps=()
  while read -r entry; do
    [[ -n "${entry}" ]] || continue
    port="${entry##* }"
    # Anchored on word boundaries: a guard covering 11434 must not be read as
    # covering 1143.
    if ! grep -qE "dport \{[^}]*\b${port}\b" <<<"${dump}"; then
      gaps+=("${entry}")
    fi
  done < <(guarded_ports || true)
  (( ${#gaps[@]} )) || return 1
  printf '%s\n' "${gaps[@]}"
}

# installed_backup_schedule — the OnCalendar the backup timer is really on.
# systemd renders the property as '{ OnCalendar=<spec> ; next_elapse=<time> }',
# so the capture must stop at the ' ; ' — a '[^}]*' capture swallows the
# next_elapse tail and reports a garbled schedule.
installed_backup_schedule() {
  local out
  systemd_available || return 1
  out="$(systemctl show -p TimersCalendar --value local-code-agent-backup.timer 2>/dev/null \
    | sed -n 's/.*OnCalendar=\(.*\) ; next_elapse=.*/\1/p' | head -1)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}"
}

# --- what a boot unit will actually try to run ------------------------------
#
# 'systemctl is-enabled' is a statement about a symlink. It keeps answering
# "enabled" long after the checkout the unit points into was moved, renamed or
# deleted — every one of our three units bakes an absolute path from the
# installing checkout into ExecStart — and the breakage only surfaces at the
# next boot. For the netmode guard that means the WebUI and Ollama ports go
# public while 'lca check' reports the boot service as healthy; for the timer
# it means backups that silently never ran, discovered when one is needed.
# Reading the path back is the only way to see any of it coming.

# show_execstart_program — parse 'systemctl show -p ExecStart --value' (stdin).
# systemd renders it as '{ path=/x/y.sh ; argv[]=... ; ... }', so the capture
# has to stop at the ' ; ' — the same trap installed_backup_schedule documents.
show_execstart_program() {
  sed -n 's/.*path=\(.*\) ; argv\[\]=.*/\1/p' | head -1
}

# execstart_program FILE — the program named by a unit FILE's ExecStart. We
# write these ourselves as 'ExecStart="/path/to/script.sh" [args]', so the
# quoted form is what matters; the unquoted form is handled for units written
# by an older version of this repo. Reading the file is also the only source
# on a machine where systemd is installed but not running.
execstart_program() {
  local out
  [[ -r "$1" ]] || return 1
  out="$(sed -n 's/^ExecStart="\([^"]*\)".*/\1/p;s/^ExecStart=\([^" ]*\).*/\1/p' "$1" \
           | head -1)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}"
}

# unit_boot_program UNIT — the program that unit will execute, or nothing
# (exit 1) when it cannot be determined. systemd is asked first because a
# drop-in can override ExecStart and it is the authority on what will really
# run; the unit file is the fallback.
#
# SYSTEMD_UNIT_DIR is a seam for the tests, which cannot write to
# /etc/systemd/system; nothing sets it in normal use.
unit_boot_program() {
  local out=""
  if systemd_available; then
    out="$(systemctl show -p ExecStart --value "$1" 2>/dev/null | show_execstart_program)"
  fi
  [[ -n "${out}" ]] \
    || out="$(execstart_program "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$1" || true)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}"
}

# lca_link_state LINK EXPECTED — classify the 'lca' command on PATH.
#
# 'lca' is a symlink into a checkout, so moving or renaming that directory
# leaves it dangling — and the first thing anyone does about a stack that
# stopped working is type 'lca check', which is then the one command that
# cannot run. The copy in the checkout still can, so it should say so.
#
#   ok       a symlink to EXPECTED
#   broken   a symlink whose target cannot be executed (the moved checkout)
#   foreign  a symlink to a different checkout — 'lca check' would run other
#            code than the health check the reader is looking at right now
#   other    something else lives at that path; not ours to judge
#   absent   not installed (a rootless install never creates it)
lca_link_state() {
  local link="$1" want="$2" target
  # Resolve BOTH sides the same way before comparing. SCRIPT_DIR is built with
  # 'cd && pwd', which keeps a symlinked path, while readlink -f returns the
  # physical one — so a checkout reached through a symlinked parent (a /tmp on
  # macOS, a symlinked /opt, a bind-mounted home) would compare unequal and
  # report 'foreign': a frightening message about a perfectly healthy machine.
  want="$(readlink -f "${want}" 2>/dev/null || printf '%s' "${want}")"
  if [[ -L "${link}" ]]; then
    # readlink -f fails outright when a NON-final component is missing, which
    # is exactly the moved-checkout case; -x catches the rest.
    target="$(readlink -f "${link}" 2>/dev/null || true)"
    if [[ -z "${target}" || ! -x "${target}" ]]; then
      printf 'broken'
    elif [[ "${target}" == "${want}" ]]; then
      printf 'ok'
    else
      printf 'foreign'
    fi
    return 0
  fi
  if [[ -e "${link}" ]]; then
    printf 'other'
    return 0
  fi
  printf 'absent'
}

# reenable_hint UNIT INSTALLER — the command that will actually put UNIT back.
# 'systemctl enable' can only enable a unit file that exists, and the most
# likely reason a unit is not enabled is that nothing ever wrote it — so
# offering it unconditionally names a command that fails in the common case.
# INSTALLER is the heavier thing that writes the file.
reenable_hint() {
  if [[ -f "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/$1" ]]; then
    # Deliberately not '--now': that would run the unit immediately, and for
    # auto-tune that can mean an unasked-for model download. The question was
    # about the next boot.
    printf 'sudo systemctl enable %s' "$1"
  else
    printf '%s' "$2"
  fi
}

# stale_boot_program UNIT — echo the program a unit will try to run at boot,
# but only when that program is no longer there. Prints nothing and returns 1
# when the unit is fine AND when we could not work out what it runs: an answer
# we cannot compute is not evidence of a fault, and a health check that cries
# wolf about its own blind spot is worse than one that stays quiet.
stale_boot_program() {
  local prog
  prog="$(unit_boot_program "$1" || true)"
  [[ -n "${prog}" ]] || return 1
  [[ -x "${prog}" ]] && return 1
  printf '%s' "${prog}"
}

# resync_dropin_if_drifted — re-render the ollama drop-in and restart when the
# applied state has fallen behind .env. Returns 0 if it acted, 1 if there was
# nothing to do (or nothing to act on).
#
# One copy on purpose: the auto-tuned path, the manually-pinned path and
# 'lca apply' all need it, and two copies of a convergence rule is how one of
# them ends up forgotten — which is exactly how the AUTO_TUNE=false path came
# to ignore .env in the first place.
resync_dropin_if_drifted() {
  have ollama && systemd_available || return 1
  ollama_dropin_matches && return 1
  warn "Config drift: the ollama drop-in does not match .env — re-rendering and restarting to re-sync."
  render_ollama_dropin
  restart_ollama
  return 0
}

# normalized_calendar SPEC — systemd's own canonical form of an OnCalendar
# expression, so that "daily" and "*-*-* 00:00:00" compare equal.
#
# Comparing the raw strings would report drift on a perfectly healthy box the
# moment someone wrote a shorthand, which is the unfixable-warning trap the
# auto-tune ladder had. Returns non-zero (and prints nothing) when the answer
# cannot be determined — no systemd-analyze, or an invalid spec — so a caller
# can decline to claim drift it cannot prove.
normalized_calendar() {
  local out
  have systemd-analyze || return 1
  out="$(systemd-analyze calendar "$1" 2>/dev/null)" || return 1
  out="$(sed -n 's/^ *Normalized form: *//p' <<<"${out}" | head -1)"
  [[ -n "${out}" ]] || return 1
  printf '%s' "${out}"
}

# netmode_state — current persisted netmode ('online' when never toggled).
netmode_state() {
  if [[ -f "${NETMODE_STATE_FILE}" ]]; then
    cat "${NETMODE_STATE_FILE}"
  else
    echo "online"
  fi
}

# net_blocked — true when the kill switch is engaged, so no download can work.
#
# The predicate half of net_guard, for callers that must not die. net_guard
# die()s, which is exactly right for an installer: one that cannot download
# cannot install, and there is nothing else for it to do. It is wrong for a
# RECOVERY, where the download is one step among several and the others are
# still worth having — restore.sh died inside the WebUI volume step and took
# the model re-pull, the 'lca apply' reconciliation and the machine advice down
# with it, on a machine whose kill switch was doing exactly what it is for.
net_blocked() {
  [[ "$(netmode_state)" == "offline" ]]
}

# net_guard WHAT — die early with a helpful message when the netmode kill
# switch is engaged, instead of letting downloads time out confusingly.
net_guard() {
  local what="${1:-This step}"
  if net_blocked; then
    die "${what} needs internet access, but netmode is OFFLINE. Run: sudo ${REPO_ROOT}/netmode.sh online — then retry."
  fi
}

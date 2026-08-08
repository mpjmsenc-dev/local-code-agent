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

# Where start_ollama_bg() sends Ollama's output on a host with no service
# manager — and therefore where 'lca logs ollama' has to look on that host.
# Named once for the reason git_identity() gives: two places asking the same
# question drift, and these two already had. logs.sh answered "check the
# terminal you started 'ollama serve' in" on a box where this project started
# it itself, under 'nohup ... &', so there was no terminal to check and the log
# it wrote was sitting right here.
# shellcheck disable=SC2034
OLLAMA_BG_LOG="${REPO_ROOT}/.ollama-serve.log"   # *.log is gitignored

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
    have "$cmd" || die "Required command '${cmd}' not found. Run sudo ${REPO_ROOT}/setup.sh (or sudo ${REPO_ROOT}/scripts/install_dependencies.sh) first."
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

# writable_by_us PATH — true when this process could create or modify PATH.
#
# Its own function, like have_terminal beside it, so failure branches that
# depend on it can be tested. As root '[[ -w ]]' is true for every path, so a
# suite running as root can never reach the "not writable" arm and one running
# as anybody else can never reach the other.
writable_by_us() { [[ -w "$1" ]]; }

# readable_by_us PATH — true when this process could actually read PATH.
#
# For a directory that means both bits: r lists the names, x stats what is in
# them, and a glob over a directory with only one of the two comes back empty
# rather than failing. For a regular file r is the whole question — requiring x
# as well would call every backup archive unreadable, since they are 0600.
#
# Same seam, same reason as writable_by_us above: root reads everything, so the
# arm that matters is unreachable on a suite running as root.
readable_by_us() {
  [[ -r "$1" ]] || return 1
  [[ -d "$1" ]] || return 0
  [[ -x "$1" ]]
}

# sudo_would_block — true when becoming root is possible in principle but not
# in THIS run: sudo is installed, it will ask for a password, and there is no
# terminal to type it into.
#
# A predicate, never a die. It is consulted by failure branches that already
# have their own handling — some callers tolerate an apt failure with '|| warn'
# — and turning a survivable step into an exit is exactly the shape this
# project keeps removing.
#
# The distinction it draws is the one can_root_now already makes for probes,
# applied to an action that has just failed: "could have escalated" and "could
# escalate here, now, without a human" are different, and only the second one
# was ever going to work in a pipe, a cron job or a CI step.
# have_terminal — its own function so sudo_would_block can be tested in all
# four of its states. '[[ -t 0 ]]' cannot be stubbed from outside, so a test
# either re-declares the whole predicate (and stops testing it) or depends on
# whether a pty happened to be allocated. Both were tried; the first let a
# mutation through.
have_terminal() { [[ -t 0 ]]; }

sudo_would_block() {
  can_root_now && return 1     # root already, or sudo needs no password
  can_root || return 1         # no sudo at all — as_root's own message is better
  ! have_terminal
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

# docker_start_hint — how to start the Docker daemon ON THIS HOST.
#
# Five separate messages said "sudo systemctl start docker" unconditionally:
# webui.sh, restore.sh, apply.sh, install_webui.sh and check-system.sh. On a
# host with no systemd — containers and WSL, the same hosts start_ollama_bg()
# exists for — that is a dead end, and a confusing one. Measured here:
#
#   $ systemctl start docker
#   System has not been booted with systemd as init system (PID 1). Can't operate.
#   Failed to connect to bus: Host is down
#
# Note systemctl is PRESENT on such a box; it is systemd that is not running,
# which is why 'have systemctl' is not the question and systemd_available()
# below — which this project already had, and already used elsewhere — is.
#
# Same rule as chat_address() and the 'lca' rows in the banner: do not hand the
# reader a command that cannot work where they are standing.
docker_start_hint() {
  if systemd_available; then
    printf 'sudo systemctl start docker'
  else
    printf 'start the Docker daemon for this host — there is no systemd here, so systemctl cannot do it'
  fi
}

# docker_unreachable_advice — what to DO about a daemon this account cannot
# reach, given who this account is.
#
# docker_start_hint above asks "what works on this host". This asks the second
# half of the same question, "what works for this user", and three messages
# answered it with a fixed list. Measured on this box with the daemon genuinely
# down, running as root:
#
#   [FAIL] Cannot reach the Docker daemon as 'root'. Start it (...), or add
#          yourself to the docker group (sudo .../install_docker.sh) and log
#          out/in, or re-run this as root.
#
# Two of those three remedies belong to somebody else. root is not missing from
# the docker group — group membership is not consulted for uid 0 — and root
# cannot re-run anything as root. So the only remedy that can work is the first
# one, offered in the middle of two that cannot, to a reader whose daemon is
# down and who is reading this precisely because they do not know what to do.
#
# check-system.sh has always known the rule: "running as root — docker group
# membership not needed". Three messages never asked. Same rule as
# docker_start_hint, chat_address() and the 'lca' rows in the banner: do not
# hand the reader a command that cannot work where they are standing.
docker_unreachable_advice() {
  if am_root; then
    printf 'Start it: %s' "$(docker_start_hint)"
  else
    printf 'Start it (%s), or add yourself to the docker group (sudo %s/scripts/install_docker.sh) and log out/in, or re-run this as root' \
      "$(docker_start_hint)" "${REPO_ROOT}"
  fi
}

# ollama_log_hint — where to read the model engine's own output ON THIS HOST.
#
# Three messages sent people to 'journalctl -u ollama' unconditionally:
# check-system.sh and selftest.sh (both on "the model did not respond") and
# setup.sh (on the same failure during the install). Where there is no systemd
# there is no journal for ollama either — this project starts the server itself
# under nohup and writes OLLAMA_BG_LOG — so the one command offered at the
# moment inference fails returns nothing at all.
#
# scripts/logs.sh already makes exactly this decision and is the command the
# rest of the project points at, so the no-systemd arm names it rather than the
# raw path: it follows the file, and says where it would be when it is absent.
ollama_log_hint() {
  if systemd_available; then
    printf 'journalctl -u ollama'
  else
    printf '%s ollama' "${REPO_ROOT}/scripts/logs.sh"
  fi
}

# pull_advice MODEL — how to get MODEL onto this machine FROM HERE.
#
# Seven messages tell someone their model is missing. Three of them asked
# whether the kill switch was on first — check-system.sh, restore.sh and
# run-agent.sh each wrote the same two-arm branch by hand — and four did not:
# 'lca ask', 'lca speed', 'lca test' and prompt-bench.sh all said "pull it
# with: ollama pull X" flat out. With netmode OFFLINE that command cannot
# reach the registry, and the one thing standing between the reader and their
# model goes unmentioned.
#
# Being correct in three places is how the fourth is not, which is the same
# argument docker_daemon_reachable's header makes. All seven route through
# here now, so the gate on it can be blanket rather than an allow-list: lib.sh
# is the only file that may name the raw command, and the other occurrence
# here is pull_model actually running it.
# A whole sentence, not a fragment, so every caller can simply append it after
# a full stop. Returning just the command read fine online and badly offline —
# "Get it with: netmode is OFFLINE — run ..." — and a message that parses wrong
# is a message people skim past.
pull_advice() {
  if net_blocked; then
    printf "The netmode kill switch is ON, so nothing can download — run 'sudo %s/netmode.sh online', then: ollama pull %s" \
      "${REPO_ROOT}" "$1"
  else
    printf 'Pull it with: ollama pull %s' "$1"
  fi
}

# ollama_restart_hint — how to get the model engine running again ON THIS HOST.
#
# run-agent.sh and tune.sh both branch on systemd here already, and neither is
# folded into this helper on purpose: their arms differ in BEHAVIOUR, not just
# wording (tune.sh writes the tuned values to .env and exits 0 rather than
# dying). selftest.sh had no arm at all and offered 'sudo systemctl restart
# ollama' everywhere — on 'lca test', which is the command a new owner runs to
# find out whether any of this works.
ollama_restart_hint() {
  if systemd_available; then
    printf 'sudo systemctl restart ollama'
  else
    printf "start it yourself ('ollama serve') — there is no systemd here to manage it"
  fi
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
# What a .env line is allowed to be: blank, a comment, or one assignment whose
# value is bare (no whitespace) or fully quoted. 'export ' is accepted because
# people write it out of habit and source handles it; a trailing '# comment' is
# accepted because bash does.
#
# Held in a variable rather than inlined so the gate that proves it can feed it
# the same expression the loader uses, instead of a second copy that drifts.
#
# DELIBERATELY LOOSER than env_file_is_inert() below, and the two must not be
# merged. That one guards a .env that arrived inside a tarball named on the
# command line and is about to be sourced as root, so it rejects '$', backticks
# and every other construct outright. This one guards the file the user edited
# themselves, where 'FOO=$HOME/x' is their business and works today — applying
# the tarball rule here would refuse a config that has always been valid.
# Different threat, different answer; a gate asserts they still disagree.
LCA_ENV_LINE_RE='^[[:space:]]*(#|$)|^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'\''[^'\'']*'\''|[^[:space:]'\''"]*)[[:space:]]*(#.*)?$'

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ "${LCA_ENV_READONLY:-false}" == "true" ]]; then
      # Deliberately create nothing: see load_env_readonly below.
      :
    elif [[ -f "${ENV_EXAMPLE}" ]]; then
      # The copy can fail, and unguarded it failed the way every raw tool
      # failure does. setup.sh installs to /opt/local-code-agent as root, and
      # 'lca' is meant to be run as an ordinary user, so a missing .env there
      # gives:
      #
      #   cp: cannot create regular file '/opt/local-code-agent/.env':
      #   Permission denied
      #
      # ...and then the command aborts under errexit, mid-load_env, having said
      # nothing about what .env is for or what to do. Measured as the 'ubuntu'
      # user against a root-owned checkout.
      #
      # Not fatal: the branch below already treats a missing config as
      # "continue with built-in defaults", and every default is right there in
      # this function. So warn, name the cause and the fix, and carry on — the
      # only thing actually lost is that settings will not persist.
      if cp "${ENV_EXAMPLE}" "${ENV_FILE}" 2>/dev/null; then
        # Notice goes to stderr: load_env may run inside commands whose stdout
        # is data (a message on stdout would corrupt it).
        info "Created ${ENV_FILE} from .env.example (edit it to customize)." >&2
      else
        warn "Could not create ${ENV_FILE} — $(id -un) cannot write to ${REPO_ROOT}. Continuing with built-in defaults, but settings will not persist. To fix: sudo cp ${ENV_EXAMPLE} ${ENV_FILE} && sudo chown $(id -un) ${ENV_FILE}"
      fi
    else
      warn "Neither .env nor .env.example found in ${REPO_ROOT}; using built-in defaults."
    fi
  fi
  if [[ -f "${ENV_FILE}" ]]; then
    # Strip CR first so a CRLF (Windows-edited) .env never leaves a trailing
    # '\r' in values — which would break numeric checks, ports and URLs.
    local cleaned bad
    cleaned="$(tr -d '\r' < "${ENV_FILE}")"
    # Checked BEFORE sourcing, because every doc in this project tells the
    # reader to edit this file by hand — 'sed -i' on it appears in
    # YOUR-TURN.md, PHONE.md and the README — and sourcing a typo is the one
    # failure the reader cannot diagnose. Measured on two realistic slips:
    #
    #   WEBUI_PORT="3000               -> /dev/fd/63: line 60: unexpected EOF
    #                                     while looking for matching `"'
    #   MODEL_NAME=qwen2.5 coder:7b    -> /dev/fd/63: line 14: coder:7b:
    #                                     command not found
    #
    # ...and then no banner at all, on every SSH login. '/dev/fd/63' is the
    # process substitution below; it names nothing the reader can open, and
    # nothing anywhere says the word '.env'.
    #
    # 'bash -n' alone is not enough: the second line is valid bash. It parses
    # as an assignment followed by a command, which is exactly the damage. So
    # the rule is the real invariant of the file — assignments only.
    bad="$(grep -nvE "${LCA_ENV_LINE_RE}" <<<"${cleaned}" || true)"
    bad="${bad%%$'\n'*}"
    if [[ -n "${bad}" ]]; then
      die "${ENV_FILE} line ${bad%%:*}: ${bad#*:}
A .env holds KEY=value lines only, and this is not one — sourcing it would run part of the line as a command. Quote any value with spaces in it: KEY=\"a b\"."
    fi
    set -a
    # shellcheck disable=SC1090
    source <(printf '%s\n' "${cleaned}")
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
  AIDER_NO_AUTO_COMMIT="${AIDER_NO_AUTO_COMMIT:-false}"
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

# am_root — are we actually running as root?
#
# Its own function so the branch below can be reached from a test. as_root,
# can_root and can_root_now keep testing EUID inline on purpose: those decide
# an ACTION, where being root is a fact the process cannot be wrong about. This
# one decides what to PRINT about somebody else's account, and a reporter's
# branch that only one kind of machine can reach is a branch that gets tested
# on one kind of machine — the same reason writable_by_us and have_terminal
# exist a few hundred lines up.
am_root() { [[ "${EUID}" -eq 0 ]]; }

# invoking_user — the human this command is acting for.
#
# Under 'sudo lca X' that is SUDO_USER rather than root: they are the account
# that will own the files, run aider, need the docker group and SSH in.
#
# But SUDO_USER names whoever INVOKED sudo, which is not the account this
# process is running as when sudo dropped privileges rather than raised them.
# Measured, running check-system.sh under 'sudo -u ubuntu' — SUDO_USER=root,
# process running as ubuntu:
#
#   [warn] no global git identity for 'root' — ... Fix once:
#          git config --global user.name 'Ada Lovelace' && ...
#   [info] running as root — docker group membership not needed.
#
# Neither sentence is about the reader. The first names an account that is not
# the one whose config was read, and offers a fix that would set a third
# party's identity. The second SKIPS the group check entirely — so the one
# diagnostic that would explain an unreachable daemon is replaced by a claim
# that no check is needed, on an account that may well need it.
#
# So SUDO_USER only counts while we are actually root. Four scripts wrote
# '${SUDO_USER:-$(id -un)}' out by hand and all four had this; there is a gate
# below on writing it again.
#
# 'have sudo' as well: without it we cannot act as another account at all, so
# naming one would produce a label nothing can honour.
invoking_user() {
  if am_root && [[ -n "${SUDO_USER:-}" ]] && have sudo; then
    printf '%s\n' "${SUDO_USER}"
  else
    id -un
  fi
}

# git_identity_user — whose git config actually matters here. The same person
# invoking_user names; kept as its own name because git_identity below is paired
# with it and the two must be read together.
git_identity_user() { invoking_user; }

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
  # Escalate exactly when the account that matters is not the one we already
  # are. This used to be a second copy of git_identity_user's condition, and
  # the two disagreed: 'sudo -u ubuntu' put SUDO_USER=root in the label while
  # this branch, seeing EUID != 0, read ubuntu's config. Derived from 'who'
  # now, so a name and a value from different accounts is not expressible.
  if [[ "${who}" != "$(id -un)" ]]; then
    name="$(sudo -u "${who}" git config --global user.name 2>/dev/null || true)"
    email="$(sudo -u "${who}" git config --global user.email 2>/dev/null || true)"
  else
    name="$(git config --global user.name 2>/dev/null || true)"
    email="$(git config --global user.email 2>/dev/null || true)"
  fi
  [[ -n "${name}" && -n "${email}" ]] || return 1
  printf '%s <%s>\n' "${name}" "${email}"
}

# commit_safety_state — whether an aider run started in THIS directory will
# leave anything you can inspect or undo. Echoes one word:
#
#   repo    inside a git work tree — every edit becomes its own commit, so
#           'git diff HEAD~1' shows it and 'git revert <sha>' takes it back
#   home    $HOME, and not a repo — aider does NOT offer to create one here
#   norepo  anywhere else without a repo — aider offers to create one, yes
#
# The 'home' case is the point of this function, and it is measured from
# aider's own source rather than assumed: in main.py, a cwd equal to the home
# directory prints "You should probably run aider in your project's directory,
# not your home dir." and RETURNS — no prompt, no repo. Everywhere else it
# asks "No git repo found, create one to track aider's changes (recommended)?"
#
# That exception lands on the likeliest directory there is. SSH puts you in
# $HOME, 'lca help' describes the bare command as "start the coding agent
# here", and the login banner now tells people to write code. So typing the
# headline command the first time, in the directory you were already standing
# in, is the one path where auto-commit — this project's entire answer to a
# small model deleting a function nobody mentioned — silently does not exist.
# aider says so in one line among ten lines of startup output.
#
# -ef, not string equality: it compares device and inode, so a symlinked or
# non-canonical $HOME still matches instead of quietly missing the case.
commit_safety_state() {
  # The VALUE, not just the exit status: inside a bare .git directory
  # 'rev-parse --is-inside-work-tree' prints false and still exits 0.
  if have git && [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]]; then
    printf 'repo\n'; return 0
  fi
  if [[ -n "${HOME:-}" && "${PWD}" -ef "${HOME}" ]]; then
    printf 'home\n'; return 0
  fi
  printf 'norepo\n'
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
  # Permission before disk space, because sed has usually just said so.
  #
  # 'a full disk is the usual cause' was the only explanation offered, and it
  # is the wrong one for anybody using a checkout they do not own — which is
  # every ordinary user of a stack installed with 'sudo setup.sh'. Measured as
  # such a user, running what 'lca tune' and 'lca model' both call:
  #
  #   sed: couldn't open temporary file /home/user/local-code-agent/sedlOoIFn:
  #        Permission denied
  #   [FAIL] Could not write MODEL_NAME to .../.env (sed exited 4) — a full
  #          disk is the usual cause, so check 'df -h' ... re-run once there is
  #          room.
  #
  # There was room. There always was. Freeing disk space would change nothing,
  # and 'sed exited 4' is not something a reader can act on.
  #
  # The DIRECTORY is checked as well as the file, and that is what the error
  # actually names: 'sed -i' writes its temp file next to the target, so a
  # writable .env inside an unwritable directory fails the same way.
  # The file is only consulted when it EXISTS. '[[ -w ]]' is false for a path
  # that is not there, which is not the same as "you may not write it" — and
  # the gate below drives a real failure through an ENV_FILE whose parent is a
  # regular file, so the target cannot exist. Testing it unconditionally
  # classified that as a permission problem, which it is not.
  local env_dir
  env_dir="$(dirname "${ENV_FILE}")"
  if ! writable_by_us "${env_dir}" \
     || { [[ -e "${ENV_FILE}" ]] && ! writable_by_us "${ENV_FILE}"; }; then
    die "Could not write ${1} to ${ENV_FILE}: '$(id -un)' cannot write there. A checkout installed with 'sudo setup.sh' is owned by root, so this needs the same. Nothing was changed — re-run the command with sudo.${3:+ $3}"
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

# retention_desc — how to describe BACKUP_KEEP to a human.
#
# The two early returns above are the whole reason this exists. BACKUP_KEEP=0
# means "keep everything" and a non-number means "retention never runs", so
# printing the raw value produces:
#
#   BACKUP_KEEP=0     keeping the newest 0
#   BACKUP_KEEP=abc   keeping the newest abc
#
# The first is not merely unclear, it is backwards and alarming: it reads as
# "every backup will be deleted" at the exact moment somebody is switching
# scheduled backups ON, when the truth is that none of them ever will be. The
# second is not a sentence.
#
# check-system.sh worked this out and carries a comment saying precisely that
# — "BACKUP_KEEP=0 means 'keep everything', not 'keep newest 0'". backup.sh's
# own --install-timer line, which is the one printed while setting retention
# up, never asked. Same shape as docker_start_hint and pull_advice: the rule
# existed, in one place, and the other caller did not know about it.
retention_desc() {
  local keep="${BACKUP_KEEP:-7}"
  if ! [[ "${keep}" =~ ^[0-9]+$ ]]; then
    printf "retention disabled (BACKUP_KEEP='%s' is not a number)" "${keep}"
  elif [[ "${keep}" == "0" ]]; then
    printf 'retention disabled (keeping all)'
  else
    printf 'keeping newest %s' "${keep}"
  fi
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

# input_file_ok PATH OPTION [EXTRA] — die with the right sentence for a file a
# command was told to read, naming the option that took it.
#
# Three states, not one. '[[ -r ]]' is true for a DIRECTORY, so pointing an
# option at one — 'lca ask -f src/ "explain this"', which is the obvious thing
# to try — passed a single guard and then failed inside the reader with its own
# words. Measured, in two different commands:
#
#   head: error reading '/home/you/src': Is a directory
#   cat: /etc: Is a directory
#
# which reads as an I/O or permission fault and says nothing about what to do
# instead. ask.sh had all three states and prompt-bench.sh had the bare -r, so
# they lived here rather than in either.
#
# The -e arm is not redundant with the third: without it a name that does not
# exist comes back as "owned by another account and this account cannot open
# it", which is a confident answer to a question nobody asked.
input_file_ok() {
  local f="$1" opt="$2" extra="${3:-}"
  [[ -e "${f}" ]] || die "No such file: ${f}"
  [[ ! -d "${f}" ]] || die "${f} is a directory, and ${opt} takes a file.${extra:+ ${extra}}"
  readable_by_us "${f}" \
    || die "Cannot read ${f} — it is owned by $(stat -c %U "${f}" 2>/dev/null || echo 'another account') and this account cannot open it. Re-run with sudo, or copy it somewhere you can read."
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

# model_fits_ram TAG RAM_GIB — rough q4 sizing: ~0.6 GB per billion parameters
# plus ~1 GB for context and overhead. Deliberately approximate; its only job is
# to stop something being selected that cannot possibly load. An unparseable tag
# returns true, so an unusual naming scheme is never blocked.
#
# Moved here from tune.sh, unchanged. It belongs beside model_disk_gb — same
# 0.6 GB per billion — and update-model.sh's manual-pin path needs it without
# sourcing tune.sh, which would redefine main() out from under its caller. Its
# own tag parse rather than model_params_b's: this one also accepts a tag with
# no trailing 'b' and keeps fractions (1.5b stays 1.5), and the tune ladder is
# tested against exactly that behaviour.
#
# The 0.6 is not a guess any more. Measured on this project's own box, with
# qwen2.5-coder:7b loaded at ctx 8192:
#
#   $ ps -eo rss,comm --sort=-rss | head -2
#      4986.5 MB  llama-server
#
# 4.87 GiB actual against 5.2 predicted — right, and conservative in the safe
# direction, which is what a guard wants.
model_fits_ram() {
  local need
  need="$(model_ram_gb "$1")" || return 0
  awk -v n="${need}" -v r="$2" 'BEGIN{ exit !(n <= r) }'
}

# model_ram_gb TAG — how much RAM model_fits_ram requires for TAG, or nothing
# (exit 1) for a tag whose size cannot be read.
#
# Split out of model_fits_ram so the guard and the sentence explaining it
# cannot disagree. A warning that says "needs about N GB" while the check
# behind it uses a different N is worse than printing no number at all, and
# update-model.sh was carrying the formula a second time, in prose:
#
#   "roughly 0.6 GB per billion parameters, plus about 1 GB"
#
# %.10g rather than a fixed number of decimals: every model tag this project
# can parse has at most one decimal place, so the value is exact either way,
# and this one also prints 2.8 rather than 2.80.
model_ram_gb() {
  local tag="${1##*:}" params
  params="${tag%[bB]}"
  [[ "${params}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v p="${params}" 'BEGIN { printf "%.10g\n", p * 0.6 + 1 }'
}

# tune_cost_note NEW_MODEL FREE_GB HEADROOM_GB MODELS_DIR OLD_MODEL — what
# applying the auto-tune recommendation would cost in disk, or nothing at all
# when the disk can take it comfortably.
#
# 'lca check' recommended a 9 GB download and, eleven lines later, FAILED the
# machine for having less disk than it wants. Measured on this project's own
# box, at 14 GB free:
#
#   [warn] configured model (qwen2.5-coder:7b) differs from the recommendation
#          (qwen2.5-coder:14b) — run .../scripts/tune.sh
#   [FAIL] only 14 GB free at /root/.ollama/models — models need headroom
#
# Following the report's own advice deepens the failure the same report makes,
# and tune.sh keeps the old model as a rollback, so nothing is reclaimed on the
# way either. That is the same contradiction 'lca model --list-recommended'
# carried for RAM and then for disk: a question answered in one place and
# ignored in another.
#
# Two arms, because they are two different facts — pull_model would refuse the
# download outright, or it would go through and leave the machine short. Here
# rather than inline in check-system.sh so the sentence and the numbers it
# quotes (model_disk_gb and free_gb, the ones pull_model and the disk check
# actually use) cannot drift apart, and so it can be tested without driving the
# whole health check.
#
# Nothing when the size cannot be read or the free space is unknown: an
# unparseable tag must not become a warning any more than it may become a
# refusal.
tune_cost_note() {
  local new="$1" free="$2" headroom="$3" dir="$4" old="$5" need
  need="$(model_disk_gb "${new}")" || return 0
  [[ -n "${free}" ]] || return 0
  if (( free < need )); then
    printf ' — but it needs about %s GB and only %s GB is free at %s, so the download would be refused; free some space first' \
      "${need}" "${free}" "${dir}"
  elif (( free - need < headroom )); then
    printf " — note that it downloads about %s GB and would leave about %s GB free at %s, under the %s GB this check wants (the old model is kept as a rollback; 'ollama rm %s' reclaims it)" \
      "${need}" "$(( free - need ))" "${dir}" "${headroom}" "${old}"
  fi
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

# MODEL_PROBE_TIMEOUT — how long a real generation is allowed to take before
# we stop calling it a generation.
#
# It was 300s by default and 240s in 'lca check', and both were guesses. The
# first request after a restart does not just generate: it loads the whole
# model into RAM first. Measured from this project's own CPU-only VPS, every
# model load its Ollama log holds — "loading model via llama-server" to
# "loaded runners":
#
#   298.6s   77.6s   39.6s   34.8s   26.0s   30.3s   64.8s
#
# The 298.6s one is not an outlier to be waved away, it is the ordinary case
# this project is built for: the box had just rebooted and Ollama was loading
# a 7b model on the same cores Open WebUI was using to load its embedding
# model. 'lca check' allowed 240s for load AND generation, so on a freshly
# rebooted box — the exact moment somebody runs it — the one command that
# exists to diagnose this stack reported the model broken.
MODEL_PROBE_TIMEOUT="${MODEL_PROBE_TIMEOUT:-600}"

# Set by model_responds so its callers can say WHY without probing twice:
# ok | timeout | refused, and the deadline that applied.
MODEL_PROBE_OUTCOME=""
MODEL_PROBE_SECONDS=""
# Ollama's own words for the last failed probe, when it gave any.
MODEL_PROBE_ERROR=""

# model_responds MODEL [TIMEOUT] — prove MODEL can actually generate text by
# asking the running Ollama server for a tiny real completion.
model_responds() {
  local model="$1" timeout="${2:-${MODEL_PROBE_TIMEOUT}}"
  local url payload raw rc=0 response
  MODEL_PROBE_OUTCOME="refused"
  MODEL_PROBE_SECONDS="${timeout}"
  MODEL_PROBE_ERROR=""
  url="$(ollama_url)"
  payload="$(jq -n --arg model "${model}" \
    '{model: $model, prompt: "Reply with the single word: ready", stream: false, options: {num_predict: 16}}')"
  # Not piped into jq: a pipeline's exit status is the LAST command's, and
  # curl's is the whole point here — 28 is its documented "operation timed
  # out", which is the difference between "still loading" and "said no".
  #
  # No -f, and that is the fix. With it, curl treats any non-2xx as a failure,
  # exits 22 and THROWS THE BODY AWAY — and the body is where Ollama puts its
  # reason. Measured against a running server:
  #
  #   curl -sS  ... -d '{"model":"no-such-model:1b",...}'
  #     -> {"error":"model 'no-such-model:1b' not found"}
  #   curl -fsS ... (the same request)
  #     -> rc=22, body empty
  #
  # It mattered most in the case this project is actually on a box for. Ollama
  # gives up loading a model after about five minutes and answers 500;
  # MODEL_PROBE_TIMEOUT is 600, deliberately longer. So on a slow cold load
  # Ollama ALWAYS replies before curl times out, rc is never 28, and the
  # outcome is "refused" — which made model_silence_reason say "the server
  # answered rather than running out of time, so this is not a slow load"
  # about a load that had run out of time. Measured on this box, from its own
  # log:
  #
  #   Load failed ... error="timed out waiting for llama-server to start - "
  #   [GIN] 500 | 5m1s | POST "/api/generate"
  #
  # Same fix ask.sh already carries for the streaming path, which tees the raw
  # body so Ollama's error survives.
  raw="$(curl -sS --max-time "${timeout}" -X POST "${url}/api/generate" \
    -H 'Content-Type: application/json' -d "${payload}" 2>/dev/null)" || rc=$?
  if (( rc == 28 )); then
    MODEL_PROBE_OUTCOME="timeout"
    return 1
  fi
  (( rc == 0 )) || return 1
  response="$(jq -r '.response // empty' <<<"${raw}" 2>/dev/null || true)"
  if [[ -n "${response}" ]]; then
    MODEL_PROBE_OUTCOME="ok"
    return 0
  fi
  # Kept for the caller to quote. Empty when the answer was not JSON or had no
  # error in it, which is a different thing from Ollama being silent and must
  # not be presented as a reason.
  MODEL_PROBE_ERROR="$(jq -r '.error // empty' <<<"${raw}" 2>/dev/null || true)"
  return 1
}

# ollama_error_is_slow_load ERROR — true when what Ollama reported is its own
# model load running out of time, rather than something wrong with the install.
#
# Narrow on purpose. "llama runner process has terminated" is the other common
# error on this kind of box and it is usually the load being killed for memory:
# running it again just kills it again, so it must not collect the advice below.
ollama_error_is_slow_load() {
  [[ "${1:-}" == *"timed out waiting for llama-server to start"* ]]
}

# model_silence_reason — why the last model_responds did not answer.
#
# Five messages named RAM, and four of them named it FIRST:
#
#   check-system.sh  "did not respond (RAM? see: free -h ...)"
#   selftest.sh      "did not respond — check RAM headroom (free -h) ..."
#   setup.sh         "did not respond. Check RAM headroom (free -h) ..."
#   update-model.sh  "Does this machine have enough RAM for it?"
#   tune.sh          "Check RAM headroom with: free -h"
#
# On the box those numbers above were measured on, RAM was never the cause
# once — a cold load on busy cores was. update-model.sh's is the plainest:
# it runs model_fits_ram BEFORE downloading and would have refused or warned
# already, so by the time it asks, it has its own answer and is ignoring it.
#
# RAM is still worth naming, because a model too big for the box does fail
# here. It belongs after the cause that measurement actually produced, not
# instead of it.
model_silence_reason() {
  if [[ "${MODEL_PROBE_OUTCOME}" == "timeout" ]]; then
    printf 'it was still not answering after %ss. The first request after a restart has to load the whole model into RAM before it can generate anything, and on this kind of CPU-only box that has been measured at anywhere from 26s to 5 minutes depending on what else is using the cores — so this may be a load that simply had not finished. %s shows "loading model" while it is working and "loaded runners" when it is done. If it never gets there, then check RAM: free -h.' \
      "${MODEL_PROBE_SECONDS}" "$(ollama_log_hint)"
  elif [[ -n "${MODEL_PROBE_ERROR}" ]]; then
    # Ollama said why. Quote it instead of reasoning about it: the sentence
    # below used to be printed here too, and it ruled out the commonest cause
    # on this kind of box ("this is not a slow load") in exactly the case where
    # that cause was what Ollama had just reported.
    if ollama_error_is_slow_load "${MODEL_PROBE_ERROR}"; then
      # The one thing that fixes this, and the message did not say it. Measured
      # on a cold box, the same command twice in a row: the first request gave
      # up after 304s with nothing resident, the second answered in 32s. The
      # failed attempt is not wasted — it leaves the model file in the page
      # cache, so the second load reads it from memory instead of from disk.
      # Without this the reader is told the model "produced no answer" and left
      # to conclude the install is broken, one keystroke away from working.
      printf "Ollama's own answer was: %s. That is its load giving up before it finished, not a broken install — run the same command again. The first attempt leaves the model file in the page cache, so the second load reads it from memory: measured cold on this project's own box, 304s to fail and then 32s to answer. If it keeps timing out, check RAM (free -h) and the full log: %s." \
        "${MODEL_PROBE_ERROR}" "$(ollama_log_hint)"
    else
      printf "Ollama's own answer was: %s. %s has the full log." \
        "${MODEL_PROBE_ERROR}" "$(ollama_log_hint)"
    fi
  else
    printf 'the server answered, without an answer and without saying why — it returned nothing at all. Its own reason may be in the log: %s' \
      "$(ollama_log_hint)"
  fi
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

# placement_summary PLACEMENT — one honest clause about where the model ran,
# for a reporter that wants to state it rather than grade it.
#
# gpu_state_for_placement's comment says "both reporters used to read that
# string themselves". There were three. selftest.sh printed it raw:
#
#   $ lca test
#   [info] Running on: 20%/80% CPU/GPU
#   $ lca check
#   [info] no NVIDIA GPU — CPU inference (a reading pace)
#
# on the same box, minutes apart — 'lca test' telling the reader four fifths of
# their model was on a card this machine does not have. Ollama 0.32.5 prints
# that split on a CPU-only host for memory it manages itself, which is why
# reading the string's shape can never answer the question.
#
# The sentence lives here so the reporters cannot drift again: check-system.sh
# had worked it out and was the only one who had.
placement_summary() {
  local placement="${1:-}"
  [[ -n "${placement}" ]] \
    || { printf 'is not loaded right now — run a query, then re-check to see CPU/GPU placement'; return 0; }
  case "$(gpu_state_for_placement "${placement}")" in
    active) printf 'is running on the GPU (%s)' "${placement}" ;;
    split)  printf 'is only partly on the GPU (%s) — a split runs at close to CPU speed' "${placement}" ;;
    idle)   printf 'is running on the CPU (%s) even though a GPU driver is present' "${placement}" ;;
    *)
      # none | no-driver | unknown. A slash here is Ollama's own bookkeeping,
      # not a device: say so rather than quote it as a fact about hardware.
      if [[ "${placement}" == */* ]]; then
        printf "placement reads '%s', but there is no usable NVIDIA GPU here — this is CPU inference. Ollama reports a split for memory it manages itself; there is no card on this machine to size a model against." "${placement}"
      else
        printf 'is running on the CPU (%s)' "${placement}"
      fi
      ;;
  esac
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

# read_probe_prompt — a prompt for measuring how fast this machine READS input,
# which has to be two things the old benchmark was not: big, and different
# every time.
#
# Different every time, because Ollama caches the KV prefix of a prompt it has
# already seen. The benchmark prompt is a fixed 43-token string, so the second
# and every later 'lca speed' re-read it out of that cache. Measured on this
# box, the same 2,050-token prompt twice in a row:
#
#   {"prompt_eval_count":2050, "seconds":104, "read_tps":19}
#   {"prompt_eval_count":2050, "seconds":0,   "read_tps":6899}
#
# Big, because at 43 tokens the per-request overhead dominates whatever is
# left. Between them the two faults reported 160-213 tokens/second on a machine
# that really reads at 20 — an order of magnitude, on the one number that
# explains why a code edit takes minutes.
#
# The nonce goes FIRST so the differing bytes are at the head of the prefix;
# a nonce at the end would leave everything before it cacheable.
read_probe_prompt() {
  local i filler="the quick brown fox jumps over the lazy dog while counting widgets "
  printf 'Session %s-%s-%s. Ignore the notes below and reply with one word: ok.\n' \
    "$(date +%s%N 2>/dev/null || printf 0)" "$$" "${RANDOM}"
  for (( i = 0; i < 45; i++ )); do printf '%s' "${filler}"; done
  printf '\n'
}

# What one small aider edit costs, in tokens. Measured on this project's own
# defaults: adding a two-line function to a two-line file sent 2,800 tokens and
# got 113 back. The prompt is not the file — it is aider's system prompt, the
# repo map (768 tokens by default), the read-only conventions file (253,
# measured) and the chat history. A tiny file still carries all of it.
LCA_EDIT_PROMPT_TOKENS=2800
LCA_EDIT_REPLY_TOKENS=113

# aider_edit_seconds READ_TPS GEN_TPS — how long that edit takes at two
# measured rates. Echoes whole seconds; non-zero if either rate is unusable.
#
# 'Generation N tokens/second' is the number this project quoted everywhere and
# the one every local-LLM discussion quotes, and for the coding agent it is the
# smaller half. At the rates measured here — 20 reading, 4.8 generating — that
# edit is 140 seconds of reading against 23 of writing. Someone asking why it
# is slow was being answered about the 14%.
aider_edit_seconds() {
  awk -v r="${1:-0}" -v g="${2:-0}" -v ti="${LCA_EDIT_PROMPT_TOKENS}" -v to="${LCA_EDIT_REPLY_TOKENS}" \
    'BEGIN { if (r <= 0 || g <= 0) exit 1; printf "%d\n", (ti / r) + (to / g) }'
}

# human_duration SECONDS — "45s" / "3 min" / "1 h 5 min". Minutes past 90
# seconds, because "187 seconds" is a number you have to convert before you can
# feel it, and feeling it is the whole purpose of printing it.
human_duration() {
  local s="${1:-0}"
  [[ "${s}" =~ ^[0-9]+$ ]] || return 1
  if (( s < 90 )); then printf '%ss\n' "${s}"
  elif (( s < 3600 )); then printf '%s min\n' "$(( (s + 30) / 60 ))"
  else printf '%s h %s min\n' "$(( s / 3600 ))" "$(( (s % 3600 + 30) / 60 ))"
  fi
}

# ollama_extra_env — the KEY=VALUE settings config/ollama.env adds, one per
# line, or nothing when the file is absent.
#
# One reader, because there were two and they disagreed. The systemd drop-in
# took every line of that file; start_ollama_bg hand-copied
# OLLAMA_MAX_LOADED_MODELS=1 and did not copy OLLAMA_NO_CLOUD=1 — the setting
# whose own comment says it exists because "Ollama ships with its cloud
# features ON: remote inference and web search, which contact ollama.com", and
# that leaving them enabled "contradicted the first line of the README".
#
# Measured on this project's own systemd-less box, reading the running
# server's /proc/PID/environ:
#
#   OLLAMA_CONTEXT_LENGTH=8192
#   OLLAMA_HOST=127.0.0.1:11434
#   OLLAMA_KEEP_ALIVE=30m
#   OLLAMA_MAX_LOADED_MODELS=1
#
# Four settings, and the privacy one absent. start_ollama_bg's own comment
# said it starts Ollama "with the same environment the systemd drop-in would
# apply", which is exactly the promise a second hand-written copy breaks.
ollama_extra_env() {
  local extra_env="${REPO_ROOT}/config/ollama.env"
  [[ -f "${extra_env}" ]] || return 0
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${extra_env}" || true
}

# render_ollama_dropin_content — print the drop-in the current .env implies,
# to stdout (no writes). Kept separate so callers can diff it against the
# installed file to detect drift.
render_ollama_dropin_content() {
  echo "# Managed by local-code-agent (scripts/install_ollama.sh and scripts/tune.sh)."
  echo "# Manual edits will be overwritten on the next install or tune run."
  echo "[Service]"
  echo "Environment=OLLAMA_HOST=${OLLAMA_HOST}"
  echo "Environment=OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
  echo "Environment=OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
  ollama_extra_env | sed 's/^/Environment=/'
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
  # Explicit for the same reason as restart_ollama below: apply.sh calls this
  # inside a condition, where errexit does not fire. Bare, a failed mkdir let
  # execution reach the write, which then failed for the obvious reason and
  # blamed a full disk — the one cause it could be sure it was not.
  as_root mkdir -p "${OLLAMA_DROPIN_DIR}" \
    || die "Could not create ${OLLAMA_DROPIN_DIR}, so there is nowhere to write the Ollama settings. ${OLLAMA_DROPIN} is unchanged."
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
  local logf="${OLLAMA_BG_LOG}"
  warn "systemd not available — starting 'ollama serve' in the background (NOT persistent across reboots; use a systemd host for a managed service)."
  # config/ollama.env through the same reader the drop-in uses, rather than a
  # hand-picked copy of some of it — see ollama_extra_env for what that cost.
  local extra=() line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && extra+=( "${line}" )
  done < <(ollama_extra_env)
  nohup env \
    OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}" \
    OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}" \
    OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}" \
    ${extra[@]+"${extra[@]}"} \
    ollama serve >"${logf}" 2>&1 &
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

# ollama_bg_env KEY — the value KEY had when the background 'ollama serve' was
# started. Nothing (exit 1) when it cannot be read.
#
# On a host with no systemd this project starts the server itself, passing
# OLLAMA_CONTEXT_LENGTH and OLLAMA_KEEP_ALIVE from .env AT LAUNCH. Editing .env
# afterwards changes nothing until it restarts, and until now nothing could say
# whether that had happened: 'lca apply' reported "could not be looked at" on
# every run of every such host, which is honest and permanently unhelpful.
#
# /proc/PID/environ is the launch environment, which is exactly the question.
# Measured here, server started by start_ollama_bg:
#
#   OLLAMA_HOST=127.0.0.1:11434
#   OLLAMA_CONTEXT_LENGTH=8192
#   OLLAMA_KEEP_ALIVE=30m
#
# NOT 'ollama ps'. Its CONTEXT column looks like the answer and is not — two
# calls a minute apart on an idle box read 11677 and then 11873, because newer
# Ollama sizes the working context dynamically. Reporting drift from that would
# have produced a config warning that came and went on its own.
#
# No pipes: this suite bans 'producer | reader-that-exits-early' outright, and
# an environ block is small enough that it would have worked by luck.
ollama_bg_env() {
  local key="$1" pids pid environ val
  have pgrep || return 1
  pids="$(pgrep -f 'ollama serve' 2>/dev/null || true)"
  [[ -n "${pids}" ]] || return 1
  read -r pid <<<"${pids}"
  [[ -n "${pid}" && -r "/proc/${pid}/environ" ]] || return 1
  environ="$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null || true)"
  val="$(sed -n "s/^${key}=//p" <<<"${environ}")"
  read -r val <<<"${val}"
  [[ -n "${val}" ]] || return 1
  printf '%s' "${val}"
}

# restart_ollama — reload systemd and restart the ollama service, then wait
# for the API to come back. Warns (does not crash) where systemd is absent.
restart_ollama() {
  if systemd_available; then
    # Explicit, not bare under errexit. This function is called by apply.sh as
    #
    #   if ! ( render_ollama_dropin && restart_ollama ); then
    #
    # — a subshell, deliberately, because both of them die() and an exit is not
    # a non-zero return. But a command inside a condition does not trigger
    # errexit, so every bare line in here stopped aborting the moment that
    # caller was written. Measured:
    #
    #   f() { false; echo REACHED; return 0; }
    #   f                          -> aborts, exit 1
    #   if ! ( f ); then ... fi    -> REACHED, and reports SUCCESS
    #
    # The consequence is specific: daemon-reload is what makes systemd re-read
    # the drop-in we just rendered. If it fails and the restart succeeds, the
    # service comes back on its OLD configuration, wait_for_ollama is satisfied,
    # 'is-active' is satisfied, and this printed "Ollama restarted and
    # answering" — with 'lca apply' reporting the new context and keep-alive
    # applied. Success for the one piece of work the command exists to do.
    as_root systemctl daemon-reload \
      || die "'systemctl daemon-reload' failed, so systemd is still holding the previous unit definition and a restart now would come back on the OLD settings. Nothing was restarted and ${OLLAMA_DROPIN} is already written; re-run once systemd is answering."
    as_root systemctl restart ollama \
      || die "Could not restart the ollama service, so the settings in ${OLLAMA_DROPIN} are not in effect yet. Inspect it with: sudo systemctl status ollama"
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

# lca_webui_banners — the always-visible notice at the top of every chat, as the
# JSON list Open WebUI's WEBUI_BANNERS expects.
#
# The system prompt above already tells the model it has no filesystem, and it
# is good at saying so — but it is an INSTRUCTION to a 3b, obeyed most of the
# time rather than always. The one time it is not obeyed, the user is handed a
# confident multi-file tutorial, concludes the product cannot code, and stops.
# That is not a hypothetical: it is the first thing a real user reported.
#
# A banner is not an instruction. It is served by Open WebUI itself, from
# /api/v1/configs/banners, and rendered above the conversation whatever the
# model does or does not say. Verified against the real image
# by starting a container from WEBUI_IMAGE with it set and reading it back from
# note it does NOT appear under 'ui.banners' in /api/config, which is where you
# would look first and find null.
#
# dismissible:false on purpose. The limitation does not go away, and a
# dismissed banner is exactly what someone would not see on the day they ask it
# to build something.
lca_webui_banners() {
  local content
  content="This chat cannot read, create or edit files — it is a chat box with no filesystem. For real coding, SSH into the server and run:  lca [project-dir]   (that is aider, on this same private model, and it does write files.)"
  jq -nc --arg c "${content}" \
    '[{id: "lca-no-filesystem", type: "warning",
       title: "This chat cannot touch your files",
       content: $c, dismissible: false, timestamp: 1}]'
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

# WEBUI_START_TIMEOUT — how long a chat-app start is allowed to take before we
# stop calling it a start.
#
# It was 120s for 'webui.sh start' and 'restart' and 180s for the installer,
# and all three numbers were guesses. Measured instead, from the container's
# own log on this box — every real boot it has had, container start to "Started
# server process":
#
#   2026-08-06 02:09:52 -> 02:10:21     29s
#   2026-08-06 10:13:20 -> 10:17:50   4m30s
#   2026-08-06 14:48:54 -> 14:50:51   1m57s
#   2026-08-06 16:22:52 -> 16:23:08     16s
#   2026-08-07 02:15:48 -> 02:22:43   6m55s
#
# Three of five were at or past 120s, and two were past 180s. Open WebUI loads
# a SentenceTransformer embedding model before it serves, and on a CPU-only
# box sharing its cores with Ollama that is minutes, not seconds. So on this
# hardware the common case — the VPS reboots, both services come up together,
# the owner logs in and follows the banner's advice — ended in:
#
#   [FAIL] Container started but no HTTP answer after 120s
#
# about a container that was working perfectly and answered four minutes
# later. The installer's "first start can take ~1 minute" was wrong by 7x.
#
# 600s is the measured worst case with headroom. That is only safe because the
# wait below now watches the container as well as the port: a start that has
# actually failed is reported in seconds, not at the end of the clock.
WEBUI_START_TIMEOUT="${WEBUI_START_TIMEOUT:-600}"

# wait_for_webui [TIMEOUT_SECONDS] — poll Open WebUI's /health until it
# answers. A cold container start takes noticeably longer than 'docker
# start' returning, so start/restart/install all wait through this.
#
#   0  it answered
#   1  the deadline passed and the container is STILL RUNNING — slow or stuck
#   2  the container is no longer running, so waiting cannot help
#
# The two failures are different problems with different fixes, and a caller
# that cannot tell them apart has to hedge. Checked every 30s rather than
# every poll: 'docker inspect' is far more expensive than a loopback curl, and
# a container that dies is not in a hurry.
#
# The progress line matters as much as the timeout. A silent wait through
# seven minutes is indistinguishable from a hang, and the honest reading of
# that silence — "this is broken, Ctrl-C it" — is exactly wrong.
wait_for_webui() {
  local timeout="${1:-${WEBUI_START_TIMEOUT}}" waited=0
  while ! webui_responds; do
    if (( waited >= timeout )); then
      return 1
    fi
    sleep 3
    waited=$((waited+3))
    (( waited % 30 == 0 )) || continue
    webui_container_running || return 2
    if (( waited == 30 )); then
      info "Still starting. Open WebUI loads an embedding model before it answers anything; on a CPU-only box that has taken up to 7 minutes here." >&2
    else
      info "  ...still starting (${waited}s, up to ${timeout}s)." >&2
    fi
  done
  return 0
}

# webui_wait_or_die TIMEOUT LOGS_HINT — wait for the chat app, or die naming
# the reason the wait actually had. Shared by every caller so the distinction
# wait_for_webui draws is never flattened back into one message.
webui_wait_or_die() {
  local timeout="$1" logs="$2" rc=0
  wait_for_webui "${timeout}" || rc=$?
  case "${rc}" in
    0) return 0 ;;
    2) die "The container stopped while we waited for it, so this is not a slow start — something inside it failed. Its log says what: ${logs}" ;;
    *) die "Open WebUI still was not answering after ${timeout}s, and its container is still running. That is either a start slower than anything measured here or one that is stuck; the log tells them apart: ${logs}" ;;
  esac
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

# webui_container_running — true when the chat app's container is not merely
# present but actually running, i.e. actually listening on something.
#
# webui_container_exists deliberately answers "in any state", which is right
# for "has it been created". It is the wrong question for exposure: a stopped
# container accepts no connections, and reporting its port as an unguarded gap
# would be a finding nothing can clear — 'lca webui stop' does not remove the
# container, so the port stays in its Config.Env for ever.
webui_container_running() {
  have docker || return 1
  local state
  state="$(docker container inspect -f '{{.State.Running}}' "${WEBUI_CONTAINER}" 2>/dev/null \
           || { root_for_probe && as_root docker container inspect -f '{{.State.Running}}' "${WEBUI_CONTAINER}" 2>/dev/null; } \
           || true)"
  [[ "${state}" == "true" ]]
}

# webui_volume_has_data — true when the chat app's volume exists AND has
# something in it, i.e. there is something in there to lose.
#
# A third answer, for the same reason webui_container_exists is distinct from
# webui_drift: "no volume", "an empty volume" and "a volume holding every
# account and chat" are three different states, and restore.sh is about to
# 'rm -rf' whichever one it finds.
#
# A volume can only be read from inside a container, so this needs the image.
# Every way of failing — no docker, no daemon, image missing, run refused —
# answers "no data", on purpose: the only caller uses this to decide whether to
# ASK, and a question nobody can answer is worse than no question. Nothing is
# decided by it that could lose data on its own; the destructive step validates
# the archive before it clears anything either way.
webui_volume_has_data() {
  have docker || return 1
  as_root docker volume inspect open-webui >/dev/null 2>&1 || return 1
  local listing
  listing="$(as_root docker run --rm --entrypoint sh -v open-webui:/v:ro \
               "${WEBUI_IMAGE}" -c 'ls -A /v' 2>/dev/null || true)"
  [[ -n "${listing}" ]]
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
    # The banner is baked in at creation like everything else here, so an
    # install that predates it keeps a container with no banner at all and
    # nothing would say so. That is the state the first real user was in.
    want="$(lca_webui_banners 2>/dev/null || true)"
    live="$(webui_container_env WEBUI_BANNERS || true)"
    [[ -z "${want}" || "${live}" == "${want}" ]] || drifted+=("WEBUI_BANNERS")
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
  #
  # Deduplicated against what is ALREADY in the list, not against WEBUI_PORT,
  # and that distinction is the whole of a security hole. With
  # ENABLE_WEBUI=false the first branch above adds nothing, so 'live == WEBUI_PORT'
  # suppressed the only entry there was — and a chat app that .env says is off
  # but that is still running went unlisted. Measured on this box with
  # ENABLE_WEBUI=false, the container untouched and answering:
  #
  #   guarded_ports:  Ollama 11434                 (3000 simply absent)
  #   curl 127.0.0.1:3000/health -> {"status":true}
  #   lca apply --dry-run: "apply the inbound guard ... to Ollama 11434"
  #   lca check:           "no public service ports to guard"
  #
  # Turning a feature OFF in .env made the box more exposed, not less: before
  # the edit port 3000 was in the guard, after it the two commands that decide
  # what the guard covers both said there was nothing there. netmode.sh's own
  # renderer never agreed — it guards WEBUI_PORT regardless of ENABLE_WEBUI —
  # so this was three answers to one question, and the two that drive 'lca
  # check' and 'lca apply' were the wrong ones.
  #
  # ENABLE_WEBUI is a statement of intent. A listening socket is a fact.
  #
  # ...and only while it is RUNNING. A stopped container listens on nothing, so
  # its port is not an exposure — and reporting it would be a gap nothing can
  # close, because 'lca webui stop' leaves the container (and its baked-in
  # PORT) in place. That is the "unfixable failure" this function's own header
  # says is worse than saying nothing.
  local live already=0 entry
  if webui_container_running; then
    live="$(webui_container_env PORT 2>/dev/null || true)"
  fi
  if [[ "${live:-}" =~ ^[0-9]+$ && "${live}" != "22" ]]; then
    for entry in ${out[@]+"${out[@]}"}; do
      [[ "${entry}" == *" ${live}" ]] && already=1
    done
    (( already )) || out+=("live WebUI ${live}")
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

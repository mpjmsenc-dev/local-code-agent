#!/usr/bin/env bash
# scripts/logs.sh — show the logs that matter, without needing to know where
# any of them live.
#
# The docs suggest `journalctl -u ollama -n 50 | lca ask "why did this fail?"`,
# which is a good loop but assumes you already know the unit name, that the
# WebUI's logs are somewhere else entirely, and that the install log is a third
# place again. This is that loop without the prerequisites:
#
#   lca logs                     recent logs from everything
#   lca logs ollama              just the model server
#   lca logs -f webui            follow the chat app
#   lca logs | lca ask "why did this fail?"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env
# SETUP_LOG comes from lib.sh — the login banner reads the same file to decide
# whether an install is still in flight, and two copies of a path drift.

usage() {
  cat <<EOF
Usage: lca logs [-n LINES] [-f] [SOURCE]

  SOURCE   ollama | webui | setup | all   (default: all)
  -n N     how many lines per source (default 50)
  -f       follow live; needs a single SOURCE, not 'all'

Pipe it straight into the model when something is broken:
  lca logs | lca ask "why did this fail?"
EOF
}

# heading NAME — a plain, greppable separator. Kept free of colour and symbols
# because this output is routinely piped into the model, where decoration is
# just tokens that cost time on CPU.
heading() { printf '\n===== %s =====\n' "$1"; }

logs_ollama() {
  local lines="$1" follow="$2"
  heading "ollama (the model server)"
  if ! systemd_available; then
    # On a host with no service manager, start_ollama_bg() is what runs Ollama
    # — under 'nohup ... &', redirecting into OLLAMA_BG_LOG. So "check the
    # terminal you started it in" was doubly wrong there: this project started
    # it, and a nohup'd background process has no terminal to check. The log it
    # wrote was next to us the whole time, and this is the command the login
    # banner and TROUBLESHOOTING.md both send people to when Ollama misbehaves.
    if [[ -r "${OLLAMA_BG_LOG}" ]]; then
      info "No systemd here — reading the background 'ollama serve' log this project writes:"
      info "  ${OLLAMA_BG_LOG}"
      if [[ "${follow}" == "true" ]]; then
        tail -n "${lines}" -f "${OLLAMA_BG_LOG}"
      else
        tail -n "${lines}" "${OLLAMA_BG_LOG}"
      fi
      return 0
    fi
    info "No systemd on this machine, so there is no service journal."
    info "Ollama's output goes wherever you started 'ollama serve' — check that terminal."
    info "(If this project started it for you, the log would be at ${OLLAMA_BG_LOG}.)"
    return 0
  fi
  local -a cmd=(journalctl -u ollama --no-pager -n "${lines}")
  [[ "${follow}" == "true" ]] && cmd+=( -f )
  run_reader journalctl -u ollama --no-pager -n 0 -- "${cmd[@]}" \
    || warn "Could not read the journal for ollama. Try: sudo journalctl -u ollama -n ${lines}"
}

logs_webui() {
  local lines="$1" follow="$2"
  heading "open webui (the chat app)"
  if ! have docker; then
    info "Docker is not installed, so the chat app is not running here."
    return 0
  fi
  # "Cannot ask" is not "was never created", and run_reader's probe collapses
  # them: 'docker container inspect' returns non-zero for a missing container
  # and for a daemon that is not answering alike. Measured with the daemon
  # unreachable while the container was running and serving:
  #
  #   [warn] Could not read logs for container 'open-webui'
  #          (is it created? try: lca webui status).
  #
  # It is created. It is running. And 'lca webui status' cannot answer either,
  # because it needs the same daemon — so the one command people run when
  # things are broken sent them in a circle. Same fault docker_daemon_reachable
  # was written for, and the same one uninstall.sh had.
  #
  # ONE message for both causes on purpose. This is a log viewer, not a
  # diagnostician: whether the daemon is down or simply unreachable from this
  # account, the reader does the same two things. check-system.sh splits them
  # because telling them apart IS its job; here it would be noise.
  if ! docker_daemon_reachable; then
    info "The Docker daemon could not be reached from this account, so the chat app's logs were not read — which says nothing about whether it is running. Start the daemon ($(docker_start_hint)), or re-run as root, then try again."
    return 0
  fi
  local -a cmd=(docker logs --tail "${lines}" "${WEBUI_CONTAINER}")
  [[ "${follow}" == "true" ]] && cmd+=( -f )
  run_reader docker container inspect "${WEBUI_CONTAINER}" -- "${cmd[@]}" \
    || warn "Could not read logs for container '${WEBUI_CONTAINER}' (is it created? try: lca webui status)."
}

logs_setup() {
  local lines="$1" follow="$2"
  heading "install log"
  # "Not readable" is not "not there", and the two need opposite advice. This
  # tested -r and then called the absence normal — so on a box where the log is
  # root-only (it is written by root, through tee, on a droplet) it announced
  # that a file sitting right there did not exist, and the reader stopped
  # looking. The other two sources here have always escalated through
  # run_reader; this one was the odd one out.
  if [[ ! -e "${SETUP_LOG}" ]]; then
    info "No install log at ${SETUP_LOG} — normal unless this machine was built from deploy/do-user-data.sh."
    return 0
  fi
  local -a cmd=(tail -n "${lines}")
  [[ "${follow}" == "true" ]] && cmd+=( -f )
  cmd+=( "${SETUP_LOG}" )
  run_reader test -r "${SETUP_LOG}" -- "${cmd[@]}" \
    || warn "${SETUP_LOG} exists but could not be read, even as root. Check it with: ls -l ${SETUP_LOG}"
}

main() {
  local lines=50 follow=false source="all" arg
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -n|--lines) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "-n needs a number"; lines="$2"; shift 2 ;;
      -f|--follow) follow=true; shift ;;
      -h|--help) usage; exit 0 ;;
      ollama|webui|setup|all) source="$1"; shift ;;
      *) arg="$1"; usage; die "Unknown argument: ${arg}" ;;
    esac
  done

  # Following several sources at once would interleave two live streams with no
  # way to tell them apart, and Ctrl-C would leave one running.
  if [[ "${follow}" == "true" && "${source}" == "all" ]]; then
    die "-f needs a single source: lca logs -f ollama   (or webui / setup)"
  fi

  case "${source}" in
    ollama) logs_ollama "${lines}" "${follow}" ;;
    webui)  logs_webui  "${lines}" "${follow}" ;;
    setup)  logs_setup  "${lines}" "${follow}" ;;
    all)
      logs_ollama "${lines}" false
      logs_webui  "${lines}" false
      logs_setup  "${lines}" false
      printf '\n'
      info "Ask the model about it:  lca logs | lca ask \"why did this fail?\""
      ;;
  esac
}

main "$@"

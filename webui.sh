#!/usr/bin/env bash
# webui.sh — manage the Open WebUI container: start|stop|restart|status|logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

# Also the help text for 'lca chat', which bin/lca dispatches straight to
# 'webui.sh url'. That mattered: 'lca chat --help' used to print the address
# instead of explaining anything, bin/lca fixed it by forwarding "$@" here, and
# what arrived was a page about 'lca webui' that never contained the word chat
# — one line after 'lca help' promises that every command explains itself. So
# 'url' names the alias, and says what it really prints, which is more than an
# address.
usage() {
  cat <<EOF
Usage: lca webui <command>       (or webui.sh directly)

Commands:
  start     Start the Open WebUI container
  stop      Stop it (chat history is kept in the docker volume)
  restart   Restart it
  status    Container state + HTTP health on port ${WEBUI_PORT}
  url       Phone setup: the chat URL and the SSH address, both as QR codes.
            'lca chat' is a shortcut for exactly this.
  logs      Follow the container logs (Ctrl-C to stop)

To (re)create the container after editing .env, run: sudo lca apply
EOF
}

# Talk to docker the least-privileged way that actually works, decided once.
# scripts/install_docker.sh adds the user to the docker group, so plain 'docker'
# normally works: using as_root unconditionally would trigger a needless sudo
# password prompt (breaking non-interactive use), and with neither root nor sudo
# as_root would die() mid-command instead of giving a usable message.
#
# Three rungs, in this order, and the order is the whole point:
#   1. plain docker            — no escalation at all
#   2. sudo -n                 — escalation that CANNOT stop and ask
#   3. interactive sudo, after saying so
#
# Rung 3 stays because this script mostly ACTS: 'webui.sh start' that refused
# where it used to work would be the worse trade. What it may not do is ask
# silently, and it did — measured, 'lca webui status' printed nothing
# whatsoever and then sat on "[sudo] password for ...". That reads as a hung
# command rather than a question, on a subcommand 'lca help' does not mark as
# needing root. The elif keeps it to ONE escalation attempt, so the sentence
# about a password is printed only where a password can really be asked for:
# root reaching rung 2 and failing has a broken daemon, not a missing password.
DOCKER=(docker)
select_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
    return 0
  fi
  if can_root_now; then
    if as_root docker info >/dev/null 2>&1; then
      DOCKER=(as_root docker)
      return 0
    fi
  elif can_root; then
    # warn, not info: 'lca webui logs' can be piped, and an announcement that
    # lands in the middle of a captured log stream is its own small bug.
    warn "Docker is not reachable as '$(id -un)' — retrying with sudo, which may ask for your password."
    if as_root docker info >/dev/null 2>&1; then
      DOCKER=(as_root docker)
      return 0
    fi
  fi
  return 1
}

container_exists() {
  "${DOCKER[@]}" container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1
}

# port_mismatch_reason — print why a health probe on WEBUI_PORT cannot succeed,
# or return 1 when the ports agree and the probe is worth making.
#
# Every wait here polls .env's WEBUI_PORT, while the container listens on the
# port it was CREATED with. When those differ — someone edited .env and has not
# applied it yet — 'start' and 'restart' each spent 120 seconds probing a port
# nothing was ever going to answer on, then said "check the logs", where a
# perfectly healthy app is logging happily on another port. The mismatch is
# readable off the container in a millisecond, and 'status' already read it;
# one copy of the sentence, used by all three.
port_mismatch_reason() {
  local live
  live="$(webui_container_env PORT || true)"
  [[ -n "${live}" && "${live}" != "${WEBUI_PORT}" ]] || return 1
  printf 'it listens on port %s, not the %s now in .env — it was created before that edit. Apply it with: sudo %s/bin/lca apply' \
    "${live}" "${WEBUI_PORT}" "${REPO_ROOT}"
}

# drift_note — one line after a successful start/restart, when the container is
# still running settings .env has since moved away from.
#
# 'restart' is stop-then-start of the SAME container, and a container's
# environment is fixed when it is created: everything it was built with is
# still in force afterwards. So "Open WebUI restarted." was the whole output on
# a box whose assistant instructions, model or signup policy had changed —
# and restarting is exactly what someone tries when they have edited .env and
# want it to take effect. 'status' has said all of this for a while; the two
# commands that people actually reach for said nothing.
#
# Deliberately not fatal and deliberately not per-key: the restart did work,
# and the detail is one 'lca webui status' away.
drift_note() {
  local drifted
  drifted="$(webui_drift || true)"
  [[ -n "${drifted}" ]] || return 0
  warn "Still NOT in effect: ${drifted//$'\n'/, } — a restart re-uses the settings the container was CREATED with. Apply them with: sudo ${REPO_ROOT}/bin/lca apply (details: lca webui status)"
}

main() {
  local cmd="${1:-}"
  # >&2 and named, like every other error path here — see netmode.sh's "No mode
  # given." for the same case in the same shape.
  [[ -n "${cmd}" ]] || { usage >&2; die "No command given."; }
  # Answered here, above everything else, for the same reason 'url' is special
  # below: the dispatch further down runs select_docker first, so 'lca webui
  # --help' died with "Cannot reach the Docker daemon" — needing a running
  # daemon to print a page of text, on precisely the machine where the daemon
  # being down is what sent you looking for help.
  case "${cmd}" in
    -h|--help) usage; exit 0 ;;
  esac
  # No subcommand here takes an argument, so a second one is always a mistake —
  # and the mistake that matters is '--help', which would otherwise be ignored
  # and the subcommand run anyway. Same guard, and same reason, as netmode.sh.
  case "${2:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown extra argument: ${2}" ;;
  esac
  # WHICH command it is, before anything that needs a working machine — the
  # same argument that hoisted --help above, and it was left half applied.
  # Measured with the daemon down:
  #
  #   $ lca webui nosuchcmd
  #   [FAIL] Cannot reach the Docker daemon as 'root'. Start it: ...
  #
  # A typo diagnosed as a Docker outage, sending the reader to debug a daemon
  # over a misspelling — and on a box where the daemon really is down they
  # never learn the command was wrong at all. Nothing about spelling needs
  # docker to be running, so it is answered here.
  #
  # 'usage >&2' and die, matching the extra-argument guard above rather than
  # the dispatch's own bare 'usage; exit 1', which named nothing: 'lca logs'
  # has said "Unknown argument: X" for a while and this said only "here is the
  # usage", leaving the reader to spot the difference themselves.
  case "${cmd}" in
    start|stop|restart|status|url|logs) ;;
    *) usage >&2; die "Unknown command: ${cmd}" ;;
  esac

  # 'url' only reads .env and Tailscale — it must keep working when Docker is
  # down or the container was never created, since that is exactly when someone
  # is trying to work out where their chat app lives.
  if [[ "${cmd}" == "url" ]]; then
    local ts_ip=""
    if have tailscale; then
      ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "${ts_ip}" ]]; then
      ok "Open this on your phone:  http://${ts_ip}:${WEBUI_PORT}"
      # Point the phone's camera at this instead of typing an IP by hand. The
      # URL is always printed above as well: a terminal QR renders light
      # modules on a dark background, which almost every scanner reads but not
      # quite all, so this is a shortcut and never the only way in.
      # -m 2 keeps the quiet zone; without a margin many scanners refuse.
      if have qrencode; then
        echo
        qrencode -t ANSIUTF8 -m 2 "http://${ts_ip}:${WEBUI_PORT}" 2>/dev/null || true
      fi
      info "(the phone must be signed in to the same Tailscale account — docs/PHONE.md)"
      # The chat's answer to "build me an app" is now, reliably, a command to
      # run in a terminal. On a phone that means SSH — over this same Tailscale
      # address, since the inbound guard leaves SSH open by design. Printing it
      # here costs one line and saves the reader working out that half for
      # themselves at the exact moment they have been told to go somewhere they
      # do not yet know how to reach.
      #
      # SUDO_USER first: run under sudo, 'id -un' says root, and handing someone
      # a root SSH line that their server most likely refuses is worse than
      # printing nothing.
      local ssh_user; ssh_user="$(invoking_user)"
      echo
      ok "For the coding agent (aider), SSH from the phone:  ssh ${ssh_user}@${ts_ip}"
      if have qrencode; then
        echo
        qrencode -t ANSIUTF8 -m 2 "ssh://${ssh_user}@${ts_ip}" 2>/dev/null || true
      fi
      info "(then: mkdir -p ~/my-project && cd ~/my-project && lca — see docs/PHONE.md for SSH apps)"
    else
      # Which of the three reasons matters, because 'sudo tailscale up' on a
      # box without tailscale is a command that does not exist — the rule
      # motd.sh's chat_address() already states in as many words and this
      # branch did not, on the exact command docs/PHONE.md and YOUR-TURN.md
      # both send people to for phone setup.
      if have tailscale; then
        warn "Tailscale has no IPv4 address yet — run: sudo tailscale up"
        info "Once connected: http://<tailscale-ip>:${WEBUI_PORT}"
      elif [[ "${SKIP_TAILSCALE:-false}" == "true" ]]; then
        # No "once connected" line here: Tailscale is deliberately not the
        # route on this box, so a tailscale-ip URL is not what this reader is
        # ever going to type.
        warn "Tailscale is skipped (SKIP_TAILSCALE=true) — reach port ${WEBUI_PORT} over the private network you provide."
      else
        warn "Tailscale is not installed, so there is no private address yet."
        info "Install it: sudo ${SCRIPT_DIR}/scripts/install_tailscale.sh   (then: sudo tailscale up)"
        info "Once connected: http://<tailscale-ip>:${WEBUI_PORT}"
      fi
    fi
    info "On this machine:  http://127.0.0.1:${WEBUI_PORT}"
    exit 0
  fi

  have docker || die "Docker is not installed. Run sudo ${SCRIPT_DIR}/scripts/install_docker.sh first."
  select_docker || die "Cannot reach the Docker daemon as '$(id -un)'. $(docker_unreachable_advice)."

  case "${cmd}" in
    start)
      if container_exists; then
        "${DOCKER[@]}" start "${WEBUI_CONTAINER}" >/dev/null
        local why
        why="$(port_mismatch_reason || true)"
        [[ -z "${why}" ]] || die "The container is started, but ${why}"
        info "Waiting for Open WebUI to answer on port ${WEBUI_PORT}..."
        webui_wait_or_die "${WEBUI_START_TIMEOUT}" "${SCRIPT_DIR}/webui.sh logs"
        ok "Open WebUI started — http://<tailscale-ip>:${WEBUI_PORT}"
        drift_note
      else
        info "Container '${WEBUI_CONTAINER}' does not exist yet — creating it..."
        "${SCRIPT_DIR}/scripts/install_webui.sh"
      fi
      ;;
    stop)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist."
      "${DOCKER[@]}" stop "${WEBUI_CONTAINER}" >/dev/null
      ok "Open WebUI stopped (data kept in the 'open-webui' volume)."
      ;;
    restart)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist — run sudo ${SCRIPT_DIR}/scripts/install_webui.sh first."
      "${DOCKER[@]}" restart "${WEBUI_CONTAINER}" >/dev/null
      local restart_why
      restart_why="$(port_mismatch_reason || true)"
      [[ -z "${restart_why}" ]] || die "The container is restarted, but ${restart_why}"
      info "Waiting for Open WebUI to answer on port ${WEBUI_PORT}..."
      webui_wait_or_die "${WEBUI_START_TIMEOUT}" "${SCRIPT_DIR}/webui.sh logs"
      ok "Open WebUI restarted."
      drift_note
      ;;
    status)
      if ! container_exists; then
        warn "Container '${WEBUI_CONTAINER}' does not exist — run sudo ${SCRIPT_DIR}/scripts/install_webui.sh to create it."
        exit 1
      fi
      local state live_port key
      state="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "${WEBUI_CONTAINER}")"
      info "Container '${WEBUI_CONTAINER}': ${state}"
      # Settings are baked into the container when it is created, so editing
      # .env moves nothing until it is re-created. webui_drift() does the
      # comparing (one copy, in lib.sh — writing it out per key is how signups
      # came to have no check at all); the message stays specific per key,
      # because "PORT differs" and "anyone can still register an account" are
      # not the same news.
      live_port="$(webui_container_env PORT || true)"
      while read -r key; do
        [[ -n "${key}" ]] || continue
        case "${key}" in
          WEBUI_PORT)
            warn "Port drift: the container listens on ${live_port}, but .env says WEBUI_PORT=${WEBUI_PORT}. Apply it with: sudo lca apply" ;;
          MODEL_NAME)
            warn "Model drift: the chat app preselects '$(webui_container_env DEFAULT_MODELS || true)', but .env says MODEL_NAME=${MODEL_NAME} (auto-tune may have changed it). Apply it with: sudo lca apply" ;;
          WEBUI_ENABLE_SIGNUP)
            warn "Signup drift: the running chat app was started with signups $(webui_container_env ENABLE_SIGNUP | tr '[:lower:]' '[:upper:]' || true), but .env says WEBUI_ENABLE_SIGNUP=${WEBUI_ENABLE_SIGNUP}. Editing .env does NOT change a running container — apply it with: sudo lca apply" ;;
          OLLAMA_HOST)
            warn "Ollama address drift: the chat app talks to '$(webui_container_env OLLAMA_BASE_URL || true)', but .env now points Ollama at $(ollama_url). The phone will show no models until the container is re-created: sudo lca apply" ;;
          WEBUI_NAME)
            warn "Name drift: the chat app is titled '$(webui_container_env WEBUI_NAME || true)', but .env says WEBUI_NAME=${WEBUI_NAME}. Apply it with: sudo lca apply" ;;
          SYSTEM_PROMPT)
            warn "System prompt drift: the running chat app still has the assistant instructions it was created with, and this repo now has different ones. Until it is re-created the chat keeps the OLD behaviour — including anything a repo update was meant to fix. Apply it with: sudo lca apply" ;;
          PROMPT_SUGGESTIONS)
            warn "Starter question drift: the chat app's empty-screen suggestions are the ones it was created with, not the ones in config/prompt-suggestions.json. Apply them with: sudo lca apply" ;;
        esac
      done < <(webui_drift || true)
      if webui_responds; then
        ok "Open WebUI /health answering on port ${WEBUI_PORT}."
      else
        # The same sentence the other two branches use, and it names 'lca
        # apply'. This used to send the reader to install_webui.sh — a second
        # answer to a problem the port-drift warning four lines above had
        # already answered with 'lca apply', in the output of one command.
        local status_why
        status_why="$(port_mismatch_reason || true)"
        [[ -z "${status_why}" ]] || die "No /health answer on port ${WEBUI_PORT}, because ${status_why}"
        warn "No /health answer on port ${WEBUI_PORT} (still starting? crash-looping? check: lca webui logs)"
        exit 1
      fi
      ;;
    logs)
      container_exists || die "Container '${WEBUI_CONTAINER}' does not exist."
      "${DOCKER[@]}" logs -f "${WEBUI_CONTAINER}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      # Unreachable: the guard at the top of main() accepts exactly the arms
      # above. Kept, and loud, because without it a command added to that list
      # and not to this case would match nothing, fall out of the case and exit
      # 0 — succeeding silently while doing nothing at all.
      die "internal error: '${cmd}' passed validation but has no implementation"
      ;;
  esac
}

# Sourceable so port_mismatch_reason can be tested without a docker daemon —
# same pattern as restore.sh, uninstall.sh and scripts/apply.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

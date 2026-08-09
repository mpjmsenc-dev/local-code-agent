#!/usr/bin/env bash
# scripts/ollama-relay.sh — let containers reach Ollama without putting Ollama
# on the network.
#
# The problem in one line: a container's loopback is the container. Ollama is
# bound to 127.0.0.1 on purpose, so the agent tier — which runs in its own
# network namespace — reaches this machine as the docker bridge gateway, where
# nothing is listening. Every task it is given then fails without producing a
# single token, and nothing else in the stack looks wrong.
#
# There were two ways out and they are not equal. Widening OLLAMA_HOST to
# 0.0.0.0 puts the model server on every interface this box has and leaves the
# inbound guard as the only thing between it and the internet. This is the
# other one: Ollama stays exactly where it is, and a relay listens on the
# bridge gateway ALONE — an address that is not routable from outside the
# machine — and forwards to loopback.
#
# WHAT DOES THE FORWARDING, and why it is not socat.
#
# systemd-socket-proxyd, which ships inside systemd itself. socat would be a
# new package on every install; a proxy of our own would be a new HTTP parser
# sitting between the agent and the model, on the path where every token
# travels. This adds neither. Proven end to end on a real box: a container run
# with --add-host host.docker.internal:host-gateway fetched
# http://host.docker.internal:11435/api/version through it and got Ollama's
# own answer, with 0.0.0.0 never bound.
#
# WHAT IT DELIBERATELY DOES NOT DO.
#
# The idea was a smarter relay that injects options.num_ctx per client, so the
# agent could have a large context without raising OLLAMA_CONTEXT_LENGTH for
# aider and the chat app too. Measured, and it cannot work that way — the
# OpenAI-compatible endpoint, which is the one OpenHands speaks, ignores it:
#
#   POST /v1/chat/completions  {"options":{"num_ctx":8192}} -> context_length 4096
#   POST /v1/chat/completions  {"num_ctx":8192}             -> context_length 4096
#   POST /api/chat             {"options":{"num_ctx":8192}} -> context_length 8192
#
# A relay could only have delivered it by rewriting /v1 requests onto /api,
# i.e. by reimplementing the translation Ollama already does, on the hot path.
# The per-client context is solved where it belongs instead — a derived model
# carrying PARAMETER num_ctx, which /v1 does honour. See docs/AGENT.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

RELAY_SOCKET_UNIT="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/local-code-agent-ollama-relay.socket"
RELAY_SERVICE_UNIT="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/local-code-agent-ollama-relay.service"

# The proxy binary, wherever this distribution keeps it. Not hardcoded to one
# path: Debian and Ubuntu ship it under /lib, others under /usr/lib, and a unit
# with an ExecStart that does not exist fails at boot with a message about a
# file rather than about a relay.
relay_proxy_bin() {
  local p
  for p in /usr/lib/systemd/systemd-socket-proxyd /lib/systemd/systemd-socket-proxyd; do
    [[ -x "${p}" ]] && { printf '%s' "${p}"; return 0; }
  done
  return 1
}

usage() {
  cat <<EOF
Usage: lca relay <command>

  status            is the relay configured, listening, and does it answer
  install           write and enable the boot units
  remove            stop, disable and delete them

It exists so ENABLE_AGENT=true can be an honest state: the agent runs in its
own network namespace and cannot reach 127.0.0.1:11434 without it.

  ENABLE_OLLAMA_RELAY=${ENABLE_OLLAMA_RELAY}
  OLLAMA_RELAY_PORT=${OLLAMA_RELAY_PORT}

Why a relay rather than OLLAMA_HOST=0.0.0.0: docs/AGENT.md
EOF
}

# render_units — the two unit files, on stdout, in install order.
#
# A socket unit and a service unit rather than one long-running process: the
# socket holds the bind, systemd starts the proxy on the first connection and
# lets it go again when nothing has used it for a while, and the address is
# declared rather than polled for.
#
# FreeBind is the one non-obvious line. The bridge gateway only exists once
# docker has created the bridge, and a .socket that must bind an address that
# is not there yet fails at boot on a machine where docker starts later. With
# it the bind succeeds regardless of ordering, which is the difference between
# a relay that survives a reboot and one that merely survived installation.
render_socket_unit() {
  local addr="$1"
  cat <<EOF
[Unit]
Description=local-code-agent Ollama relay socket (docker bridge -> loopback)
Documentation=file://${REPO_ROOT}/docs/AGENT.md

[Socket]
ListenStream=${addr}
FreeBind=true

[Install]
WantedBy=sockets.target
EOF
}

render_service_unit() {
  local target="$1" proxy="$2"
  cat <<EOF
[Unit]
Description=local-code-agent Ollama relay (forwards the docker bridge to loopback)
Requires=local-code-agent-ollama-relay.socket
After=local-code-agent-ollama-relay.socket ollama.service

[Service]
ExecStart=${proxy} --exit-idle-time=5min ${target}
PrivateTmp=true
EOF
}

do_install() {
  local addr target proxy
  addr="$(ollama_relay_address)" \
    || die "OLLAMA_RELAY_PORT='${OLLAMA_RELAY_PORT}' is not a port number, so there is nothing to listen on. Fix it in ${ENV_FILE}."
  # Ollama's own address, as loopback. ollama_url already normalises 0.0.0.0 to
  # 127.0.0.1, which is what the relay must forward to either way.
  target="$(ollama_url)"; target="${target#http://}"
  proxy="$(relay_proxy_bin)" \
    || die "systemd-socket-proxyd is not on this machine, so the relay has nothing to forward with. It ships with systemd; on Debian and Ubuntu that is the 'systemd' package."
  systemd_available \
    || die "systemd is not available here, so a relay could not survive a reboot. Nothing was installed."

  step "Installing the Ollama relay"
  info "Listening on ${addr} (the docker bridge gateway only), forwarding to ${target}."
  render_socket_unit "${addr}"        | write_root_file "${RELAY_SOCKET_UNIT}"  || die "Could not write ${RELAY_SOCKET_UNIT}"
  render_service_unit "${target}" "${proxy}" | write_root_file "${RELAY_SERVICE_UNIT}" || die "Could not write ${RELAY_SERVICE_UNIT}"
  as_root systemctl daemon-reload || die "systemctl daemon-reload failed"
  as_root systemctl enable --now local-code-agent-ollama-relay.socket >/dev/null 2>&1 \
    || die "Could not enable local-code-agent-ollama-relay.socket — check: systemctl status local-code-agent-ollama-relay.socket"
  # Reported from the far side, not from systemctl. 'active' means the socket
  # is bound, which is not the same as Ollama answering through it, and the
  # difference is the whole reason this component exists.
  if ollama_relay_healthy; then
    ok "The relay is up and Ollama answers through it."
  else
    warn "The relay is installed and the socket is bound, but Ollama did not answer through it. Check that Ollama is running: lca logs ollama"
  fi
}

do_remove() {
  step "Removing the Ollama relay"
  if systemd_available; then
    as_root systemctl disable --now local-code-agent-ollama-relay.socket >/dev/null 2>&1 || true
    as_root systemctl stop local-code-agent-ollama-relay.service >/dev/null 2>&1 || true
  fi
  as_root rm -f "${RELAY_SOCKET_UNIT}" "${RELAY_SERVICE_UNIT}" || true
  systemd_available && { as_root systemctl daemon-reload >/dev/null 2>&1 || true; }
  ok "The relay is gone. Ollama is unchanged — it was never moved off loopback."
}

do_status() {
  local addr unit drift
  if [[ "${ENABLE_OLLAMA_RELAY}" != "true" ]]; then
    info "ENABLE_OLLAMA_RELAY is false. Containers cannot reach Ollama, which matters only if you run the agent tier."
  fi
  if ! addr="$(ollama_relay_address)"; then
    warn "OLLAMA_RELAY_PORT='${OLLAMA_RELAY_PORT}' is not a port number, so no relay address can be formed."
    return 0
  fi
  info "Configured address: ${addr}  (containers dial $(ollama_relay_url))"
  if unit="$(ollama_relay_unit_address)"; then
    info "Installed unit listens on: ${unit}"
  else
    info "No boot units installed. Install them: sudo lca relay install"
  fi
  if drift="$(ollama_relay_drift)"; then
    warn "The installed relay listens on a different address than this machine now has: ${drift}. Re-install it: sudo lca relay install"
  fi
  if ollama_relay_healthy; then
    ok "Ollama answers through the relay."
  else
    warn "Nothing answers through the relay at ${addr}."
  fi
}

main() {
  case "${1:-status}" in
    status)          do_status ;;
    install)         do_install ;;
    remove)          do_remove ;;
    -h|--help|help)  usage; exit 0 ;;
    *)               usage >&2; die "Unknown command: ${1}" ;;
  esac
}

main "$@"

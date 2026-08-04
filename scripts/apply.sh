#!/usr/bin/env bash
# scripts/apply.sh — make the running system match .env.
#
# Most settings in .env are read fresh on every run. Four are not: they are
# baked into a systemd drop-in, a docker container, a systemd timer and an
# nftables ruleset at the moment each is created, and editing .env moves none
# of them. That single fact has caused four separate silent failures — a
# keep-alive that never took effect, a chat app still accepting signups after
# its owner closed them, backups running on a cadence nobody chose, and an
# inbound guard still protecting the port a service used to listen on.
#
# 'lca check' reports all four, each with a different command to fix it. This
# is that command, once. It applies whatever has fallen behind and nothing
# that has not, so it is safe to run whenever you have edited .env and are not
# sure whether it took.
#
# Usage:
#   lca apply             apply whatever drifted
#   lca apply --dry-run   say what would change, touch nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

DRY_RUN=false
CHANGED=0
BLOCKED=0
UNCHECKED=0

usage() {
  cat <<EOF
Usage: lca apply [--dry-run]

Re-applies .env to the parts of the system that hold their own copy of a
setting: the Ollama service, the chat app container, the backup timer and the
inbound guard. Only what has actually drifted is touched.

  --dry-run   report what would change, change nothing
EOF
}

# would CHANGE_DESCRIPTION — in a dry run, announce and decline. Returns 0 when
# the caller should stop (dry run), 1 when it should go ahead.
#
# Printed on STDOUT, deliberately not through warn(). In a dry run these lines
# are the entire answer the user asked for, so 'lca apply --dry-run > plan.txt'
# has to contain the plan — routing them to stderr left that file with a
# summary count and no plan. tune.sh --dry-run reports the same way, on stdout.
would() {
  [[ "${DRY_RUN}" == "true" ]] || return 1
  printf '%b\n' "${C_YELLOW}[would]${C_RESET} $1"
  CHANGED=$((CHANGED+1))
  return 0
}

# needs_root WHAT — a change that cannot be made without root should say so
# plainly rather than dying half way through the other two.
needs_root() {
  can_root && return 0
  warn "$1 needs root — re-run as: sudo ${REPO_ROOT}/bin/lca apply"
  BLOCKED=$((BLOCKED+1))
  return 1
}

apply_ollama() {
  if ! have ollama; then
    info "Ollama:   not installed here — nothing to apply."
    return 0
  fi
  if ! systemd_available; then
    info "Ollama:   no systemd — settings are applied by whatever starts ollama here."
    return 0
  fi
  if ollama_dropin_matches; then
    ok "Ollama:   already matches .env (context ${OLLAMA_CONTEXT_LENGTH}, keep-alive ${OLLAMA_KEEP_ALIVE})."
    return 0
  fi
  would "apply context ${OLLAMA_CONTEXT_LENGTH} / keep-alive ${OLLAMA_KEEP_ALIVE} to Ollama (restarts the server)." && return 0
  needs_root "Applying Ollama settings" || return 0
  info "Ollama:   applying context ${OLLAMA_CONTEXT_LENGTH}, keep-alive ${OLLAMA_KEEP_ALIVE} (this restarts the server)..."
  render_ollama_dropin
  restart_ollama
  ok "Ollama:   applied."
  CHANGED=$((CHANGED+1))
}

apply_webui() {
  if [[ "${ENABLE_WEBUI}" != "true" || "${SKIP_DOCKER}" == "true" ]]; then
    info "Chat app: disabled in .env — nothing to apply."
    return 0
  fi
  if ! have docker; then
    info "Chat app: docker not installed — nothing to apply."
    return 0
  fi
  # "Cannot ask" is not "nothing to do". Without this the message below claims
  # the container was never created — sending the user to an install command
  # that cannot work either, while a perfectly good container may be sitting
  # there with drifted settings.
  if ! docker_daemon_reachable; then
    warn "Chat app: cannot reach the Docker daemon, so its settings were neither checked nor applied. Start it (sudo systemctl start docker), then re-run."
    UNCHECKED=$((UNCHECKED+1))
    return 0
  fi
  if ! webui_container_exists; then
    info "Chat app: not created yet — create it with: ${SCRIPT_DIR}/install_webui.sh"
    return 0
  fi
  local drifted
  drifted="$(webui_drift || true)"
  if [[ -z "${drifted}" ]]; then
    ok "Chat app: already matches .env (port ${WEBUI_PORT}, model ${MODEL_NAME}, signups ${WEBUI_ENABLE_SIGNUP})."
    return 0
  fi
  # Named, because "recreating your chat app" is a bigger thing to do silently
  # than the words "applying .env" suggest.
  local pretty="${drifted//$'\n'/, }"
  would "re-create the chat app container to apply: ${pretty}." && return 0
  info "Chat app: re-creating the container to apply ${pretty} (chats and accounts live in a docker volume and survive)..."
  # Not bare under 'set -e'. A failed re-create aborted 'lca apply' right here:
  # the inbound guard was never reconciled, no summary was printed, and the
  # exit status said "apply failed" without saying what still needed applying.
  if ! "${SCRIPT_DIR}/install_webui.sh"; then
    warn "Chat app: could not be re-created, so ${pretty} is still not in effect — see the error above. Continuing with the rest."
    UNCHECKED=$((UNCHECKED+1))
    return 0
  fi
  ok "Chat app: applied."
  CHANGED=$((CHANGED+1))
}

apply_backup_timer() {
  if ! systemd_available; then
    info "Backups:  no systemd — no timer to apply to."
    return 0
  fi
  if ! systemctl is-enabled --quiet local-code-agent-backup.timer 2>/dev/null; then
    # Deliberately not installed is a choice, not drift. Creating a timer here
    # because someone ran 'lca apply' would be a surprise, and scheduled
    # backups are opt-in by design.
    info "Backups:  no scheduled timer installed (optional) — nothing to apply."
    return 0
  fi
  local live want have_norm
  live="$(installed_backup_schedule || true)"
  want="$(normalized_calendar "${BACKUP_SCHEDULE}" || true)"
  have_norm="$(normalized_calendar "${live}" || true)"
  # Only claim drift when both sides are known: an unparseable spec is not
  # evidence of a difference, and a warning we cannot substantiate is worse
  # than none.
  if [[ -z "${want}" || -z "${have_norm}" || "${want}" == "${have_norm}" ]]; then
    ok "Backups:  timer already on .env's schedule (${live:-${BACKUP_SCHEDULE}})."
    return 0
  fi
  would "move the backup timer from '${live}' to '${BACKUP_SCHEDULE}'." && return 0
  needs_root "Re-installing the backup timer" || return 0
  info "Backups:  moving the timer from '${live}' to '${BACKUP_SCHEDULE}'..."
  "${REPO_ROOT}/backup.sh" --install-timer
  ok "Backups:  applied."
  CHANGED=$((CHANGED+1))
}

# The guard bakes in the ports it drops, so a port changed in .env leaves it
# protecting the old one. Until now it was only ever re-applied as a side
# effect of re-creating the chat app container — which never happens when the
# chat app is off, or when docker is unreachable. In that case 'lca apply'
# printed "Everything already matches .env" while the unauthenticated Ollama
# API listened, publicly, on a port nothing was guarding.
apply_guard() {
  local want dump gaps
  want="$(guarded_ports || true)"
  if [[ -z "${want}" ]]; then
    info "Guard:    nothing binds a public port — no inbound guard needed."
    return 0
  fi
  # Both branches below are "could not look", not "nothing to do": saying the
  # guard matches when we never read it is the failure this command exists to
  # end, one level up.
  if ! have nft; then
    warn "Guard:    nftables is not installed, so the inbound guard was neither checked nor applied. Install it (${SCRIPT_DIR}/install_dependencies.sh), then re-run."
    UNCHECKED=$((UNCHECKED+1))
    return 0
  fi
  if ! can_root; then
    warn "Guard:    reading the firewall needs root, so the inbound guard was neither checked nor applied. Re-run as: sudo ${REPO_ROOT}/bin/lca apply"
    UNCHECKED=$((UNCHECKED+1))
    return 0
  fi
  dump="$(as_root nft list table inet lca_inbound 2>/dev/null || true)"
  if [[ -n "${dump}" ]]; then
    gaps="$(inbound_guard_uncovered "${dump}" || true)"
    if [[ -z "${gaps}" ]]; then
      ok "Guard:    already covers ${want//$'\n'/ + }."
      return 0
    fi
    would "re-apply the inbound guard to cover ${gaps//$'\n'/, }." && return 0
    info "Guard:    re-applying to cover ${gaps//$'\n'/, }..."
  else
    would "apply the inbound guard, which is not loaded, to ${want//$'\n'/ + }." && return 0
    info "Guard:    applying to ${want//$'\n'/ + } (it is not loaded)..."
  fi
  "${REPO_ROOT}/netmode.sh" harden
  ok "Guard:    applied."
  CHANGED=$((CHANGED+1))
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run|-n) DRY_RUN=true ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage; die "Unknown option: ${arg}" ;;
    esac
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    step "What applying .env would change (dry run)"
  else
    step "Applying .env to the running system"
  fi

  # Order matters, and only in one direction. The chat app container is created
  # with OLLAMA_BASE_URL baked in, so when someone moves OLLAMA_HOST to another
  # port — which docs/TROUBLESHOOTING.md now tells them to fix with this very
  # command — Ollama has to be listening on the new port BEFORE the container
  # is rebuilt to point at it. Reversed, the app spends the gap talking to a
  # port nothing answers on, which is the failure this command exists to end.
  #
  # The guard goes last for the same reason: it drops the ports the two above
  # have just settled on, and re-creating the chat app container re-applies it
  # anyway — so by the time we get there it usually has nothing left to do.
  apply_ollama
  apply_webui
  apply_backup_timer
  apply_guard

  echo
  if (( BLOCKED > 0 )); then
    die "${BLOCKED} change(s) need root and were not applied. Re-run: sudo ${REPO_ROOT}/bin/lca apply"
  fi
  if (( CHANGED == 0 )); then
    if (( UNCHECKED > 0 )); then
      # Never "everything matches" when something could not be looked at.
      warn "Nothing needed applying, but ${UNCHECKED} component(s) could not be checked — see above."
      return 0
    fi
    ok "Everything already matches .env — nothing to do."
    return 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    # A plan is a claim about what is left to do, so it carries the same rule
    # as the other three summaries: never present it as complete when a
    # component could not be looked at. The CHANGED==0 branch above already
    # said so; this one printed the count alone, and a reader with a docker
    # daemon down would take "1 change would be applied" as the whole list.
    if (( UNCHECKED > 0 )); then
      warn "${CHANGED} change(s) would be applied, but ${UNCHECKED} component(s) could not be checked at all — the real plan may be longer. See above, then re-run."
      return 0
    fi
    info "${CHANGED} change(s) would be applied. Run without --dry-run to do it."
    return 0
  fi
  if (( UNCHECKED > 0 )); then
    warn "Applied ${CHANGED} change(s), but ${UNCHECKED} component(s) could not be checked — see above."
    return 0
  fi
  ok "Applied ${CHANGED} change(s). Verify with: lca check"
}

# Run main only when executed, so tests can source this file and drive the
# individual appliers — same pattern as scripts/tune.sh and scripts/motd.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

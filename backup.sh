#!/usr/bin/env bash
# backup.sh — create one timestamped tarball in backups/ containing:
#   - the Open WebUI docker volume (accounts, chats, settings)
#   - your .env
#   - the list of installed Ollama models (models re-pull on restore;
#     the multi-GB blobs are deliberately NOT tarred)
# Then prune old backups, keeping the newest BACKUP_KEEP (.env; default 7) so
# they can't slowly fill the disk. Restore with: ./restore.sh <tarball>
#
# Usage:
#   backup.sh                 create a backup now (and prune old ones)
#   backup.sh --install-timer install a systemd timer that runs this daily
#   backup.sh --uninstall-timer  remove that timer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

BACKUP_DIR="${REPO_ROOT}/backups"
BACKUP_SERVICE=/etc/systemd/system/local-code-agent-backup.service
BACKUP_TIMER=/etc/systemd/system/local-code-agent-backup.timer

do_backup() {
  step "Creating backup"
  local stamp tarball
  stamp="$(date +%Y%m%d-%H%M%S)"
  # workdir stays global: the EXIT trap runs after main() returns, where a
  # local would already be out of scope (unbound under set -u).
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir:-}"' EXIT
  mkdir -p "${BACKUP_DIR}"
  tarball="${BACKUP_DIR}/local-code-agent-backup-${stamp}.tar.gz"

  # 1. Open WebUI docker volume (accounts + chat history).
  if have docker && as_root docker volume inspect open-webui >/dev/null 2>&1; then
    info "Archiving the 'open-webui' docker volume..."
    # Open WebUI stores its data in a WAL-mode SQLite database. Archiving it
    # while the container is writing yields a torn, possibly-corrupt snapshot
    # that only surfaces at restore time. Pause the container (freezes its
    # processes) around the tar so the on-disk files are consistent, and
    # guarantee it is unpaused again even if the tar fails.
    local paused=false
    if as_root docker container inspect -f '{{.State.Running}}' "${WEBUI_CONTAINER}" 2>/dev/null | grep -q true; then
      if as_root docker pause "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
        paused=true
        # shellcheck disable=SC2064
        trap "as_root docker unpause ${WEBUI_CONTAINER} >/dev/null 2>&1 || true; rm -rf \"${workdir:-}\"" EXIT
      else
        warn "Could not pause '${WEBUI_CONTAINER}' — archiving live (snapshot may be inconsistent)."
      fi
    fi
    if as_root docker run --rm --entrypoint tar -v open-webui:/from:ro -v "${workdir}":/to \
        ghcr.io/open-webui/open-webui:main \
        czf /to/open-webui-volume.tar.gz -C /from .; then
      ok "WebUI data archived."
    else
      warn "Could not archive the WebUI volume — continuing without it."
    fi
    if [[ "${paused}" == "true" ]]; then
      # Only tear down the unpause-guaranteeing trap once the unpause has
      # actually succeeded; otherwise leave the trap in place (it will retry
      # the unpause on exit) and warn, so the container can never be left
      # paused and unreachable from the phone.
      if as_root docker unpause "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
        trap 'rm -rf "${workdir:-}"' EXIT
      else
        warn "Could not unpause '${WEBUI_CONTAINER}' now — the exit trap will retry. If it stays paused, run: sudo docker unpause ${WEBUI_CONTAINER}"
      fi
    fi
  else
    warn "No 'open-webui' docker volume found — skipping WebUI data."
  fi

  # 2. .env
  if [[ -f "${ENV_FILE}" ]]; then
    cp "${ENV_FILE}" "${workdir}/env"
    ok ".env captured."
  else
    warn "No .env file found — skipping it."
  fi

  # 3. Installed model list (names only; blobs re-pull on restore).
  if have ollama; then
    if ollama list > "${workdir}/models.txt" 2>/dev/null; then
      ok "Model list captured: $(tail -n +2 "${workdir}/models.txt" | { grep -c . || true; }) model(s)."
    else
      warn "Could not list models (is Ollama running?) — skipping the model list."
    fi
  else
    warn "Ollama not installed — skipping the model list."
  fi

  tar czf "${tarball}" -C "${workdir}" .
  as_root chown "$(id -un)" "${tarball}" 2>/dev/null || true
  ok "Backup written: ${tarball} ($(du -h "${tarball}" | cut -f1))"

  prune_old_backups

  info "Copy it off the machine (e.g. scp) — restore with: ./restore.sh ${tarball}"
}

# Keep only the newest BACKUP_KEEP tarballs; delete older ones so a daily/cron
# backup can never silently fill the disk. BACKUP_KEEP=0 disables pruning.
prune_old_backups() {
  local keep="${BACKUP_KEEP:-7}" stale=() f
  shopt -s nullglob
  local files=( "${BACKUP_DIR}"/local-code-agent-backup-*.tar.gz )
  shopt -u nullglob
  (( ${#files[@]} )) || return 0
  mapfile -t stale < <(printf '%s\n' "${files[@]}" | backups_to_prune "${keep}")
  (( ${#stale[@]} )) || return 0
  info "Retention: keeping the newest ${keep}; removing $(( ${#stale[@]} )) older backup(s)."
  for f in "${stale[@]}"; do
    if rm -f "${f}"; then
      info "  pruned $(basename "${f}")"
    else
      warn "  could not remove ${f}"
    fi
  done
}

# install_timer — schedule do_backup daily via systemd. The timer owns the
# schedule; the oneshot service just runs backup.sh (no [Install] on it, so it
# only ever fires from the timer, never at boot). Persistent=true catches up a
# run missed while the box was off.
install_timer() {
  if ! systemd_available; then
    warn "systemd is not available here — cannot install the backup timer. Run '${SCRIPT_DIR}/backup.sh' from cron instead."
    return 0
  fi
  # Catch a bad BACKUP_SCHEDULE now (a clear error) rather than writing a timer
  # that systemd silently never fires.
  if have systemd-analyze && ! systemd-analyze calendar "${BACKUP_SCHEDULE}" >/dev/null 2>&1; then
    die "BACKUP_SCHEDULE='${BACKUP_SCHEDULE}' is not a valid systemd OnCalendar expression. Examples: daily | weekly | '*-*-* 03:30:00'."
  fi
  info "Installing the backup timer (${BACKUP_TIMER}) — schedule: ${BACKUP_SCHEDULE}"
  {
    echo "[Unit]"
    echo "Description=local-code-agent backup (WebUI data + .env + model list)"
    echo "After=docker.service"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStart=${SCRIPT_DIR}/backup.sh"
  } | as_root tee "${BACKUP_SERVICE}" >/dev/null
  {
    echo "[Unit]"
    echo "Description=Run the local-code-agent backup on a schedule"
    echo ""
    echo "[Timer]"
    echo "OnCalendar=${BACKUP_SCHEDULE}"
    echo "Persistent=true"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
  } | as_root tee "${BACKUP_TIMER}" >/dev/null
  as_root systemctl daemon-reload
  as_root systemctl enable --now local-code-agent-backup.timer >/dev/null 2>&1 \
    || die "Could not enable local-code-agent-backup.timer — check: systemctl status local-code-agent-backup.timer"
  ok "Scheduled backups on: ${BACKUP_SCHEDULE}, keeping the newest ${BACKUP_KEEP:-7} (systemctl list-timers local-code-agent-backup.timer)."
}

# uninstall_timer — remove the timer + service (used by uninstall.sh too).
uninstall_timer() {
  if systemd_available; then
    as_root systemctl disable --now local-code-agent-backup.timer >/dev/null 2>&1 || true
  fi
  as_root rm -f "${BACKUP_TIMER}" "${BACKUP_SERVICE}"
  if systemd_available; then
    as_root systemctl daemon-reload
  fi
  ok "Scheduled backup timer removed."
}

usage() { sed -n '10,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  case "${1:-}" in
    "")                 do_backup ;;
    --install-timer)    install_timer ;;
    --uninstall-timer)  uninstall_timer ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "Unknown option: ${1}" ;;
  esac
}

main "$@"

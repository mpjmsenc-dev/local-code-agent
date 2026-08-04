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
#   backup.sh --install-timer install a systemd timer (BACKUP_SCHEDULE in .env;
#                             default: daily at 03:30)
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
  mkdir -p "${BACKUP_DIR}" 2>/dev/null || true
  # Owner-only. Every archive in here holds the Open WebUI database — account
  # password hashes and the JWT signing key that mints valid sessions — plus a
  # copy of .env. It was 755, holding 644 files, so any other login on the box
  # could read all of it. Applied to an existing directory too, since the ones
  # already out there were created wide open.
  chmod 700 "${BACKUP_DIR}" 2>/dev/null || true
  # The timer runs backup.sh as root. If root created backups/ first, a later
  # non-root run would fail with a bare 'tar: Cannot open: Permission denied'
  # and set -e would abort with no explanation — say what's wrong instead.
  [[ -w "${BACKUP_DIR}" ]] || die "Cannot write to ${BACKUP_DIR} (owned by $(stat -c %U "${BACKUP_DIR}" 2>/dev/null || echo 'another user')). Re-run with sudo, or: sudo chown -R $(id -un) ${BACKUP_DIR}"
  tarball="${BACKUP_DIR}/local-code-agent-backup-${stamp}.tar.gz"

  # Retention below must never evict an older COMPLETE backup because this run
  # captured less than it should have. Three distinct states — conflating the
  # last two either destroys data or disables retention forever:
  #   none      no WebUI data exists on this machine  -> nothing to lose, prune
  #   captured  the volume exists and we archived it  -> complete, prune
  #   missed    the volume exists (or docker is down so we cannot tell) and we
  #             did NOT archive it                    -> keep older backups
  local webui_state="none"
  # lib.sh's probe rather than a fourth hand-written copy of it: this one was
  # correct, and being correct in four places is how the fifth is not.
  local docker_ok=false
  if docker_daemon_reachable; then
    docker_ok=true
  fi

  # 1. Open WebUI docker volume (accounts + chat history).
  local docker_installed=false volume_present=false data_state
  have docker && docker_installed=true
  if [[ "${docker_ok}" == "true" ]] && as_root docker volume inspect open-webui >/dev/null 2>&1; then
    volume_present=true
  fi
  data_state="$(webui_data_state "${docker_ok}" "${docker_installed}" "${volume_present}")"

  if [[ "${data_state}" == "present" ]]; then
    webui_state="missed"   # promoted to "captured" only if the archive succeeds
    info "Archiving the 'open-webui' docker volume..."
    # Open WebUI stores its data in a WAL-mode SQLite database. Archiving it
    # while the container is writing yields a torn, possibly-corrupt snapshot
    # that only surfaces at restore time. Pause the container (freezes its
    # processes) around the tar so the on-disk files are consistent, and
    # guarantee it is unpaused again even if the tar fails.
    local paused=false
    # Paused is checked FIRST, and it is not the same question as Running.
    #
    # A container left paused — by a run killed with a signal the EXIT trap
    # cannot catch — still reports State.Running=true, and 'docker pause' then
    # fails on it with "already paused". That failure used to land in the
    # "could not pause" branch below, which leaves 'paused' false, installs no
    # trap, and skips the unpause at the end. So every later backup archived
    # happily and left the chat app frozen, unreachable from the phone, while
    # the warning claimed it was "archiving live". Adopting the unpause here is
    # what ends that: whoever finds it paused is responsible for resuming it.
    if as_root docker container inspect -f '{{.State.Paused}}' "${WEBUI_CONTAINER}" 2>/dev/null | grep -q true; then
      warn "'${WEBUI_CONTAINER}' was already paused — an earlier backup was probably killed before it could unpause. Archiving it as it is, then unpausing."
      paused=true
      # shellcheck disable=SC2064
      trap "as_root docker unpause ${WEBUI_CONTAINER} >/dev/null 2>&1 || true; rm -rf \"${workdir:-}\"" EXIT
    elif as_root docker container inspect -f '{{.State.Running}}' "${WEBUI_CONTAINER}" 2>/dev/null | grep -q true; then
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
      webui_state="captured"
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
  elif [[ "${data_state}" == "unknown" ]]; then
    webui_state="missed"
    warn "Docker is installed but its daemon is not usable — cannot check for WebUI data; assuming it exists and protecting older backups."
  else
    warn "No 'open-webui' docker volume on this machine — skipping WebUI data."
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
      # '>' created the file before ollama failed, so a zero-byte models.txt
      # would ship in the archive — and restore.sh reads a models.txt that
      # exists as an authoritative "no models", re-pulling nothing on a machine
      # that had a dozen. An absent file is the honest record of not knowing.
      rm -f "${workdir}/models.txt"
      warn "Could not list models (is Ollama running?) — skipping the model list."
    fi
  else
    warn "Ollama not installed — skipping the model list."
  fi

  # 4. Provenance. A backup carries the SOURCE machine's model and context
  #    length, and the commonest reason to restore one is moving to different
  #    hardware — docs/MIGRATE.md is about nothing else. Without this, restore
  #    cannot say whether the settings it just put back suit the machine it put
  #    them on, so it can only offer advice that is right half the time.
  #
  #    Never fatal: this is metadata about the backup, not part of it.
  if {
       printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
       printf 'host=%s\n'    "$(hostname 2>/dev/null || echo unknown)"
       printf 'ram_gib=%s\n' "$(detect_ram_gib 2>/dev/null || echo 0)"
       printf 'model=%s\n'   "${MODEL_NAME}"
       printf 'context=%s\n' "${OLLAMA_CONTEXT_LENGTH}"
     } > "${workdir}/meta" 2>/dev/null; then
    ok "Source machine recorded ($(detect_ram_gib 2>/dev/null || echo '?') GiB, ${MODEL_NAME})."
  else
    warn "Could not record the source machine — the backup itself is unaffected."
  fi

  # A failed tar (classically: the disk filled up) still leaves a PARTIAL file
  # behind, and set -e would abort before anything cleaned it up. That partial
  # file then becomes the newest tarball in backups/ — which is precisely what
  # restore.sh picks by default. Remove it so a broken archive can never be
  # restored over good data.
  # umask, not a chmod after the fact: tar creates the file the moment it
  # starts, so a chmod afterwards leaves the whole write world-readable and
  # only closes it once the secrets are already on disk.
  local prev_umask; prev_umask="$(umask)"
  umask 077
  if ! tar czf "${tarball}" -C "${workdir}" .; then
    umask "${prev_umask}"
    rm -f "${tarball}"
    die "Could not write ${tarball} (disk full? check: df -h). The partial archive was deleted so it cannot be restored by mistake."
  fi
  umask "${prev_umask}"
  # Only needed when root created the file (the timer runs as root). Guard with
  # can_root: for an unprivileged user without sudo the file is already theirs,
  # and an unguarded as_root would die() here — aborting a backup that had
  # already been written and verified.
  if can_root; then
    as_root chown "$(id -un)" "${tarball}" 2>/dev/null || true
  fi

  # A backup you cannot restore is not a backup. Read the archive back and
  # confirm every file we staged is really in it, BEFORE retention is allowed to
  # delete older (good) backups on the strength of this one.
  if ! verify_backup "${tarball}" "${workdir}"; then
    rm -f "${tarball}"
    die "The backup archive failed verification and was deleted (older backups were kept untouched). Check free space with 'df -h' and re-run ${SCRIPT_DIR}/backup.sh."
  fi
  ok "Backup written and verified: ${tarball} ($(du -h "${tarball}" | cut -f1))"

  # Only prune when this backup is as complete as it was supposed to be.
  # Otherwise an unattended timer run with docker down would, over BACKUP_KEEP
  # nights, silently delete every backup that still had the WebUI accounts and
  # chat history — the exact data this feature exists to protect.
  if [[ "${webui_state}" == "missed" ]]; then
    warn "WebUI data was NOT captured in this backup — skipping retention so older, complete backups are kept. Fix Docker, then re-run ${SCRIPT_DIR}/backup.sh."
  else
    prune_old_backups
  fi

  info "Copy it off the machine (e.g. scp) — restore with: ${SCRIPT_DIR}/restore.sh ${tarball}"
}

# webui_data_state DOCKER_USABLE DOCKER_INSTALLED VOLUME_PRESENT — which of the
# three retention states this machine is in, decided before anything is
# archived. Its own function so all of it can be exercised without a docker
# daemon, the same reason verify_backup below is one.
#
#   present   the volume is there and readable -> archive it, then prune
#   unknown   docker is here but its daemon is not answering, so nothing has
#             LOOKED -> keep older backups
#   none      no docker at all, or docker answered and there is no volume ->
#             nothing to lose, prune
#
# ENABLE_WEBUI is deliberately not a parameter, and used to be part of this
# decision. The volume outlives the setting: switch the chat app off in .env
# and every account and chat is still sitting in 'open-webui' — which is why
# the caller archives it whether or not .env says the chat is enabled. But with
# the daemon down AND ENABLE_WEBUI=false, the old condition fell through to "no
# volume found", a claim nothing had checked, and pruned on the strength of it.
# BACKUP_KEEP nights of that deletes every backup that still had the data —
# the precise failure the three states were introduced to prevent, reachable
# through the one input that has nothing to do with whether the data exists.
webui_data_state() {
  local usable="$1" installed="$2" volume="$3"
  if [[ "${usable}" == "true" && "${volume}" == "true" ]]; then
    printf 'present\n'
  elif [[ "${usable}" != "true" && "${installed}" == "true" ]]; then
    printf 'unknown\n'
  else
    printf 'none\n'
  fi
}

# verify_backup TARBALL STAGING_DIR — true when the archive reads back cleanly
# and contains every file that was staged for it. Catches truncated/corrupt
# archives (the usual cause is a full disk) at the moment they are created,
# instead of months later during a restore that was supposed to save you.
# Comparing against the staging directory means new contents are covered
# automatically, with no list to keep in sync.
verify_backup() {
  local tarball="$1" staging="$2" listing staged missing=()
  # tar tzf decompresses the whole stream, so a truncated gzip fails here.
  listing="$(tar tzf "${tarball}" 2>/dev/null)" || return 1
  [[ -n "${listing}" ]] || return 1
  while IFS= read -r staged; do
    grep -qxF "./${staged}" <<<"${listing}" || missing+=( "${staged}" )
  done < <(cd "${staging}" && find . -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
  if (( ${#missing[@]} )); then
    err "Archive is missing staged file(s): ${missing[*]}"
    return 1
  fi
  return 0
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
  # Create backups/ now, owned by the human running sudo. If the root timer
  # created it first it would be root-owned, and every later non-root
  # './backup.sh' would fail on tar with a permission error.
  as_root mkdir -p "${BACKUP_DIR}"
  as_root chmod 700 "${BACKUP_DIR}"
  as_root chown "${SUDO_USER:-$(id -un)}" "${BACKUP_DIR}" 2>/dev/null || true
  {
    echo "[Unit]"
    echo "Description=local-code-agent backup (WebUI data + .env + model list)"
    echo "After=docker.service"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStart=\"${SCRIPT_DIR}/backup.sh\""
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

# Print the header's Usage block. Anchored to '# Usage:' .. the first non-comment
# line rather than fixed line numbers, which silently drift (and truncate the
# help) whenever the header above gains or loses a line.
usage() {
  sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/!p; }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  case "${1:-}" in
    "")                 do_backup ;;
    --install-timer)    install_timer ;;
    --uninstall-timer)  uninstall_timer ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "Unknown option: ${1}" ;;
  esac
}

# Run main only when executed, so tests can source this file and unit-test
# verify_backup() without taking a real backup (same pattern as scripts/tune.sh).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

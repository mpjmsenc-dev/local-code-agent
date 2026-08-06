#!/usr/bin/env bash
# restore.sh — reverse of backup.sh on a fresh install:
#   - restores .env (backing up any existing one first)
#   - restores the Open WebUI docker volume and recreates the container
#   - re-pulls the models recorded in the backup
# Usage: lca restore [backup-tarball]   (default: newest in backups/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
# This script ACTS — see LCA_MAY_PROMPT in lib.sh. It recreates docker volumes,
# so its daemon probe must be allowed to ask rather than report "cannot look"
# and skip the WebUI data on a machine where the daemon is perfectly fine.
LCA_MAY_PROMPT=true

usage() {
  # This file's header comment block is the help text — read to the first
  # non-comment line, so editing the header cannot silently truncate it.
  sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
}

BACKUP_DIR="${REPO_ROOT}/backups"

# machine_advice META_FILE — say whether the restored .env suits THIS machine.
#
# Its own function purely so the three branches can be exercised without
# running a real restore, which overwrites .env and the WebUI volume and is
# therefore not something a test suite can do.
machine_advice() {
  local meta="$1" src_ram="" src_model="" here_ram
  if [[ -f "${meta}" ]]; then
    src_ram="$(sed -n 's/^ram_gib=//p' "${meta}" | head -1)"
    src_model="$(sed -n 's/^model=//p' "${meta}" | head -1)"
  fi
  here_ram="$(detect_ram_gib 2>/dev/null || echo 0)"
  if [[ "${src_ram}" =~ ^[0-9]+$ ]] && (( src_ram > 0 )) && [[ "${src_ram}" != "${here_ram}" ]]; then
    # Precise, because the backup records where it came from.
    warn "This backup is from a ${src_ram} GiB machine (model ${src_model:-unknown}); this one has ${here_ram} GiB. The restored .env is the OLD machine's. Re-pick for this one now: sudo ${REPO_ROOT}/bin/lca tune"
  elif [[ -z "${src_ram}" ]]; then
    # A backup taken before provenance was recorded. "Cannot tell" is not
    # "they match", so give the conditional advice rather than none.
    info "Restored .env carries the backup machine's model (${MODEL_NAME}, context ${OLLAMA_CONTEXT_LENGTH})."
    info "This backup predates machine details, so if it came from different hardware: sudo ${REPO_ROOT}/bin/lca tune"
  else
    ok "Backup and this machine agree on RAM (${here_ram} GiB) — ${MODEL_NAME} is the right model here."
  fi
}

# restore_webui_volume WORKDIR — put the chat app's docker volume back from an
# unpacked backup, and re-create the container around it.
#
# ALWAYS returns 0. Everything it can fail at is reported and survived, because
# the model re-pull, the 'lca apply' reconciliation and the machine advice all
# come after it and are worth having even when the chat data is not.
#
# Its own function for the same reason machine_advice is, one up: the branches
# that matter are the FAILING ones, and no test can perform a real restore to
# reach them. Extracting it is what let the daemon-down path below actually be
# exercised — it had never been run, and it aborted the whole recovery.
restore_webui_volume() {
  local workdir="$1" vol_rc=0
  if [[ ! -f "${workdir}/open-webui-volume.tar.gz" ]]; then
    warn "Backup contains no WebUI volume archive — skipping."
    return 0
  fi
  # Asked BEFORE anything is attempted, because "docker is installed" and
  # "docker answers" are different facts and everything below assumes the
  # second. With the daemon down each step failed in turn until a bare
  # 'docker volume create' aborted restore.sh under set -e: no model re-pull,
  # no apply.sh, no machine advice, just a raw docker error at the end of a
  # recovery. On the machine docs/MIGRATE.md is written for — a fresh box you
  # are restoring onto — a daemon that is not up yet is not an exotic state.
  if ! have docker; then
    warn "Docker not installed — cannot restore the WebUI volume. Run ${SCRIPT_DIR}/setup.sh first, then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
    return 0
  fi
  if ! docker_daemon_reachable; then
    warn "The Docker daemon is not responding, so the WebUI volume was NOT restored — nothing was touched and any existing data is intact. Start it ($(docker_start_hint)), then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
    return 0
  fi
  info "Restoring the 'open-webui' docker volume..."
  # The tar/untar helper needs the open-webui image; on a fresh machine it
  # isn't cached, so guard the implicit pull the way every other download path
  # does instead of dropping a raw registry error.
  if ! as_root docker image inspect "${WEBUI_IMAGE}" >/dev/null 2>&1; then
    # net_blocked, not net_guard: the guard die()s, and dying here skipped the
    # model re-pull, the reconciliation and the machine advice. Offline is a
    # state this project TELLS people to be in, so a restore meeting it is
    # ordinary rather than exceptional — and without the image there is nothing
    # to untar with, so this step is over either way. Say so and get on.
    if net_blocked; then
      warn "The ${WEBUI_IMAGE} image is not on this machine and netmode is OFFLINE, so the WebUI volume was NOT restored — nothing was touched and any existing data is intact. Run 'sudo ${SCRIPT_DIR}/netmode.sh online', then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
      return 0
    fi
    as_root docker pull "${WEBUI_IMAGE}" \
      || warn "Could not pull the Open WebUI image — the volume restore below may fail; re-run after 'sudo ${SCRIPT_DIR}/netmode.sh online' or once online."
  fi
  # These two were bare, and either one failing took the whole restore with it.
  # They join the vol_rc scheme instead, because the reader's real question is
  # the one all these codes exist to answer: is my existing data still there?
  # For 6 and 7 it always is — neither runs after the volume has been touched.
  #   6 = the old container would not go away; nothing was replaced
  #   7 = the volume could not be created; nothing was replaced
  if as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
    as_root docker rm -f "${WEBUI_CONTAINER}" >/dev/null || vol_rc=6
  fi
  if (( vol_rc == 0 )) && ! as_root docker volume create open-webui >/dev/null; then
    vol_rc=7
  fi
  # 'tar tzf' FIRST, inside the same shell: the extraction wipes the live
  # volume ('rm -rf /to/*') before unpacking, so a corrupt inner archive would
  # destroy the existing accounts and chat history and then fail to replace
  # them. Validating first means a bad archive aborts while the current data is
  # still intact.
  # Distinct exit codes per stage, because the failure message has to say
  # whether the live volume still exists — and the '&&' chain this used to be
  # could not tell. Validation failing and the unpack failing landed in the
  # same branch, which asserted "Your existing WebUI data was NOT wiped" either
  # way. After 'rm -rf /to/*' has run, that sentence is false on the one path
  # where the reader most needs it to be true: a disk that fills during the
  # unpack empties the volume and then says nothing was lost.
  #   3 = the archive would not read; nothing was touched
  #   4 = clearing the volume failed; nothing was lost
  #   5 = the unpack failed AFTER the volume was emptied
  if (( vol_rc == 0 )); then
    as_root docker run --rm --entrypoint sh -v open-webui:/to -v "${workdir}":/from:ro \
        "${WEBUI_IMAGE}" \
        -c 'tar tzf /from/open-webui-volume.tar.gz >/dev/null || exit 3
            rm -rf /to/* || exit 4
            tar xzf /from/open-webui-volume.tar.gz -C /to || exit 5' \
      || vol_rc=$?
  fi
  case "${vol_rc}" in
    0)
      ok "WebUI data restored."
      if [[ "${ENABLE_WEBUI}" == "true" ]]; then
        # Not bare under 'set -e': a failed re-create would abort restore.sh
        # here, before the models are re-pulled and before apply.sh puts the
        # restored .env into effect. A recovery command must finish everything
        # it still can and report what it could not.
        "${SCRIPT_DIR}/scripts/install_webui.sh" \
          || warn "The chat app container could not be re-created — its data IS restored. Fix the cause and run: sudo lca apply. Continuing with the rest of the restore."
      fi
      ;;
    3|125|126|127)
      # 125/126/127 are docker's own: the image is missing or the container
      # never started, so the script inside never ran either.
      warn "WebUI volume NOT restored — the image is unavailable (offline?) or the archived volume is unreadable. Your existing WebUI data was NOT wiped: nothing is replaced until the archive has been read back. Fix connectivity or use another backup, then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
      ;;
    4)
      warn "WebUI volume NOT restored — the old contents could not be cleared, so your existing WebUI data is still there and unchanged. Check disk and permissions, then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
      ;;
    5)
      err "WebUI volume restore FAILED PART-WAY: the volume was emptied and the archive did not finish unpacking, so the old accounts and chat history are gone and the new ones are incomplete. A full disk is the usual cause — free space, then re-run ${SCRIPT_DIR}/restore.sh with the same backup. Continuing with the model restore."
      ;;
    6)
      warn "WebUI volume NOT restored — the old '${WEBUI_CONTAINER}' container could not be removed, so nothing was replaced and your existing WebUI data is intact. Clear it by hand (sudo docker rm -f ${WEBUI_CONTAINER}), then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
      ;;
    7)
      warn "WebUI volume NOT restored — the 'open-webui' volume could not be created, so nothing was replaced and your existing WebUI data is intact. Check disk space and the docker daemon, then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
      ;;
    *)
      warn "WebUI volume restore failed with an unrecognised status (${vol_rc}) — this cannot say whether the volume was emptied. Check it with: sudo docker run --rm -v open-webui:/v alpine ls /v. Continuing with the model restore."
      ;;
  esac
  return 0
}

main() {
  # Before the step banner, and before anything is chosen to restore: asking
  # a destructive command what it does must never be answered by doing it.
  # '--help' used to fall through as a filename — "Backup file not found:
  # --help" — which is a true sentence and a useless one.
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac
  step "Restoring from backup"
  local tarball="${1:-}"
  if [[ -z "${tarball}" ]]; then
    [[ -d "${BACKUP_DIR}" ]] || die "No tarball given and ${BACKUP_DIR} does not exist. Usage: ${SCRIPT_DIR}/restore.sh <backup.tar.gz>"
    # '|| true' keeps the empty-directory case from aborting the whole
    # script under set -euo pipefail (find exits nonzero) — the explicit
    # emptiness check below emits the helpful message instead.
    tarball="$(find "${BACKUP_DIR}" -maxdepth 1 -name 'local-code-agent-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
    [[ -n "${tarball}" ]] || die "No tarball given and none found in ${BACKUP_DIR}. Usage: ${SCRIPT_DIR}/restore.sh <backup.tar.gz>"
    info "Using newest backup: ${tarball}"
  fi
  [[ -f "${tarball}" ]] || die "Backup file not found: ${tarball}"

  # workdir stays global: the EXIT trap runs after main() returns, where a
  # local would already be out of scope (unbound under set -u).
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir:-}"' EXIT
  # Read the archive back before extracting anything. A truncated/corrupt
  # tarball (classically: the disk filled during backup) would otherwise extract
  # partially and then abort part-way through the restore. Fail here, with a
  # clear cause, while nothing on the system has been touched yet.
  tar tzf "${tarball}" >/dev/null 2>&1 \
    || die "'${tarball}' is not a readable gzip archive — it is corrupt or truncated. Nothing was changed. Try an older backup in ${BACKUP_DIR}, or a copy you moved off-box."
  tar xzf "${tarball}" -C "${workdir}"

  # ...and a readable gzip is still not necessarily OUR gzip. Each component
  # below is optional on purpose, so an older or partial backup restores what
  # it does have and skips the rest. But when NONE of them is present the file
  # is not a backup at all, and the old code walked the whole optional path and
  # finished with "[ ok ] Restore complete." Measured, on a tarball containing
  # one text file:
  #
  #   [warn] Backup contains no .env — skipping.
  #   [warn] Backup contains no WebUI volume archive — skipping.
  #   [warn] Backup contains no model list — skipping.
  #   [ ok ] Restored settings are in effect.
  #   [ ok ] Restore complete.
  #
  # Three warnings nobody reads as fatal, two claims that are simply false —
  # the "restored" settings were the current ones — and exit 0. Someone who
  # points this at the wrong file is told their data came back, and may then
  # delete the source it was still sitting in.
  local components=0 component
  for component in env open-webui-volume.tar.gz models.txt meta; do
    [[ -e "${workdir}/${component}" ]] && components=$(( components + 1 ))
  done
  (( components > 0 )) || die "'${tarball}' is a valid archive but contains none of a local-code-agent backup's parts (no env, no WebUI volume, no model list, no machine details) — it is some other tarball. Nothing was changed. Backups made by this project live in ${BACKUP_DIR} and are named local-code-agent-backup-*.tar.gz."

  # 1. .env
  #
  # Read before it is installed, because installing it is what runs it. The
  # next statement after this block is load_env, which SOURCES .env — so every
  # line of a file that arrived inside a tarball named on the command line
  # executes here, as root, since a restore recreates docker volumes.
  # docs/MIGRATE.md is built on carrying that tarball between machines, which
  # makes "it is your own backup" an assumption about a file that has been
  # off-box and back.
  #
  # Rejecting is not the same as failing: the volume and the models are still
  # restored below, and the current .env — which load_env then reads instead —
  # is left alone. A conservative validator can also refuse a legitimate but
  # unusual file, so the rejected one is kept next to .env rather than dropped,
  # and the message says where.
  local env_usable=false
  if [[ ! -f "${workdir}/env" ]]; then
    warn "Backup contains no .env — skipping."
  elif env_file_is_inert "${workdir}/env"; then
    env_usable=true
  else
    cp "${workdir}/env" "${ENV_FILE}.rejected" 2>/dev/null || true
    warn "The .env inside this backup contains shell syntax (an expansion, a command substitution, or a second command on a line), not just settings — restoring it would RUN that, as root. It was NOT installed and your current .env is untouched. Read it at ${ENV_FILE}.rejected and, if you recognise every line, copy it over by hand. Continuing with the rest of the restore."
  fi
  if [[ "${env_usable}" == "true" ]]; then
    if [[ -f "${ENV_FILE}" ]] && ! cmp -s "${workdir}/env" "${ENV_FILE}"; then
      if confirm "Overwrite existing .env with the backed-up one? (current saved as .env.pre-restore)"; then
        cp "${ENV_FILE}" "${ENV_FILE}.pre-restore"
        cp "${workdir}/env" "${ENV_FILE}"
        ok ".env restored (previous kept as .env.pre-restore)."
      else
        warn "Keeping the current .env."
      fi
    else
      cp "${workdir}/env" "${ENV_FILE}"
      ok ".env restored."
    fi
  fi
  load_env

  # 2. Open WebUI volume + container.
  restore_webui_volume "${workdir}"

  # 3. Models (re-pull by name).
  if [[ -f "${workdir}/models.txt" ]]; then
    # Announced, and it STARTS Ollama rather than only waiting: a restore is
    # exactly when you want the model server up, and the silent form spent
    # half a minute looking like a hang right at the end of a recovery.
    if have ollama && ensure_ollama_up_announced 30; then
      local model
      # `ollama list` output: NAME  ID  SIZE  MODIFIED (header on line 1).
      while read -r model; do
        [[ -n "${model}" ]] || continue
        if model_present "${model}"; then
          ok "Model '${model}' already present."
        elif net_blocked; then
          # Per model, not once before the loop: which models arrived and which
          # did not is the whole answer here, and the offline branch used to
          # die() on the FIRST missing one — so a restore whose models were all
          # present bar one lost the reconciliation and the machine advice too.
          warn "Model '${model}' is missing and netmode is OFFLINE, so it was not re-pulled. Run 'sudo ${SCRIPT_DIR}/netmode.sh online', then: ollama pull ${model}"
        else
          pull_model "${model}" || warn "Could not pull '${model}' — pull it later with: ollama pull ${model}"
        fi
      done < <(tail -n +2 "${workdir}/models.txt" | awk '{print $1}')
    else
      warn "Ollama not reachable — skipping model re-pull. Run ${SCRIPT_DIR}/setup.sh first, then re-run ${SCRIPT_DIR}/restore.sh."
    fi
  else
    warn "Backup contains no model list — skipping."
  fi

  # A restore replaces .env wholesale, which makes it the single most likely
  # moment for the running system to disagree with it — and the worst moment to
  # find that out later. Nothing above re-renders the Ollama drop-in, so a
  # restored OLLAMA_CONTEXT_LENGTH or OLLAMA_KEEP_ALIVE would not be in effect;
  # and the chat app container is only rebuilt when the backup happened to
  # contain its volume, so otherwise it keeps the settings it was created with.
  #
  # 'lca apply' is exactly this reconciliation, and it is drift-driven, so
  # whatever the steps above already handled costs nothing here.
  step "Reconciling the running system with the restored .env"
  if "${SCRIPT_DIR}/scripts/apply.sh"; then
    ok "Restored settings are in effect."
  else
    warn "Could not fully apply the restored .env — run: sudo ${SCRIPT_DIR}/bin/lca apply"
  fi

  # A backup carries the SOURCE machine's model and context length, and the
  # commonest reason to restore one is moving to different hardware
  # (docs/MIGRATE.md is exactly that). Auto-tune re-picks on the next boot, but
  # there is no reason to run the wrong model until then, and nothing said so.
  machine_advice "${workdir}/meta"

  ok "Restore complete. Verify with: ${SCRIPT_DIR}/check-system.sh"
}

# Sourceable so machine_advice() and restore_webui_volume() can be tested
# without performing a restore — same pattern as scripts/apply.sh and
# scripts/prompt-bench.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

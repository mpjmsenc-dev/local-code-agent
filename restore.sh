#!/usr/bin/env bash
# restore.sh — reverse of backup.sh on a fresh install:
#   - restores .env (backing up any existing one first)
#   - restores the Open WebUI docker volume and recreates the container
#   - re-pulls the models recorded in the backup
# Usage: ./restore.sh [backup-tarball]   (default: newest in backups/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

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

main() {
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

  # 1. .env
  if [[ -f "${workdir}/env" ]]; then
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
  else
    warn "Backup contains no .env — skipping."
  fi
  load_env

  # 2. Open WebUI volume + container.
  if [[ -f "${workdir}/open-webui-volume.tar.gz" ]]; then
    if have docker; then
      info "Restoring the 'open-webui' docker volume..."
      # The tar/untar helper needs the open-webui image; on a fresh machine
      # it isn't cached, so guard the implicit pull the way every other
      # download path does instead of dropping a raw registry error.
      if ! as_root docker image inspect ghcr.io/open-webui/open-webui:main >/dev/null 2>&1; then
        net_guard "Pulling the Open WebUI image (needed to restore the volume)"
        as_root docker pull ghcr.io/open-webui/open-webui:main \
          || warn "Could not pull the Open WebUI image — the volume restore below may fail; re-run after 'sudo ${SCRIPT_DIR}/netmode.sh online' or once online."
      fi
      if as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
        as_root docker rm -f "${WEBUI_CONTAINER}" >/dev/null
      fi
      as_root docker volume create open-webui >/dev/null
      # 'tar tzf' FIRST, inside the same shell: the extraction wipes the live
      # volume ('rm -rf /to/*') before unpacking, so a corrupt inner archive
      # would destroy the existing accounts and chat history and then fail to
      # replace them. Validating first means a bad archive aborts while the
      # current data is still intact.
      if as_root docker run --rm --entrypoint sh -v open-webui:/to -v "${workdir}":/from:ro \
          ghcr.io/open-webui/open-webui:main \
          -c 'tar tzf /from/open-webui-volume.tar.gz >/dev/null && rm -rf /to/* && tar xzf /from/open-webui-volume.tar.gz -C /to'; then
        ok "WebUI data restored."
        if [[ "${ENABLE_WEBUI}" == "true" ]]; then
          "${SCRIPT_DIR}/scripts/install_webui.sh"
        fi
      else
        warn "WebUI volume restore failed — either the image is unavailable (offline?) or the archived volume is corrupt. Your existing WebUI data was NOT wiped (the archive is validated before the volume is replaced). Fix connectivity or use another backup, then re-run ${SCRIPT_DIR}/restore.sh; continuing with the model restore."
      fi
    else
      warn "Docker not installed — cannot restore the WebUI volume. Run ${SCRIPT_DIR}/setup.sh first, then re-run ${SCRIPT_DIR}/restore.sh."
    fi
  else
    warn "Backup contains no WebUI volume archive — skipping."
  fi

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
        else
          net_guard "Re-pulling ${model}"
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

# Sourceable so machine_advice() can be tested without performing a restore —
# same pattern as scripts/apply.sh and scripts/prompt-bench.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

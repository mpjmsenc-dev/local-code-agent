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

main() {
  step "Restoring from backup"
  local tarball="${1:-}"
  if [[ -z "${tarball}" ]]; then
    tarball="$(find "${BACKUP_DIR}" -maxdepth 1 -name 'local-code-agent-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    [[ -n "${tarball}" ]] || die "No tarball given and none found in ${BACKUP_DIR}. Usage: ./restore.sh <backup.tar.gz>"
    info "Using newest backup: ${tarball}"
  fi
  [[ -f "${tarball}" ]] || die "Backup file not found: ${tarball}"

  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT
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
      if as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
        as_root docker rm -f "${WEBUI_CONTAINER}" >/dev/null
      fi
      as_root docker volume create open-webui >/dev/null
      as_root docker run --rm -v open-webui:/to -v "${workdir}":/from:ro \
        ghcr.io/open-webui/open-webui:main \
        sh -c 'rm -rf /to/* && tar xzf /from/open-webui-volume.tar.gz -C /to'
      ok "WebUI data restored."
      if [[ "${ENABLE_WEBUI}" == "true" ]]; then
        "${SCRIPT_DIR}/scripts/install_webui.sh"
      fi
    else
      warn "Docker not installed — cannot restore the WebUI volume. Run ./setup.sh first, then re-run restore.sh."
    fi
  else
    warn "Backup contains no WebUI volume archive — skipping."
  fi

  # 3. Models (re-pull by name).
  if [[ -f "${workdir}/models.txt" ]]; then
    if have ollama && wait_for_ollama 30; then
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
      warn "Ollama not reachable — skipping model re-pull. Run ./setup.sh first, then re-run restore.sh."
    fi
  else
    warn "Backup contains no model list — skipping."
  fi

  ok "Restore complete. Verify with: ./check-system.sh"
}

main "$@"

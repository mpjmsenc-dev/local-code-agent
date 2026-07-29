#!/usr/bin/env bash
# backup.sh — create one timestamped tarball in backups/ containing:
#   - the Open WebUI docker volume (accounts, chats, settings)
#   - your .env
#   - the list of installed Ollama models (models re-pull on restore;
#     the multi-GB blobs are deliberately NOT tarred)
# Restore on a fresh install with: ./restore.sh <tarball>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

BACKUP_DIR="${REPO_ROOT}/backups"

main() {
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
    if as_root docker run --rm -v open-webui:/from:ro -v "${workdir}":/to \
        ghcr.io/open-webui/open-webui:main \
        tar czf /to/open-webui-volume.tar.gz -C /from .; then
      ok "WebUI data archived."
    else
      warn "Could not archive the WebUI volume — continuing without it."
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
  info "Copy it off the machine (e.g. scp) — restore with: ./restore.sh ${tarball}"
}

main "$@"

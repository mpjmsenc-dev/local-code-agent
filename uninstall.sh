#!/usr/bin/env bash
# uninstall.sh — remove the local-code-agent stack from this machine.
#
# Removes: Ollama (including ALL downloaded models), the Open WebUI container
# (and its data volume unless --keep-data), the boot services (auto-tune +
# netmode), any netmode egress lockdown, and the project virtualenv.
# Keeps:   Docker Engine, Tailscale, git, this repository and your .env
#          (delete the repo directory yourself to finish the job).
#
# Usage: sudo ./uninstall.sh [--yes] [--keep-data]
#   --yes        don't ask for confirmation (REQUIRED when non-interactive)
#   --keep-data  keep the 'open-webui' docker volume (accounts + chats)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
load_env

usage() {
  # Print this file's header comment block (lines 2-12) as the help text.
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local force=false keep_data=false arg
  for arg in "$@"; do
    case "${arg}" in
      --yes) force=true ;;
      --keep-data) keep_data=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown option: ${arg}" ;;
    esac
  done

  step "Uninstalling local-code-agent"
  if [[ "${force}" != "true" ]]; then
    # confirm() auto-answers yes when non-interactive, which is right for
    # installs but far too dangerous here — demand an explicit --yes instead.
    if [[ ! -t 0 ]]; then
      die "Refusing to uninstall non-interactively without --yes (this removes Ollama, all models, and WebUI data)."
    fi
    confirm "Remove Ollama (incl. ALL models), the WebUI container and its data, and the boot services?" \
      || die "Uninstall cancelled — nothing was changed."
  fi

  # 1. Lift the netmode nftables tables so nothing stays firewalled.
  if have nft; then
    if as_root nft list table inet lca_netmode >/dev/null 2>&1; then
      as_root nft delete table inet lca_netmode
      ok "Netmode egress lockdown removed."
    fi
    if as_root nft list table inet lca_inbound >/dev/null 2>&1; then
      as_root nft delete table inet lca_inbound
      ok "Inbound guard removed."
    fi
  fi

  # 2. Boot services + persisted netmode state.
  if systemd_available; then
    as_root systemctl disable --now local-code-agent-tune.service >/dev/null 2>&1 || true
    as_root systemctl disable --now local-code-agent-netmode.service >/dev/null 2>&1 || true
    as_root systemctl disable --now local-code-agent-backup.timer >/dev/null 2>&1 || true
  fi
  as_root rm -f /etc/systemd/system/local-code-agent-tune.service \
                /etc/systemd/system/local-code-agent-netmode.service \
                /etc/systemd/system/local-code-agent-backup.timer \
                /etc/systemd/system/local-code-agent-backup.service
  as_root rm -rf "${NETMODE_DIR}"
  ok "Boot services and netmode state removed."

  # 3. Open WebUI.
  if have docker; then
    if as_root docker container inspect "${WEBUI_CONTAINER}" >/dev/null 2>&1; then
      as_root docker rm -f "${WEBUI_CONTAINER}" >/dev/null
      ok "WebUI container '${WEBUI_CONTAINER}' removed."
    fi
    if [[ "${keep_data}" == "true" ]]; then
      info "Keeping the 'open-webui' data volume (--keep-data)."
    elif as_root docker volume inspect open-webui >/dev/null 2>&1; then
      as_root docker volume rm open-webui >/dev/null
      ok "WebUI data volume removed."
    fi
  fi

  # 4. Ollama — service, drop-in, binary, libraries, models, user.
  if systemd_available; then
    as_root systemctl disable --now ollama >/dev/null 2>&1 || true
  fi
  as_root rm -rf /etc/systemd/system/ollama.service.d
  as_root rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama
  as_root rm -rf /usr/local/lib/ollama /usr/share/ollama
  if id ollama >/dev/null 2>&1; then
    as_root userdel ollama 2>/dev/null || true
  fi
  if getent group ollama >/dev/null 2>&1; then
    as_root groupdel ollama 2>/dev/null || true
  fi
  if systemd_available; then
    as_root systemctl daemon-reload
  fi
  ok "Ollama removed (including all downloaded models)."

  # 5. Project virtualenv.
  local venv
  venv="$(venv_dir)"
  if [[ -d "${venv}" ]]; then
    rm -rf "${venv}"
    ok "Virtualenv ${venv} removed."
  fi

  # 6. The 'lca' command on PATH — but only if it points at THIS checkout, so a
  # second install elsewhere is never silently disarmed by this uninstall.
  if [[ -L /usr/local/bin/lca ]]; then
    local lca_target
    lca_target="$(readlink -f /usr/local/bin/lca 2>/dev/null || true)"
    if [[ "${lca_target}" == "${SCRIPT_DIR}/bin/lca" ]]; then
      as_root rm -f /usr/local/bin/lca
      ok "'lca' command removed."
    else
      info "/usr/local/bin/lca points elsewhere (${lca_target:-unknown}) — leaving it alone."
    fi
  fi

  # 7. Generated state outside the repo: run-agent.sh writes an aider
  # model-metadata file under ~/.cache. Under sudo, $HOME is root's, while the
  # file was written by the human's own run — clean up both.
  local cache_dirs=( "${HOME}/.cache/local-code-agent" ) sudo_home d
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${sudo_home:-}" ]] && cache_dirs+=( "${sudo_home}/.cache/local-code-agent" )
  fi
  for d in "${cache_dirs[@]}"; do
    if [[ -d "${d}" ]]; then
      rm -rf "${d}"
      ok "Removed generated cache ${d}."
    fi
  done

  step "Uninstall complete"
  info "Kept on purpose: Docker Engine, Tailscale, git, this repository and .env."
  info "To finish completely:  sudo tailscale logout   and delete this directory:  ${REPO_ROOT}"
}

main "$@"

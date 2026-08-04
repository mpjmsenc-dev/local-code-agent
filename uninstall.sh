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
  # Print this file's header comment block as the help text — read to the
  # first non-comment line, so editing the header cannot truncate it.
  sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
}

# report_ollama_removal WAS_INSTALLED — say what actually happened, having
# looked, rather than announcing the outcome the code hoped for.
#
# The line this replaces printed unconditionally. It said "Ollama removed
# (including all downloaded models)" on a machine where Ollama was never
# installed, and — worse — on one where it still is: the official installer
# picks the first writable directory on PATH, so a host where /usr/local/bin
# was not writable has the binary somewhere none of the rm's above name. Being
# told the thing is gone when it still starts on every boot is the kind of
# wrong that only surfaces months later.
#
# Its own function so all three answers can be exercised without uninstalling
# anything — the same reason restore.sh's machine_advice is one.
report_ollama_removal() {
  # bash caches command locations; without this the check reports on a binary
  # that was removed a few lines ago.
  hash -r 2>/dev/null || true
  if [[ "${1:-false}" != "true" ]]; then
    info "Ollama was not installed here — nothing to remove."
  elif have ollama; then
    warn "Ollama is STILL on PATH at $(command -v ollama) — that copy lives somewhere this script does not manage (it removes /usr/local/bin/ollama, /usr/local/lib/ollama and /usr/share/ollama). Remove it yourself if you meant to; its models are still on disk."
  else
    ok "Ollama removed (including all downloaded models)."
  fi
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
    # The prompt must describe what THIS invocation will do. It said "and its
    # data" unconditionally, which is wrong whenever --keep-data was passed —
    # and a destructive confirmation that overstates the damage is worse than
    # it sounds: it either gets someone to cancel a safe uninstall, or it
    # teaches them that this prompt exaggerates.
    local data_clause="and its data"
    if [[ "${keep_data}" == "true" ]]; then
      data_clause="(keeping its data — --keep-data)"
    fi
    confirm "Remove Ollama (incl. ALL models), the WebUI container ${data_clause}, and the boot services?" \
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

  # Homes to clean. Under sudo, ${HOME} is root's while the files that matter
  # were written by the human's own runs, so both are in scope. Computed here
  # because two later steps need the same list.
  local homes=( "${HOME:-/root}" ) sudo_home d
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${sudo_home:-}" && "${sudo_home}" != "${HOME:-}" ]] && homes+=( "${sudo_home}" )
  fi

  # 4. Ollama — service, drop-in, binary, libraries, models, user.
  local ollama_was_installed=false
  have ollama && ollama_was_installed=true
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
  # Models live wherever the SERVER ran. Under systemd that is the 'ollama'
  # system account, whose home (/usr/share/ollama) went with the line above.
  # Without systemd — containers and WSL, where install_ollama.sh deliberately
  # falls back to start_ollama_bg — the server runs as the invoking user and
  # every blob lands in THEIR home instead. Nothing touched that, so the
  # confirmation prompt promised "incl. ALL models" and then left the
  # gigabytes behind on exactly the hosts this project supports specially.
  for d in "${homes[@]}"; do
    [[ -d "${d}/.ollama" ]] || continue
    as_root rm -rf "${d}/.ollama"
    ok "Removed ${d}/.ollama (where models go when Ollama runs without systemd)."
  done
  if systemd_available; then
    as_root systemctl daemon-reload
  fi
  report_ollama_removal "${ollama_was_installed}"

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

  # 6b. The login banner, on the same "only if it is ours" rule — otherwise a
  # second checkout's banner would be removed by this one's uninstall. Left
  # behind, it would print a banner for a stack that no longer exists.
  if [[ -L "${MOTD_FILE}" ]]; then
    local motd_target
    motd_target="$(readlink -f "${MOTD_FILE}" 2>/dev/null || true)"
    if [[ "${motd_target}" == "${SCRIPT_DIR}/scripts/motd.sh" ]]; then
      as_root rm -f "${MOTD_FILE}"
      ok "Login banner removed."
    else
      info "${MOTD_FILE} points elsewhere (${motd_target:-unknown}) — leaving it alone."
    fi
  fi

  # 7. Generated state outside the repo: run-agent.sh writes an aider
  # model-metadata file under ~/.cache. Same two homes as the model blobs
  # above, for the same reason — under sudo, ${HOME} is root's while the file
  # was written by the human's own run.
  for d in "${homes[@]}"; do
    if [[ -d "${d}/.cache/local-code-agent" ]]; then
      as_root rm -rf "${d}/.cache/local-code-agent"
      ok "Removed generated cache ${d}/.cache/local-code-agent."
    fi
  done

  step "Uninstall complete"
  info "Kept on purpose: Docker Engine, Tailscale, git, this repository and .env."
  info "To finish completely:  sudo tailscale logout   and delete this directory:  ${REPO_ROOT}"
}

# Sourceable so report_ollama_removal can be tested without uninstalling
# anything — same pattern as restore.sh, scripts/apply.sh and scripts/tune.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

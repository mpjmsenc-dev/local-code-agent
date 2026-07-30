#!/usr/bin/env bash
# scripts/install_ollama.sh — install Ollama (official installer), configure
# it via a systemd drop-in rendered from .env + config/ollama.env, and verify
# the API answers. Idempotent: an existing install is reused and reconfigured.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

main() {
  step "Installing Ollama"
  require_cmd curl

  # Reuse an existing binary only if it came with the systemd unit the rest
  # of this script configures. A binary without ollama.service (interrupted
  # first install, or a manual tarball install) would otherwise skip the
  # installer and then fail on 'systemctl enable ollama'. Re-running the
  # official installer is itself idempotent and creates the missing unit.
  local need_install=false
  if ! have ollama; then
    need_install=true
  elif systemd_available && ! systemctl cat ollama >/dev/null 2>&1; then
    warn "Ollama binary present but no ollama.service unit (interrupted or manual install) — re-running the official installer to create it."
    need_install=true
  fi

  if [[ "${need_install}" == "true" ]]; then
    net_guard "Installing Ollama"
    # The official installer unpacks a zstd-compressed tarball; without the
    # zstd CLI it aborts with "requires zstd for extraction". setup.sh installs
    # it via dependencies, but guard standalone runs on minimal systems too.
    if ! have zstd && have apt-get; then
      info "Installing zstd (required to unpack the Ollama release)..."
      apt_get install -y zstd || warn "Could not install zstd — the Ollama installer may fail to unpack."
    fi
    info "Running the official Ollama installer..."
    curl -fsSL https://ollama.com/install.sh | as_root sh
    require_cmd ollama
    ok "Ollama installed."
  else
    info "Ollama already installed ($(ollama --version 2>/dev/null || echo 'version unknown')) — reusing and reconfiguring it."
  fi

  if ! systemd_available; then
    warn "systemd not available — cannot configure the ollama service here."
    warn "Start Ollama manually with: OLLAMA_HOST=${OLLAMA_HOST} ollama serve"
    exit 0
  fi

  info "Writing systemd drop-in with settings from .env and config/ollama.env..."
  render_ollama_dropin
  as_root systemctl daemon-reload
  as_root systemctl enable --now ollama
  as_root systemctl restart ollama

  info "Waiting for the Ollama API..."
  wait_for_ollama 90 || die "Ollama API did not come up at $(ollama_url). Inspect it with: sudo systemctl status ollama"

  # Assert our unit is the thing answering — a stray 'ollama serve' on 11434
  # would answer the probe while the systemd unit crash-loops on the bind.
  if ! systemctl is-active --quiet ollama 2>/dev/null; then
    die "The Ollama API answers but the ollama systemd service is not active — another process may hold port 11434. See docs/TROUBLESHOOTING.md (Port 11434 already in use)."
  fi

  local version
  # '|| true' applies to the whole pipeline: if curl itself fails (service
  # crash right after it first answered), the [[ -n ]] check below emits the
  # intended diagnostic instead of set -e aborting with no message.
  version="$(curl -fsS --max-time 5 "$(ollama_url)/api/version" 2>/dev/null | jq -r '.version // empty' || true)"
  [[ -n "${version}" ]] || die "Ollama API answered but returned no version — something is wrong; check: journalctl -u ollama"
  ok "Ollama ${version} is running at $(ollama_url)"
}

main "$@"

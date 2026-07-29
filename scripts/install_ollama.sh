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

  if have ollama; then
    info "Ollama already installed ($(ollama --version 2>/dev/null || echo 'version unknown')) — reusing and reconfiguring it."
  else
    net_guard "Installing Ollama"
    info "Running the official Ollama installer..."
    curl -fsSL https://ollama.com/install.sh | as_root sh
    require_cmd ollama
    ok "Ollama installed."
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

  local version
  version="$(curl -fsS --max-time 5 "$(ollama_url)/api/version" | { jq -r '.version // empty' || true; })"
  [[ -n "${version}" ]] || die "Ollama API answered but returned no version — something is wrong; check: journalctl -u ollama"
  ok "Ollama ${version} is running at $(ollama_url)"
}

main "$@"

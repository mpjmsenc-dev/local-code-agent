#!/usr/bin/env bash
# scripts/install_tailscale.sh — install Tailscale (official installer) for
# private phone access. Login ('tailscale up') needs a human to tap a URL,
# so it is deliberately deferred — unattended installs never block here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

main() {
  step "Installing Tailscale"
  # Symmetric with SKIP_DOCKER. Installing a second VPN on a machine that
  # already has WireGuard, ZeroTier, or is simply LAN-only is presumptuous —
  # Tailscale is how THIS project offers private phone access, not the only
  # way to have it.
  if [[ "${SKIP_TAILSCALE}" == "true" ]]; then
    warn "SKIP_TAILSCALE=true — not installing Tailscale."
    info "Phone access then needs a private network you provide (WireGuard, ZeroTier, a LAN)."
    info "The inbound guard still restricts the WebUI port to loopback and tailscale0, so reach it over your own network or adjust the guard deliberately."
    return 0
  fi
  require_cmd curl

  if have tailscale; then
    info "Tailscale already installed ($(tailscale version 2>/dev/null | head -1 || true)) — reusing it."
  else
    net_guard "Installing Tailscale"
    info "Running the official Tailscale installer..."
    curl -fsSL https://tailscale.com/install.sh | as_root sh
    require_cmd tailscale
    ok "Tailscale installed."
  fi

  if systemd_available; then
    as_root systemctl enable --now tailscaled
    ok "tailscaled service enabled and running."
  else
    warn "systemd not available — start tailscaled yourself before running 'tailscale up'."
  fi

  if tailscale status >/dev/null 2>&1; then
    ok "Tailscale is already logged in. This machine's Tailscale IPv4: $(tailscale ip -4 2>/dev/null | head -1 || echo 'unknown')"
  else
    warn "Tailscale is installed but NOT logged in yet (expected on first boot)."
    info "When you're ready, run:  sudo tailscale up   — then open the printed URL to log in. See docs/PHONE.md."
  fi
}

main "$@"

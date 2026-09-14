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
    # Retried, for the reason install_ollama.sh records beside its own copy of
    # this: a transient reset while a remote installer is being streamed into a
    # shell fails the whole pipeline, and this one was bare — 'curl | sh' under
    # 'set -o pipefail', so a blip exited the script with no message at all.
    # The official installer is idempotent, so repeating a partial attempt is
    # safe.
    local attempt ts_ok=false
    for attempt in 1 2 3; do
      if curl -fsSL https://tailscale.com/install.sh | as_root sh; then
        ts_ok=true
        break
      fi
      if (( attempt < 3 )); then
        warn "Tailscale download/install attempt ${attempt}/3 failed (transient network?) — retrying in $((attempt * 5))s..."
        sleep "$((attempt * 5))"
      fi
    done
    [[ "${ts_ok}" == "true" ]] \
      || die "The Tailscale installer failed 3 times — check connectivity (curl -I https://tailscale.com) and whether netmode is offline: ${REPO_ROOT}/netmode.sh status"
    require_cmd tailscale
    ok "Tailscale installed."
  fi

  if systemd_available; then
    # Not bare: an enable that fails leaves the binary installed and perfectly
    # usable by hand, so it is a warning about phone access, not a reason to
    # stop an install that has already put the whole terminal stack in place.
    if as_root systemctl enable --now tailscaled; then
      ok "tailscaled service enabled and running."
    else
      warn "Tailscale is installed but its service would not start — phone access will not work until it does. Look at: sudo systemctl status tailscaled"
      return 0
    fi
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

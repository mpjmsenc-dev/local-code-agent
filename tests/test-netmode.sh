#!/usr/bin/env bash
# tests/test-netmode.sh — validate the netmode OFFLINE ruleset without ever
# applying it:
#   1. content assertions: the safety-critical rules must be present
#   2. kernel validation: nft --check parses and evaluates the ruleset in
#      check-only mode (nothing is loaded)
# Needs root (or sudo) + nft for step 2; degrades to a clear skip otherwise.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"

FAILED=0
t_ok()   { printf '%s\n' "ok   - $*"; }
t_fail() { printf '%s\n' "FAIL - $*"; FAILED=$((FAILED+1)); }

RULES="$(mktemp)"
INBOUND="$(mktemp)"
trap 'rm -rf "${RULES}" "${INBOUND}"' EXIT
"${REPO}/netmode.sh" render-rules > "${RULES}"
"${REPO}/netmode.sh" render-inbound > "${INBOUND}"

contains() {  # desc file needle
  if grep -qF "$3" "$2"; then t_ok "$1"; else t_fail "$1 — missing: $3"; fi
}
absent() {    # desc file pattern
  if grep -qE "$3" "$2"; then t_fail "$1 — unexpectedly present: $3"; else t_ok "$1"; fi
}

echo "# stdout purity: render-* must emit nft syntax and nothing else"
# (CI caught load_env's '[info] Created .env' notice leaking into the rules
# on a fresh checkout — this guards against any such stdout contamination.)
shebang_ok() {  # desc file
  if [[ "$(head -1 "$2")" == "#!/usr/sbin/nft -f" ]]; then
    t_ok "$1"
  else
    t_fail "$1 (got: $(head -1 "$2"))"
  fi
}
shebang_ok "offline ruleset first line is the nft shebang" "${RULES}"
shebang_ok "inbound ruleset first line is the nft shebang" "${INBOUND}"

echo "# OFFLINE egress: the Tailscale path must never be cut"
contains "loopback egress allowed"          "${RULES}" 'oifname "lo" accept'
contains "tailscale0 egress allowed"        "${RULES}" 'oifname "tailscale0" accept'
contains "tailscaled fwmark allowed"        "${RULES}" 'meta mark & 0x00ff0000 == 0x00080000 accept'
contains "WireGuard port allowed"           "${RULES}" 'udp dport 41641 accept'
contains "established replies allowed"       "${RULES}" 'ct state established,related accept'
contains "new outbound connections dropped" "${RULES}" 'ct state new counter drop'

echo "# OFFLINE also covers forwarded (docker-bridge) traffic"
contains "forward hook present"             "${RULES}" 'hook forward'
contains "forward allows tailscale0"        "${RULES}" 'oifname "tailscale0" accept'

echo "# INBOUND guard: private-only services, SSH untouched"
contains "inbound input hook present"       "${INBOUND}" 'type filter hook input'
contains "inbound allows loopback"          "${INBOUND}" 'iifname "lo" accept'
contains "inbound allows tailscale0"        "${INBOUND}" 'iifname "tailscale0" accept'
contains "inbound drops the service ports"  "${INBOUND}" 'ct state new counter drop'
contains "inbound targets tcp dport set"    "${INBOUND}" 'tcp dport {'
# SSH (22) must never appear in the inbound guard — proves it can't lock you out.
absent  "inbound never filters SSH (22)"    "${INBOUND}" '(\{|[[:space:],]|dport )22([[:space:],]|\})'

echo "# rule ORDER: in every chain the drop is the last rule (no dead accepts after it)"
order_ok() {  # desc file
  if awk '
    /ct state new counter drop/ { dropped=1; next }
    dropped && /accept/         { bad=1 }
    dropped && /}/              { dropped=0 }
    END { exit bad?1:0 }
  ' "$2"; then
    t_ok "$1"
  else
    t_fail "$1 (an accept follows a drop — dead rule)"
  fi
}
order_ok "offline: drop is the last rule in every chain" "${RULES}"
order_ok "inbound: drop is the last rule in every chain" "${INBOUND}"

echo "# kernel validation via nft --check (nothing is applied)"
NFT=()
if command -v nft >/dev/null 2>&1; then
  if [[ "${EUID}" -eq 0 ]]; then
    NFT=(nft)
  elif command -v sudo >/dev/null 2>&1; then
    NFT=(sudo -n nft)
  fi
fi
nft_check() {  # desc file
  if "${NFT[@]}" --check -f "$2"; then t_ok "$1"; else t_fail "$1"; fi
}
if [[ "${#NFT[@]}" -eq 0 ]]; then
  echo "skip - nft (as root) not available; content checks above still ran"
else
  nft_check "nft --check accepts the offline ruleset" "${RULES}"
  nft_check "nft --check accepts the inbound ruleset" "${INBOUND}"
fi

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all netmode tests passed"

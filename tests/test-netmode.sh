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
trap 'rm -rf "${RULES}"' EXIT
"${REPO}/netmode.sh" render-rules > "${RULES}"

echo "# stdout purity: render-rules must emit nft syntax and nothing else"
# (CI caught load_env's '[info] Created .env' notice leaking into the rules
# on a fresh checkout — this guards against any such stdout contamination.)
if [[ "$(head -1 "${RULES}")" == "#!/usr/sbin/nft -f" ]]; then
  t_ok "first line is the nft shebang"
else
  t_fail "unexpected first line: $(head -1 "${RULES}")"
fi

echo "# safety-critical rules are present (the Tailscale path must never be cut)"
must_contain() {
  local desc="$1" needle="$2"
  if grep -qF "${needle}" "${RULES}"; then
    t_ok "${desc}"
  else
    t_fail "${desc} — missing: ${needle}"
  fi
}
must_contain "loopback always allowed"          'oifname "lo" accept'
must_contain "tailscale0 always allowed"        'oifname "tailscale0" accept'
must_contain "tailscaled fwmark traffic allowed" 'meta mark & 0x00ff0000 == 0x00080000 accept'
must_contain "WireGuard port allowed"           'udp dport 41641 accept'
must_contain "established replies allowed"      'ct state established,related accept'
must_contain "new outbound connections dropped" 'ct state new counter drop'

echo "# rule ORDER: every accept must come before the final drop"
drop_line="$(grep -n 'ct state new counter drop' "${RULES}" | cut -d: -f1 | head -1)"
last_accept="$(grep -n ' accept$' "${RULES}" | cut -d: -f1 | sort -n | tail -1)"
if [[ -n "${drop_line}" && -n "${last_accept}" ]] && (( last_accept < drop_line )); then
  t_ok "all accepts precede the drop"
else
  t_fail "an accept rule appears after the drop (would be dead)"
fi

echo "# kernel validation via nft --check (nothing is applied)"
NFT=()
if command -v nft >/dev/null 2>&1; then
  if [[ "${EUID}" -eq 0 ]]; then
    NFT=(nft)
  elif command -v sudo >/dev/null 2>&1; then
    NFT=(sudo -n nft)
  fi
fi
if [[ "${#NFT[@]}" -eq 0 ]]; then
  echo "skip - nft (as root) not available; content checks above still ran"
elif "${NFT[@]}" --check -f "${RULES}"; then
  t_ok "nft --check accepts the ruleset"
else
  t_fail "nft --check rejected the ruleset"
fi

echo
if (( FAILED > 0 )); then
  echo "RESULT: ${FAILED} test(s) FAILED"
  exit 1
fi
echo "RESULT: all netmode tests passed"

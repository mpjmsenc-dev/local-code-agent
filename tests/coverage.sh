#!/usr/bin/env bash
# tests/coverage.sh — which lib.sh functions does nothing test?
#
# Not a gate. A report, run by hand ('make coverage') when you want to know
# where the suites are not looking. It exists because two functions that write
# the firewall's ruleset turned out never to have been EXECUTED by a test —
# only grepped — and nothing said so. The question "what does nothing test?"
# should be answerable in one command rather than by noticing.
#
# Method: run each suite with xtrace and a PS4 that stamps the current function
# name, then subtract what ran from what is defined.
#
# Two things this deliberately does NOT claim:
#
#   - it measures functions EXECUTED IN THE SUITE'S OWN SHELL. The house style
#     for a behavioural test is a child 'bash -c' with stubs, and a child shell
#     resets PS4, so everything tested that way is invisible here. The raw
#     subtraction listed 38 functions on a suite that genuinely exercises most
#     of them. So the report cross-references tests/ for the name too, and only
#     reports what is neither run nor mentioned.
#   - a name appearing in tests/ is not proof of a test. It is proof that the
#     raw list would have been misleading, which is all this filter is for.
#
# Calibrate before believing it: the self-check below runs a fixture where one
# function is called and one is not, and refuses to report if the instrument
# cannot tell them apart. The first version of this silently traced nothing —
# PS4 is reset at shell startup, so passing it in the environment does nothing —
# and reported all 89 functions as uncovered, which reads exactly like a
# catastrophic result rather than a broken tool.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# trace_functions SCRIPT — the set of function names that ran while SCRIPT did.
trace_functions() {
  local target="$1"
  cat > "${WORK}/runner.sh" <<'RUNNER'
cd "$1" || exit 1
PS4='@@${FUNCNAME[0]:-TOP}@@ '
set -x
# shellcheck disable=SC1090
. "$2"
RUNNER
  bash "${WORK}/runner.sh" "${REPO}" "${target}" >/dev/null 2>"${WORK}/trace" || true
  # '|| true': no matches is a legitimate answer here (and the one a broken
  # tracer gives), but grep exits 1 for it — which under errexit aborts the
  # ASSIGNMENT in the caller, killing the script before the calibration guard
  # below can say what went wrong. Verified: without this, blinding the tracer
  # produced exit 1 and not one word of explanation.
  grep -oE '@@[A-Za-z_][A-Za-z0-9_]*@@' "${WORK}/trace" | tr -d '@' | sort -u || true
}

# --- calibration: the instrument must distinguish called from not-called -----
cat > "${WORK}/fixture.sh" <<'FIXTURE'
coverage_fixture_called()     { :; }
coverage_fixture_not_called() { :; }
coverage_fixture_called
FIXTURE
cal="$(trace_functions "${WORK}/fixture.sh")" || true
if ! grep -qx 'coverage_fixture_called' <<<"${cal}"; then
  echo "coverage.sh: the tracer saw nothing — refusing to report a result it cannot measure" >&2
  exit 1
fi
if grep -qx 'coverage_fixture_not_called' <<<"${cal}"; then
  echo "coverage.sh: the tracer reports uncalled functions as called — result would be meaningless" >&2
  exit 1
fi

# --- the real measurement ---------------------------------------------------
{
  trace_functions "${REPO}/tests/test-lib.sh"
  trace_functions "${REPO}/tests/test-netmode.sh"
} | sort -u > "${WORK}/ran"
grep -oE '^[a-z_][a-z0-9_]*\(\)' "${REPO}/scripts/lib.sh" | tr -d '()' | sort -u > "${WORK}/defined"

printf 'lib.sh functions defined:            %s\n' "$(wc -l < "${WORK}/defined")"
printf 'run directly by a suite:             %s\n' \
  "$(comm -12 "${WORK}/defined" "${WORK}/ran" | wc -l)"

untouched=()
while read -r fn; do
  [[ -n "${fn}" ]] || continue
  grep -q "\b${fn}\b" "${REPO}"/tests/*.sh || untouched+=("${fn}")
done < <(comm -23 "${WORK}/defined" "${WORK}/ran")

if (( ${#untouched[@]} == 0 )); then
  echo
  echo "Every lib.sh function is either executed by a suite or named in one."
  exit 0
fi
printf 'neither run nor named in tests/:     %s\n\n' "${#untouched[@]}"
echo "No test touches these at all:"
printf '  %s\n' "${untouched[@]}"

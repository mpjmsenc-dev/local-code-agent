#!/usr/bin/env bash
# tests/in-container.sh — run a make target (default: gates) inside a throwaway
# Ubuntu 24.04 container, against a copy of THIS checkout as it is on disk.
#
# WHY THIS EXISTS. On 2026-09-14 the unit suite, run as root on the droplet it
# was written on, drove setup.sh with one host path redirected and wrote the
# rest for real: /usr/local/bin/lca and both boot units, pointed into a mktemp
# directory the suite then deleted. The netmode unit failed at the next boot, the
# inbound guard was not loaded, and the chat app was on a public address for
# fifty-five minutes while every report read green. LCA_HOST_ROOT now moves
# every host path and the escape check watches all of them — but the rule that
# came out of it does not depend on that work being perfect: gates run where a
# mistake costs a container, not a machine. CONTRIBUTING, "Where the gates run".
#
# What is copied: the repository's history (for the gates that read commit
# messages), then every tracked and untracked-but-not-ignored file as it is on
# disk, then tracked files deleted on disk are deleted in the copy. So what is
# tested is the working tree, not the last commit.
#
# Usage: tests/in-container.sh [make-target]
#   LCA_GATES_OUT=DIR     where the log goes (default: a new mktemp dir, printed)
#   LCA_GATES_MEMORY=4g   a memory limit, which is also the RAM the product
#                         detects inside it (detect_ram_gib reads the cgroup)
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
IMAGE="${LCA_GATES_IMAGE:-lca-gates:24.04}"
TARGET="${1:-gates}"
OUT="${LCA_GATES_OUT:-$(mktemp -d)}"
mkdir -p "${OUT}"

case "${TARGET}" in
  -h|--help)
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'
    exit 0 ;;
esac

command -v docker >/dev/null 2>&1 || { echo "docker is not installed; the gates cannot run in a container here." >&2; exit 2; }
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Building ${IMAGE} from tests/gates.Containerfile (once)..."
  docker build -t "${IMAGE}" -f "${TESTS_DIR}/gates.Containerfile" "${TESTS_DIR}"
fi

limit=()
[[ -z "${LCA_GATES_MEMORY:-}" ]] || limit=(--memory "${LCA_GATES_MEMORY}" --memory-swap "${LCA_GATES_MEMORY}")

echo "Running 'make ${TARGET}' in ${IMAGE}; log: ${OUT}/gates.log"
rc=0
# shellcheck disable=SC2016  # the container's script, expanded in the container
docker run --rm "${limit[@]}" \
  -v "${REPO}:/src:ro" -v "${OUT}:/out" "${IMAGE}" bash -c '
    set -uo pipefail
    git config --global --add safe.directory "*"
    git config --global user.email gates@container.invalid
    git config --global user.name gates
    git clone -q /src /work/repo || exit 3
    ( cd /src && git ls-files -z --cached --others --exclude-standard ) \
      | ( cd /src && tar --null --ignore-failed-read -T - -cf - 2>/dev/null ) \
      | tar -C /work/repo -xf - || exit 3
    ( cd /src && git ls-files -z --deleted ) | ( cd /work/repo && xargs -0 -r rm -f -- )
    cd /work/repo && make "$1"; rc=$?
    cp /work/repo/.git/lca-suite-runs /out/suite-runs 2>/dev/null || true
    exit "${rc}"
  ' _ "${TARGET}" > "${OUT}/gates.log" 2>&1 || rc=$?
echo "EXIT:${rc}" >> "${OUT}/gates.log"
# The container's record of the run, carried back to this checkout so a commit
# of the same tree can cite it (.githooks/commit-msg). The container's copy of
# the repository is gone when it exits; without this the run left no trace.
if [[ -s "${OUT}/suite-runs" ]]; then
  cat "${OUT}/suite-runs" >> "$(git -C "${REPO}" rev-parse --absolute-git-dir)/lca-suite-runs"
  echo "Recorded in .git/lca-suite-runs: $(tail -1 "${OUT}/suite-runs")"
else
  echo "No suite run was recorded — the suite did not reach its verdict."
fi
tail -3 "${OUT}/gates.log"
exit "${rc}"

#!/usr/bin/env bash
# tests/memory-preflight.sh — refuse to START the gates on a box that cannot
# hold them, and say what to unload.
#
# WHY. ShellCheck over tests/test-lib.sh needs about 3.8 GB, and the kernel's
# OOM record on the development droplet shows it killed at 3.76 GB resident and
# still growing. That box has 7.9 GB, and a resident Ollama model (2.7 GB for
# the 3b agent model) plus the chat and agent containers left too little. Two
# full gate runs were lost that way, each twenty minutes in, each ending in
# "Killed" and exit 2 — a result that reads like a failure of the code under
# test and is a failure of the machine. A run that cannot finish should not
# start, and the reason it cannot should be the first thing it prints.
#
# Usage: tests/memory-preflight.sh [NEEDED_MB]
#   NEEDED_MB defaults to LCA_GATES_MIN_MEM_MB, else 4500 (the measured peak
#   above, plus room for the shell and git around it).
#
# Seams, so tests/test-lib.sh can drive both answers without a small machine:
#   LCA_MEMINFO        a file in /proc/meminfo's format        (default /proc/meminfo)
#   LCA_OLLAMA_PS_JSON Ollama's /api/ps answer, instead of asking the server
#   LCA_PREFLIGHT_NO_DOCKER=1   do not ask docker what is using memory
#
# Exit: 0 enough memory; 3 refused (nothing was run); 2 could not tell.
set -uo pipefail

need="${1:-${LCA_GATES_MIN_MEM_MB:-4500}}"
meminfo="${LCA_MEMINFO:-/proc/meminfo}"
[[ "${need}" =~ ^[0-9]+$ ]] || { echo "memory-preflight: '${need}' is not a number of MB" >&2; exit 2; }

avail="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' "${meminfo}" 2>/dev/null)"
# Inside a memory-limited container the limit, not the host, is what there is.
if [[ -z "${LCA_MEMINFO:-}" && -r /sys/fs/cgroup/memory.max ]]; then
  lim="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
  cur="$(cat /sys/fs/cgroup/memory.current 2>/dev/null)"
  if [[ "${lim}" =~ ^[0-9]+$ && "${cur}" =~ ^[0-9]+$ ]]; then
    room=$(( (lim - cur) / 1048576 ))
    (( room < avail )) && avail="${room}"
  fi
fi
[[ "${avail}" =~ ^[0-9]+$ ]] || {
  echo "memory-preflight: could not read available memory from ${meminfo}, so whether the gates fit is UNKNOWN — not a pass" >&2
  exit 2
}

if (( avail >= need )); then
  echo "memory - ${avail} MB available, ${need} MB needed"
  exit 0
fi

{
  echo "memory-preflight: REFUSED — ${avail} MB available and the gates need about ${need} MB."
  echo "ShellCheck alone peaks near 3.8 GB on tests/test-lib.sh; started now it is killed partway and the run ends in 'Killed', which looks like a code failure."
  echo
  echo "What is holding memory, and how to free it:"
  models="${LCA_OLLAMA_PS_JSON:-$(curl -s --max-time 2 http://127.0.0.1:11434/api/ps 2>/dev/null || true)}"
  if command -v jq >/dev/null 2>&1 && [[ -n "${models}" ]]; then
    listed="$(jq -r '.models[]? | "\(.name)\t\((.size // 0) / 1048576 | floor)"' <<<"${models}" 2>/dev/null || true)"
    if [[ -n "${listed}" ]]; then
      while IFS=$'\t' read -r name mb; do
        [[ -n "${name}" ]] || continue
        echo "  Ollama model ${name} (${mb} MB resident). Unload it — it reloads on the next request:"
        echo "    curl -s http://127.0.0.1:11434/api/generate -d '{\"model\":\"${name}\",\"keep_alive\":0}'"
      done <<<"${listed}"
    else
      echo "  No Ollama model is resident."
    fi
  else
    echo "  (could not ask Ollama which models are resident)"
  fi
  if [[ "${LCA_PREFLIGHT_NO_DOCKER:-}" != "1" ]] && command -v docker >/dev/null 2>&1; then
    stats="$(timeout 10 docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' 2>/dev/null || true)"
    [[ -z "${stats}" ]] || printf '  Containers:\n    %s\n' "${stats//$'\n'/$'\n    '}"
  fi
  echo "  Largest processes:"
  ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -5 | awk '{ printf "    %6d MB  %s\n", $1 / 1024, $2 }'
  echo
  echo "RESULT: REFUSED — no gate was run. Free memory and run again, or set LCA_GATES_MIN_MEM_MB if you know better."
} >&2
exit 3

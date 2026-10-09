#!/usr/bin/env bash
# tests/memory-preflight.sh — refuse to START the gates on a box that cannot
# hold them, and say what to unload; and after a run that died partway, say
# whether the machine killed it.
#
# WHY. ShellCheck over tests/test-lib.sh needs about 3.8 GB, and the kernel's
# OOM record on the development droplet shows it killed at 3.76 GB resident and
# still growing. That box has 7.9 GB, and a resident Ollama model (2.7 GB for
# the 3b agent model) plus the chat and agent containers left too little. Two
# full gate runs were lost that way, each twenty minutes in, each ending in
# "Killed" and exit 2 — a result that reads like a failure of the code under
# test and is a failure of the machine. A run that cannot finish should not
# start, and the reason it cannot should be the first thing it prints. A run
# that is killed anyway — a model loaded halfway through — should end by saying
# so, from the kernel's own record, rather than leaving somebody to go and find
# "Out of memory: Killed process ... (shellcheck)" in the journal by hand.
#
# Usage: tests/memory-preflight.sh [NEEDED_MB]
#          before a run. NEEDED_MB defaults to LCA_GATES_MIN_MEM_MB, else 4500
#          (the measured ShellCheck peak above, plus room for the shell and git
#          around it). tests/in-container.sh asks for a whole run's worth first.
#        tests/memory-preflight.sh --killed LOG RC [CONTAINER_ID] [SINCE_EPOCH]
#          after one. LOG and RC are the run's log and exit status. The kernel
#          names the killed task's cgroup, so CONTAINER_ID attributes a record
#          to this run and no other; SINCE_EPOCH bounds the journal search.
#
# Seams, so tests/test-lib.sh can drive every answer without a small machine
# and without killing anything:
#   LCA_MEMINFO        a file in /proc/meminfo's format        (default /proc/meminfo)
#   LCA_OLLAMA_PS_JSON Ollama's /api/ps answer, instead of asking the server
#   LCA_PREFLIGHT_NO_DOCKER=1   do not ask docker what is using memory
#   LCA_KERNEL_LOG     a file of kernel log lines, instead of journalctl / dmesg
#
# Exit, before: 0 enough memory; 3 refused (nothing was run); 2 could not tell.
# Exit, --killed: 0 the run was not killed (nothing is printed);
#                 137 it was killed, and what is known about why was printed.
set -uo pipefail

# --killed ------------------------------------------------------------------
explain_kill() {
  local log="${1:-}" rc="${2:-}" cid="${3:-}" since="${4:-}"
  [[ -n "${log}" && -n "${rc}" ]] || {
    echo "usage: memory-preflight.sh --killed LOG RC [CONTAINER_ID] [SINCE_EPOCH]" >&2; return 2; }
  # Killed means one of two shapes: make's own report of a child that died by
  # SIGKILL, or the container's main process dying by it (128 + 9).
  local killed=false
  [[ "${rc}" == "137" ]] && killed=true
  grep -qE '^make(\[[0-9]+\])?: \*\*\* \[.*\] (Killed|Error 137)$' "${log}" 2>/dev/null && killed=true
  [[ "${killed}" == "true" ]] || return 0

  local kernel="" readable=false
  if [[ -n "${LCA_KERNEL_LOG:-}" ]]; then
    [[ -r "${LCA_KERNEL_LOG}" ]] && { kernel="$(cat "${LCA_KERNEL_LOG}")"; readable=true; }
  elif [[ -n "${since}" ]] && command -v journalctl >/dev/null 2>&1 \
       && kernel="$(journalctl -k --since "@${since}" --no-pager 2>/dev/null)" && [[ -n "${kernel}" ]]; then
    # journalctl first: it can be bounded to this run. dmesg cannot, which the
    # container id makes safe — it names one run.
    readable=true
  elif kernel="$(dmesg 2>/dev/null)" && [[ -n "${kernel}" ]]; then
    readable=true
  fi

  echo
  if [[ "${readable}" != "true" ]]; then
    echo "RESULT: KILLED — no verdict. Something killed this run partway, and the kernel log could not be read here (it needs root, or the systemd-journal group), so whether it was memory is UNKNOWN. Nothing about the code was decided."
    return 137
  fi
  # The oom-kill line names the cgroup and the pid; the "Killed process" line
  # with that pid carries the size. Matched on the container id, so a kill
  # somewhere else on the machine is not blamed on this run.
  local record=""
  [[ -z "${cid}" ]] || record="$(grep -E "oom-kill:.*task_memcg=[^,]*docker-${cid}" <<<"${kernel}" | tail -1)"
  if [[ -z "${record}" ]]; then
    echo "RESULT: KILLED — no verdict. This run died by SIGKILL, and the kernel log holds no out-of-memory record for its container, so the cause was not the kernel's OOM killer (or the log no longer reaches back that far). Nothing about the code was decided."
    return 137
  fi
  local pid task detail kb size="" limit="the machine"
  pid="$(sed -nE 's/.*[,:]pid=([0-9]+).*/\1/p' <<<"${record}")"
  task="$(sed -nE 's/.*[,:]task=([^,]+),.*/\1/p' <<<"${record}")"
  detail="$(grep -E "Killed process ${pid:-NONE} " <<<"${kernel}" | tail -1)"
  kb="$(sed -nE 's/.*anon-rss:([0-9]+)kB.*/\1/p' <<<"${detail}")"
  [[ -z "${kb}" ]] || size=" at $(( kb / 1024 )) MB resident"
  grep -q 'CONSTRAINT_MEMCG' <<<"${record}" && limit="the container's memory limit"
  echo "RESULT: KILLED — no verdict. The kernel ran out of memory (${limit}) and killed ${task:-a process} (pid ${pid:-?})${size} inside this run's container. That is the machine, not the code: free memory — 'tests/memory-preflight.sh' lists what is holding it — and run again."
  return 137
}
if [[ "${1:-}" == "--killed" ]]; then
  shift
  explain_kill "$@"
  exit $?
fi

# before a run ---------------------------------------------------------------
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

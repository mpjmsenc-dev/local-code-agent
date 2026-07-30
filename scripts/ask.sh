#!/usr/bin/env bash
# scripts/ask.sh — ask the local model one question and print the answer.
#
# The fast path for "how do I ...?". aider is for editing a project and the
# WebUI is for a conversation; neither is what you want when you just need one
# answer in the terminal without leaving what you were doing.
#
#   lca ask "how do I find the 10 biggest files here?"
#   lca ask -f netmode.sh "what does this script do?"
#   journalctl -u ollama -n 50 | lca ask "why did this fail?"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

usage() {
  cat <<EOF
Usage: lca ask [-f FILE] "your question"
       <command> | lca ask "your question"

  -f FILE   include FILE as context (repeatable)

Answers come from ${MODEL_NAME} running locally — nothing leaves this machine.
EOF
}

main() {
  local files=() question="" arg
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -f|--file) [[ -n "${2:-}" ]] || die "-f needs a file path"; files+=( "$2" ); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)         arg="$1"; question="${question:+${question} }${arg}"; shift ;;
    esac
  done

  # Anything piped in becomes context. This is what makes it useful for
  # "why did this fail?" against a log you already have on screen.
  local piped=""
  if [[ ! -t 0 ]]; then
    piped="$(cat)"
  fi
  [[ -n "${question}" ]] || { usage; die "No question given."; }

  require_cmd curl jq
  ensure_ollama_up 60 >/dev/null 2>&1 || true
  wait_for_ollama 5 >/dev/null 2>&1 \
    || die "Ollama is not answering at $(ollama_url). Try: lca check"
  model_present "${MODEL_NAME}" \
    || die "Model '${MODEL_NAME}' is not downloaded. Pull it with: ollama pull ${MODEL_NAME}"

  # If the question names a file that exists right here, include it. "why is
  # setup.sh failing?" should just work — being made to repeat the filename with
  # -f is exactly the kind of friction that stops people asking. Only regular,
  # readable files in the current directory match, at most 3, and every one is
  # announced so nothing is silently sent to the model.
  local w auto=0
  for w in ${question}; do
    (( auto < 3 )) || break
    w="${w%%[),.:;?\"]}"          # strip trailing punctuation from the word
    w="${w##[(\"]}"
    # A path like bin/lca has no dot, so match on "looks like a path OR has
    # an extension" and let the filesystem be the real arbiter.
    [[ "${w}" == */* || "${w}" == *.* ]] || continue
    [[ -f "${w}" && -r "${w}" ]] || continue
    # Skip anything already passed with -f.
    local dup=false g
    for g in ${files[@]+"${files[@]}"}; do [[ "${g}" == "${w}" ]] && dup=true; done
    [[ "${dup}" == "true" ]] && continue
    files+=( "${w}" )
    auto=$(( auto + 1 ))
    info "including ${w} from the current directory"
  done

  # Build the prompt: file context, then piped context, then the question.
  local context="" f
  for f in ${files[@]+"${files[@]}"}; do
    [[ -r "${f}" ]] || die "Cannot read ${f}"
    # Cap each file so one large file cannot blow the whole context window.
    context+="--- file: ${f} ---"$'\n'"$(head -c 12000 "${f}")"$'\n\n'
  done
  [[ -z "${piped}" ]] || context+="--- piped input ---"$'\n'"$(printf '%s' "${piped}" | head -c 12000)"$'\n\n'

  local system="You are a concise expert assistant on a Linux machine. Answer directly and briefly. Prefer concrete commands and short code. If you are unsure, say so instead of inventing flags or APIs."
  local prompt="${context}${question}"

  local payload
  # Cap the reply. On CPU (a few tokens/second) an unbounded answer can run for
  # minutes before it stops on its own; LCA_ASK_TOKENS raises it when needed.
  payload="$(jq -n --arg m "${MODEL_NAME}" --arg s "${system}" --arg p "${prompt}" \
    --arg n "${LCA_ASK_TOKENS:-512}" \
    '{model:$m, system:$s, prompt:$p, stream:true, options:{num_predict:($n|tonumber)}}')"

  # Stream tokens as they arrive: on CPU inference, watching the answer appear
  # is the difference between "working" and "hung".
  # jq consumes the JSONL stream directly. Do NOT route chunks through
  # "$(...)": command substitution strips trailing newlines, so a chunk that
  # IS a newline disappears and every fenced code block comes back mangled
  # ("```bashdu -ah ..." instead of a real block).
  curl -sS --no-buffer --max-time 600 -X POST "$(ollama_url)/api/generate" \
    -H 'Content-Type: application/json' -d "${payload}" \
    | jq -rj --unbuffered '.response // empty'
  printf '\n'
}

main "$@"

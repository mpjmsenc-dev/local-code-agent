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

ASK_STATE_DIR="${HOME}/.cache/local-code-agent"
ASK_LAST="${ASK_STATE_DIR}/ask-last"

usage() {
  cat <<EOF
Usage: lca ask [-f FILE] [-c] [-m MODEL] "your question"
       <command> | lca ask "your question"

  -f FILE    include FILE as context (repeatable)
  -c         continue from your last question and answer
  -m MODEL   answer with MODEL just this once (default: ${MODEL_NAME})

Answers come from ${MODEL_NAME} running locally — nothing leaves this machine.
EOF
}

main() {
  local files=() question="" arg continue_last=false
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -f|--file) [[ -n "${2:-}" ]] || die "-f needs a file path"; files+=( "$2" ); shift 2 ;;
      -c|--continue) continue_last=true; shift ;;
      # A flag, not the MODEL_NAME environment variable: load_env sources .env
      # under 'set -a', so an exported MODEL_NAME is overwritten by the file and
      # 'MODEL_NAME=x lca ask ...' silently answers with the configured model
      # instead. Comparing two models is a real thing people do — this is the
      # way that actually works.
      -m|--model) [[ -n "${2:-}" ]] || die "-m needs a model name"; MODEL_NAME="$2"; shift 2 ;;
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
  ensure_ollama_up_announced 60 || true
  wait_for_ollama 5 >/dev/null 2>&1 \
    || die "Ollama is not answering at $(ollama_url). Try: lca check"
  model_present "${MODEL_NAME}" \
    || die "Model '${MODEL_NAME}' is not downloaded. $(pull_advice "${MODEL_NAME}")"

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
    # >&2 like every other message here: this command's stdout IS the model's
    # answer, and lib.sh states the rule while naming this command — "in 'lca
    # ask' the model's answer is stdout, and progress must not end up inside a
    # piped or redirected answer". Measured before the fix, the whole of stdout
    # for a cold 'lca ask -c' was "[info] continuing from your last question".
    info "including ${w} from the current directory" >&2
  done

  # Build the prompt: the previous exchange (with -c), then file context, then
  # piped context, then the question.
  local context="" f
  if [[ "${continue_last}" == "true" ]]; then
    if [[ -r "${ASK_LAST}" ]]; then
      # Capped: a long previous answer would otherwise crowd out the files and
      # the new question, and on CPU every extra token is time on the clock.
      context+="--- the previous exchange, for context ---"$'\n'"$(head -c 6000 "${ASK_LAST}")"$'\n\n'
      info "continuing from your last question" >&2
    else
      warn "No previous question to continue from — answering this one on its own."
    fi
  fi
  for f in ${files[@]+"${files[@]}"}; do
    [[ -r "${f}" ]] || die "Cannot read ${f}"
    # Cap each file so one large file cannot blow the whole context window.
    context+="--- file: ${f} ---"$'\n'"$(head -c 12000 "${f}")"$'\n\n'
  done
  # Sliced with parameter expansion, NOT 'printf ... | head -c'. That pipeline
  # killed this command outright on exactly the inputs it exists for: head
  # exits after 12000 bytes, printf still has the rest to write, takes SIGPIPE,
  # and under 'set -o pipefail' the substitution returns 141 — which errexit
  # then turns into an immediate exit with no answer, no warning and no error.
  #
  # Size-dependent, so it looked like nothing was wrong: anything that fits the
  # 64 KiB pipe buffer completes before head leaves. Measured — 60000 chars
  # exit 0, 70000 exit 141. 'lca logs | lca ask "why did this fail?"' is the
  # first thing docs/TROUBLESHOOTING.md tells you to run, and a log big enough
  # to be worth asking about is a log big enough to trigger this.
  [[ -z "${piped}" ]] || context+="--- piped input ---"$'\n'"${piped:0:12000}"$'\n\n'

  # Same system prompt as the phone chat — one assistant, two doors.
  local system prompt
  system="$(lca_system_prompt)"

  # Each piece above is capped so that no single one "can blow the whole
  # context window". Nothing capped the TOTAL, and the caps sum to ~54,000
  # characters — roughly 13,500 tokens — against the 4,096-token window the 3b
  # rung runs with on a base droplet. Ollama truncates an over-long prompt from
  # the FRONT, which is where the system prompt sits, so the failure mode is
  # the assistant silently losing its own instructions and answering like a
  # stock model. On 'lca logs | lca ask "why did this fail?"' — recommended by
  # both the README and TROUBLESHOOTING.md — piped input alone already reached
  # the edge of that window before anything else was added.
  #
  # Budget: the window, less the reply, less the system prompt, less a margin
  # for the question and the chat scaffolding. ~4 characters per token, the
  # same rough figure the prompt-size gate uses. The tail is kept because the
  # sections are appended oldest-first, so piped input — the thing the user
  # just produced — is last and survives.
  local ctx_tokens reply_tokens budget_chars
  ctx_tokens="${OLLAMA_CONTEXT_LENGTH:-8192}"
  [[ "${ctx_tokens}" =~ ^[0-9]+$ ]] || ctx_tokens=8192
  reply_tokens="${LCA_ASK_TOKENS:-512}"
  [[ "${reply_tokens}" =~ ^[0-9]+$ ]] || reply_tokens=512
  budget_chars=$(( (ctx_tokens - reply_tokens) * 4 - ${#system} - 400 ))
  (( budget_chars > 2000 )) || budget_chars=2000
  if (( ${#context} > budget_chars )); then
    # Names what is lost, not just how much is kept. Sections are appended
    # oldest-first, so trimming to the tail drops whole files and the previous
    # exchange before it touches piped input — "keeping the last N characters"
    # is true but does not tell someone who passed three files that two of them
    # are simply gone.
    warn "Context (${#context} chars) is bigger than ${MODEL_NAME}'s ${ctx_tokens}-token window. Keeping the most recent ${budget_chars} and dropping what came before — earlier -f files and the previous exchange go first, piped input last. Pass fewer files, pipe less, or raise OLLAMA_CONTEXT_LENGTH in .env and run: sudo lca apply."
    context="${context: -budget_chars}"
  fi

  prompt="${context}${question}"

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
  # tee the answer to a file as it streams, so 'lca ask -c' can follow up
  # without the user retyping the context. Written through a temp file and
  # moved into place, so an interrupted answer cannot leave a half-written
  # exchange that the next -c would treat as complete.
  local answer_tmp raw_tmp
  answer_tmp="$(mktemp)"
  # The RAW body as well as the extracted answer. jq keeps only '.response',
  # which is exactly nothing when Ollama replies with an error object — and
  # that object is the only thing that says what went wrong. See the empty-
  # answer check below the stream.
  raw_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${answer_tmp}' '${raw_tmp}'" EXIT

  # Streaming solves the SECOND half of the wait — tokens appearing as they are
  # generated, per the comment above. It cannot touch the first half: a model
  # that is not resident has to be loaded before it produces a single token,
  # and that is silent by nature. Measured on this 4-vCPU host with no GPU:
  # 88s to load a 3B, 64s for a 0.5B, and warm_model records 228s for a 7B on a
  # cold page cache. A minute of nothing after pressing Enter is exactly the
  # "is it hung?" that the streaming was added to prevent, arriving before the
  # stream can start.
  #
  # Only when it will actually be slow. If the model is already resident the
  # first token is immediate and this would be noise on every question.
  #
  # stderr, not stdout: README documents 'lca logs | lca ask "why did this
  # fail?"', and people redirect answers to files. The answer must stay the
  # only thing on stdout.
  if ! ollama_processor "${MODEL_NAME}" >/dev/null 2>&1; then
    printf 'Loading %s into memory first — this pause happens once, then the answer streams.\n' \
      "${MODEL_NAME}" >&2
  fi
  # Status captured, not swallowed. Bare under 'set -o pipefail' this pipeline
  # was the last statement of main, so a curl that died mid-answer — the 600s
  # cap, or Ollama being OOM-killed by the very model it just loaded — exited
  # the whole command silently. The user was left with half an answer, no
  # error, and a non-zero status nothing explained. speed.sh has always said so
  # on the same failure.
  local stream_rc=0
  curl -sS --no-buffer --max-time 600 -X POST "$(ollama_url)/api/generate" \
    -H 'Content-Type: application/json' -d "${payload}" \
    | tee "${raw_tmp}" \
    | jq -rj --unbuffered '.response // empty' \
    | tee "${answer_tmp}" || stream_rc=$?
  printf '\n'

  if [[ -s "${answer_tmp}" ]]; then
    # Not bare either: ~/.cache/local-code-agent ends up root-owned the moment
    # anything here is run once under sudo, and then this whole block failed
    # under 'set -e' — after a perfect answer had already been printed. Losing
    # the follow-up history is a papercut; exiting non-zero with no message,
    # having apparently just worked, is not.
    local save_ok=true
    mkdir -p "${ASK_STATE_DIR}" 2>/dev/null || save_ok=false
    # Owner-only: this file holds the last question and answer verbatim, which
    # routinely includes the contents of whatever file was attached. A
    # world-readable copy of that under ~/.cache is not something to leave
    # behind by default.
    chmod 700 "${ASK_STATE_DIR}" 2>/dev/null || true
    # The redirect is inside a subshell so that a failure to OPEN the file is
    # the subshell's error to swallow. Grouped instead, bash reports it before
    # the group runs and the '2>/dev/null' on the group never sees it — a raw
    # "Not a directory" above the warning that explains it.
    ( {
        printf 'Question: %s\n\nAnswer: ' "${question}"
        cat "${answer_tmp}"
        printf '\n'
      } > "${ASK_LAST}.tmp" ) 2>/dev/null || save_ok=false
    if [[ "${save_ok}" == "true" ]]; then
      chmod 600 "${ASK_LAST}.tmp" 2>/dev/null || save_ok=false
      mv "${ASK_LAST}.tmp" "${ASK_LAST}" 2>/dev/null || save_ok=false
    fi
    if [[ "${save_ok}" != "true" ]]; then
      rm -f "${ASK_LAST}.tmp" 2>/dev/null || true
      warn "Could not save this exchange to ${ASK_LAST}, so 'lca ask -c' will have nothing to continue from. Check who owns it: ls -ld ${ASK_STATE_DIR}"
    fi
  fi

  # An empty answer that exited cleanly is not success.
  #
  # 'curl -sS' has no '-f', so an HTTP error arrives as a body with a zero exit
  # status. Measured against a model that is not installed:
  #
  #   $ curl -sS .../api/generate -d '{"model":"no-such-model:1b",...}'
  #   {"error":"model 'no-such-model:1b' not found"}   (curl rc=0)
  #   ...piped through jq '.response // empty' -> nothing, pipeline rc=0
  #
  # so 'lca ask' printed nothing, warned about nothing and exited 0, throwing
  # away the one sentence that named the problem. Observed live too: a cold
  # 'lca ask -c' produced the "continuing from your last question" line, no
  # answer, and status 0.
  #
  # '-f' is not the fix — it would make curl fail, but it discards the body,
  # which is the part worth reading. Keeping the raw stream costs one tee and
  # leaves the streaming behaviour above untouched.
  if [[ ! -s "${answer_tmp}" ]] && (( stream_rc == 0 )); then
    local ollama_err
    ollama_err="$(jq -rj '.error // empty' <"${raw_tmp}" 2>/dev/null || true)"
    if [[ -n "${ollama_err}" ]]; then
      err "Ollama refused the request and sent no answer: ${ollama_err}"
      return 1
    fi
    err "${MODEL_NAME} returned an empty answer — the request succeeded but produced no text at all. That usually means the prompt was rejected for length; try a shorter question, or fewer -f files. Check the engine with: lca check"
    return 1
  fi

  if (( stream_rc != 0 )); then
    warn "The answer above is incomplete — the request to Ollama ended early (a 10-minute cap, a restart, or the model being killed for memory). Try a shorter question, or check: lca check"
    return 1
  fi
}

main "$@"

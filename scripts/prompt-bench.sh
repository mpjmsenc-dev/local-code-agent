#!/usr/bin/env bash
# scripts/prompt-bench.sh — measure the system prompt against the real model.
#
# CONTRIBUTING.md says a prompt change must be measured, on the smallest rung,
# several times, counting the failure rather than the success. It said that
# while shipping no way to do it, so the advice was only followable by someone
# who first rebuilt this. Here it is.
#
# What it measures, on the model .env is configured for:
#
#   hands over   the answer names bare 'lca' — the one command that writes files
#   says where   it tells the reader the command goes in a terminal on the server
#   tutorial     the FAILURE: a doomed multi-file setup walkthrough
#   hijack       the OTHER failure: the handover fired on a question that
#                should simply have been answered
#   tool-call    the THIRD failure, reported from a real phone: instead of
#                answering, the model emits a function-call envelope —
#                {"name": ..., "arguments": {...}} — which Open WebUI renders
#                as a JSON block and which does nothing whatsoever. The prompt
#                has told it "You have NO tools" since 2026-08-03; this is
#                whether the model listens. Nothing here could see it before,
#                so a prompt change could not be judged against it.
#
# Sampling matters. Generation is stochastic, so one run proves nothing and
# small differences at N=3 are noise — a 2-in-3 "regression" here measured
# 1-in-6 when re-run. Use -n 6 or more before believing a difference.
#
# Deliberately NOT part of 'make test' or CI: it needs a running model and
# minutes of CPU, and CI has neither.
#
# Usage:
#   scripts/prompt-bench.sh              6 samples, the configured model
#   scripts/prompt-bench.sh -n 10        more samples
#   scripts/prompt-bench.sh -m qwen2.5-coder:3b   pin a model
#   scripts/prompt-bench.sh -f other.txt          bench a candidate prompt file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

SAMPLES=6
MODEL="${MODEL_NAME}"
PROMPT_FILE=""

usage() {
  cat <<EOF
Usage: scripts/prompt-bench.sh [-n SAMPLES] [-m MODEL] [-f PROMPT_FILE]

Measures the shared system prompt against the real model and prints a count
per behaviour. Compare two candidates by benching each with the SAME -n.

  -n N   samples per question (default ${SAMPLES}; use 6+ before believing a diff)
  -m M   model to ask (default ${MODEL_NAME}, from .env)
  -f F   bench the prompt in file F instead of the built-in one
EOF
}

# Argument parsing lives in main(), NOT at file scope. This script is
# sourceable so its matchers can be tested without a model, and a sourced
# script that parses "$@" would consume the SOURCING shell's arguments — the
# test harness passed three of its own and got a usage message and a die.
parse_args() {
  while (( $# )); do
    case "$1" in
      # Validated BEFORE the shift, like ask.sh, logs.sh and speed.sh. Written
      # the other way round, 'prompt-bench.sh -n' shifted two arguments off a
      # list holding one: shift failed, errexit took the script out with no
      # message at all, and the check below — which does say what is wrong —
      # was never reached. Measured: exit 1, empty output, for -n, -m and -f
      # alike, while '-n abc' explained itself perfectly.
      -n) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "-n needs a number of samples (e.g. -n 6)"
          SAMPLES="$2"; shift 2 ;;
      -m) [[ -n "${2:-}" ]] || die "-m needs a model name"
          MODEL="$2"; shift 2 ;;
      -f) [[ -n "${2:-}" ]] || die "-f needs a path to a prompt file"
          PROMPT_FILE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown option: $1" ;;
    esac
  done
  [[ "${SAMPLES}" =~ ^[0-9]+$ && "${SAMPLES}" -gt 0 ]] || die "-n needs a positive number"
}

# The questions are the real ones. 'build' is verbatim what a user asked a real
# deployment; the rest are the cases that broke while fixing it.
#   build    must hand over — the reported bug
#   wishlist must hand over — the SECOND reported one, and harder
#   backup   must NOT hand over — it has a one-word answer, 'lca backup'
#   explain  must NOT hand over — a language question is what the chat is FOR
BENCH_BUILD="build me a whole functioning income and expense tracker app"
# The second real one, photographed from a phone on 2026-08-04: the same
# request carrying a feature list AND a trailing follow-up instruction ("After
# finishing, review the code and suggest improvements"), which is how people
# actually type it.
#
# It is here because it is a real shape, NOT because it is harder. A four-sample
# run of it looked worse than the bare question — 3/4 with a tutorial — and at
# n=6 through this bench it is 6/6, tutorial 0. That is the noise this file's
# own header warns about, caught by re-running rather than by shipping the
# first number. Baseline on the 3b rung, current prompt, both build questions:
# hands over 6/6, says where 6/6, tutorial 0/6, tool-call 0/6.
BENCH_WISHLIST="build me an income and expense tracker app with categories, a monthly summary, search and filter, CSV export, local storage, a responsive UI, unit tests and a README. After finishing, review the code and suggest improvements."
BENCH_BACKUP="how do I take a backup right now?"
BENCH_EXPLAIN="explain the difference between a list and a tuple in python"

SYSTEM=""

# load_system — resolve which prompt is under test. Also main()-only: sourcing
# this file must not shell out or read files the caller never asked for.
load_system() {
  if [[ -n "${PROMPT_FILE}" ]]; then
    [[ -r "${PROMPT_FILE}" ]] || die "Cannot read prompt file: ${PROMPT_FILE}"
    SYSTEM="$(cat "${PROMPT_FILE}")"
  else
    SYSTEM="$(lca_system_prompt)"
  fi
}

# ask QUESTION SEED — one generation, printed raw.
#
# The request is built with jq rather than by pasting into a here-doc: the
# prompt contains quotes, backticks and em dashes, and one unescaped character
# would produce a 400 that looks exactly like a model that answered nothing.
ask() {
  local q="$1" seed="$2" payload
  payload="$(jq -nc --arg m "${MODEL}" --arg s "${SYSTEM}" --arg p "${q}" \
    --argjson seed "${seed}" \
    '{model: $m, system: $s, prompt: $p, stream: false,
      options: {num_predict: 260, temperature: 0.4, seed: $seed}}')"
  curl -sf --max-time 900 -X POST "$(ollama_url)/api/generate" \
    -H 'Content-Type: application/json' -d "${payload}" \
    | jq -r '.response // ""'
}

# Counting the FAILURE is more reliable than counting the success: "did it say
# the right thing" needs a pattern for every phrasing of right, and the one
# used while developing this quietly missed "run lca in your project" — so
# every rate it reported was a floor. A doomed tutorial has one shape.
hands_over()  { grep -qE '(^|[^a-z])lca([^a-z ]|$)|&& lca$' <<<"$1"; }
# Matched on the ENVELOPE, not on the word "tool": an answer may legitimately
# discuss tools, and a small model's failure is structural — either qwen's own
# <tool_call> tags, or the OpenAI-shaped object carrying both a name and its
# arguments. Requiring both keys keeps a code sample that merely prints
# "arguments" from counting.
tool_called() {
  grep -q '<tool_call>' <<<"$1" && return 0
  grep -q '"tool_calls"' <<<"$1" && return 0
  grep -q '"name"' <<<"$1" && grep -q '"arguments"' <<<"$1"
}
says_where()  { grep -qiE 'terminal|ssh|on (your|the|this) server' <<<"$1"; }
hijacked()    { grep -qE 'mkdir -p [^&]*&&|cd [^&]*&& *lca' <<<"$1"; }
is_tutorial() {
  # Our own recipe contains 'mkdir', so strip it before looking for setup
  # steps — otherwise the fix reads as the failure it was written to prevent.
  # Whole lines, via grep -v rather than a sed substitution: it is both what
  # is meant (the recipe occupies its own line) and free of SC2001.
  local body; body="$(grep -v 'mkdir -p ~/my-project' <<<"$1" || true)"
  grep -qiE '^[[:space:]]*(#+[[:space:]]*)?(step[[:space:]]*[0-9]|[0-9][.)][[:space:]])' <<<"$1" \
    && grep -qiE 'npm init|python3? -m venv|pip install|npx create|mkdir' <<<"${body}"
}

bench() {
  local label="$1" question="$2" i out
  local over=0 where=0 tut=0 hij=0 tool=0
  for (( i = 0; i < SAMPLES; i++ )); do
    out="$(ask "${question}" "$(( 1000 + i ))" || true)"
    if [[ -z "${out}" ]]; then
      warn "empty answer for '${label}' sample ${i} — is '${MODEL}' pulled?"
      continue
    fi
    hands_over  "${out}" && over=$(( over + 1 ))
    says_where  "${out}" && where=$(( where + 1 ))
    is_tutorial "${out}" && tut=$(( tut + 1 ))
    hijacked    "${out}" && hij=$(( hij + 1 ))
    tool_called "${out}" && tool=$(( tool + 1 ))
  done
  printf '  %-8s hands over %s/%s   says where %s/%s   tutorial %s/%s   handover-fired %s/%s   tool-call %s/%s\n' \
    "${label}" "${over}" "${SAMPLES}" "${where}" "${SAMPLES}" \
    "${tut}" "${SAMPLES}" "${hij}" "${SAMPLES}" "${tool}" "${SAMPLES}"
}

main() {
  parse_args "$@"
  require_cmd curl jq
  load_system
  step "Benching the system prompt against ${MODEL} (${SAMPLES} samples each)"
  ensure_ollama_up_announced 60 \
    || die "Ollama is not answering at $(ollama_url) — start it, then re-run."
  model_present "${MODEL}" || die "Model '${MODEL}' is not downloaded (ollama pull ${MODEL})"

  local chars; chars="$(wc -c <<<"${SYSTEM}")"
  info "Prompt is ${chars} chars, roughly $(( chars / 4 )) tokens of the ${OLLAMA_CONTEXT_LENGTH} context — spent on every message."
  info "This asks the model $(( SAMPLES * 4 )) times; on a CPU box that is minutes, not seconds."
  echo

  ok "WANTED: 'build' hands over and says where; tutorial and tool-call stay 0"
  bench build "${BENCH_BUILD}"
  bench wishlist "${BENCH_WISHLIST}"
  echo
  ok "WANTED: these answer the question — 'handover-fired' and 'tool-call' must stay 0"
  bench backup  "${BENCH_BACKUP}"
  bench explain "${BENCH_EXPLAIN}"
  echo
  info "Compare candidates with the same -n. Differences at n<6 are usually noise."
}

# Sourceable so the individual matchers can be exercised without a model —
# same pattern as scripts/tune.sh, scripts/apply.sh and scripts/motd.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

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
#   bad-command  the FOURTH: an 'lca' command line this box would reject —
#                an invented subcommand, or 'lca logs' used as a prefix for an
#                arbitrary shell command, which is what the model does when it
#                wants to show you a log. The prompt forbids inventing flags;
#                this is whether it listens.
#   tool-call    the THIRD failure, reported from a real phone: instead of
#                answering, the model emits a function-call envelope —
#                {"name": ..., "arguments": {...}} — which Open WebUI renders
#                as a JSON block and which does nothing whatsoever. The prompt
#                has told it "You have NO tools" since 2026-08-03; this is
#                whether the model listens. Nothing here could see it before,
#                so a prompt change could not be judged against it.
#
# Sampling matters more than it looks. Generation is stochastic, and six
# samples do not merely give a wide interval — they have pointed the WRONG WAY:
# a change that measured 5/6 -> 2/6 here (a regression) measured 12/20 -> 16/20
# at matched seeds (an improvement). Use -n 20 for anything you intend to act
# on, run the same seeds either side, and change one thing at a time.
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

  -n N   samples per question (default ${SAMPLES}; use 20 to judge a change)
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
      *) usage >&2; die "Unknown option: $1" ;;
    esac
  done
  [[ "${SAMPLES}" =~ ^[0-9]+$ && "${SAMPLES}" -gt 0 ]] || die "-n needs a positive number"
}

# The questions are the real ones. 'build' is verbatim what a user asked a real
# deployment; the rest are the cases that broke while fixing it.
#   build    must hand over — the reported bug
#   wishlist must hand over — the SECOND reported one, and harder
#   terminal must hand over — a starter question the empty screen offers
#   backup   must NOT hand over — it has a one-word answer, 'lca backup'
#   explain  must NOT hand over — a language question is what the chat is FOR
#   service  must NOT hand over — a question about THIS server, also a starter
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
# first number.
#
# Baseline, 3b rung, current prompt, through /api/chat (see ask() below), with
# the two-part hijack matcher.
#
# The three questions that have been measured properly — n=20, matched seeds,
# same run either side of the change that added "a service that will not start"
# to the prompt's list of server questions:
#
#                        wanted    before   after (as shipped)
#   build     hands over   20/20    19/20   18/20
#   build     tutorial      0/20     3/20    2/20
#   terminal  hands over   20/20    12/20   16/20
#   service   handover      0/20    13/20    6/20
#
# bad-command, measured once on the shipped prompt at the same seeds:
#   service 2/20   terminal 1/20   backup 0/20
#
# That is a FLOOR, deliberately. The matcher catches 'lca logs <shell command>'
# and an unknown subcommand on a short line; it does not yet catch the same
# mistake made with a subcommand that takes no argument at all, e.g.
#
#     lca apply systemctl restart my-service
#
# which appears in the same answers. Widening it there needs a way to tell that
# line from prose like "lca apply changes settings", and a matcher that fires
# on prose is worse than one that misses — the header-only hijack matcher
# proved that two commits ago.
#
# The obvious fix was tried and REJECTED, which is why the table line still
# reads the way it does. The prompt's command table says "lca logs   recent
# logs from Ollama, the chat app and the installer" and never says it takes one
# of four fixed sources, so naming them looked like plain accuracy. Measured,
# n=20, same seeds:
#
#                       before   after naming the sources
#   service bad-command   2/20    9/20
#   terminal bad-command  1/20    1/20
#   backup bad-command    0/20    0/20
#   (handover metrics unmoved on all three)
#
# Describing the argument slot taught the model to USE it, and a 3b model
# fills it wrong more often than right: 'lca logs systemd' is a typical
# failure, guessing a source that does not exist. Same shape as the earlier
# result where naming 'lca apply' as a counter-example taught the model to
# answer 'lca apply'. Adding detail about how a command can be used is not the
# safe direction; adding an example of the RIGHT answer is.
#
# 'terminal' is the one figure here not taken on the shipped bytes: it was
# measured on the same words wrapped one line differently. That distinction is
# not pedantry — re-wrapping a single sentence, changing nothing but where the
# line breaks fall, moved 'service' from 9/20 to 6/20. Three in twenty is about
# one standard error at this sample size, which is the honest scale of the
# wobble in every number on this page.
#
# The other three, at n=6 and stable across every run so far: backup and
# explain fire no handover and no tool call; wishlist hands over 6/6.
#
# Read the last two columns with the WANTED lines in main(): for build,
# wishlist and terminal a fired handover is the POINT; for backup, explain and
# service it is the failure.
#
# On sampling, harder than the header above puts it. Six samples cannot judge
# these questions, and not merely because the interval is wide — it pointed the
# WRONG WAY. The n=6 bench read terminal 5/6 before and 2/6 after, which says
# the change hurt it; n=20 at matched seeds says 12/20 to 16/20, which is the
# opposite. Service read 2/6 before and 3/6 after at one seed range while the
# same prompt pair read 8/10 and 2/10 at another. Use -n 20 for anything in
# this table, and change one thing at a time.
BENCH_WISHLIST="build me an income and expense tracker app with categories, a monthly summary, search and filter, CSV export, local storage, a responsive UI, unit tests and a README. After finishing, review the code and suggest improvements."
# The fifth is not hypothetical either: it is verbatim the last entry in
# config/prompt-suggestions.json, i.e. one of five things a phone user can tap
# on the empty screen without typing anything. It asks, in as many words, for
# "the exact command for the terminal case" — and measured 6 in 10 on the 3b
# rung, with the misses handing out 'lca apply', a real command that does
# something else entirely and needs sudo.
BENCH_TERMINAL="What kinds of task can you help with in this chat, and which ones need the terminal agent instead? Answer briefly and give me the exact command for the terminal case."
BENCH_BACKUP="how do I take a backup right now?"
BENCH_EXPLAIN="explain the difference between a list and a tuple in python"
# Also verbatim from config/prompt-suggestions.json, and the one that measured
# badly: "walk me through diagnosing it, starting with the exact commands" has
# the shape of a build request while being a question about THIS server, which
# the prompt says to answer directly and never send to aider. Three of six
# answers on the 3b rung opened with the handover anyway.
BENCH_SERVICE="A systemd service won't start. Walk me through diagnosing it, starting with the exact commands to run and what to look for in the output."

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
# Through /api/chat, with the prompt as a system MESSAGE. That is the shape
# Open WebUI sends, and this file exists to measure what the phone gets.
#
# It used to post to /api/generate with the prompt in the 'system' field — a
# different code path through the model's chat template. The bug that prompted
# all of this was a tool-call envelope, which is precisely the kind of
# behaviour a template decides, so a bench that could not reproduce the user's
# path could not confirm a fix for it either. Measured across the switch on the
# 3b rung, the build question, n=6: identical (hands over 6/6, tool-call 0/6),
# so the numbers recorded above carry over rather than being reset by it.
#
# The request is built with jq rather than by pasting into a here-doc: the
# prompt contains quotes, backticks and em dashes, and one unescaped character
# would produce a 400 that looks exactly like a model that answered nothing.
ask() {
  local q="$1" seed="$2" payload
  payload="$(jq -nc --arg m "${MODEL}" --arg s "${SYSTEM}" --arg p "${q}" \
    --argjson seed "${seed}" \
    '{model: $m,
      messages: [{role: "system", content: $s}, {role: "user", content: $p}],
      stream: false,
      options: {num_predict: 260, temperature: 0.4, seed: $seed}}')"
  curl -sf --max-time 900 -X POST "$(ollama_url)/api/chat" \
    -H 'Content-Type: application/json' -d "${payload}" \
    | jq -r '.message.content // ""'
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
# lca_subcommands — every word bin/lca actually dispatches, read out of its own
# case statement so aliases ('selftest', 'online') count and a rename cannot
# leave this list quietly stale.
lca_subcommands() {
  grep -oE '^  [a-z|"]+\)' "${REPO_ROOT}/bin/lca" \
    | tr -d ' )"' | tr '|' '\n' | grep -v '^$' | sort -u
}

# bad_command — the answer offers an 'lca' command line this box would reject.
#
# The prompt tells the model "never invent command-line flags, file paths or
# API names — a confidently wrong flag costs the user more than I do not know",
# and nothing here could see whether it listens. Observed while measuring the
# 'service' question:
#
#     lca logs systemctl status my-service
#     lca logs journalctl -xe | grep my-service
#
# 'lca logs' is real; those arguments are not — it takes ollama, webui, setup
# or all. Two shapes are checked, and the second is deliberately narrow:
#
#   a known subcommand given an argument it rejects (only 'lca logs' today,
#   which is the one a small model reliably treats as a prefix for any shell
#   command it fancies)
#
#   an unknown subcommand, but ONLY on a line short enough to be a command.
#   "lca will write the files for you" is prose, and the first draft of this
#   flagged it: three words of English after 'lca' look exactly like a
#   subcommand and an argument. Three tokens is the whole of 'sudo lca apply'.
bad_command() {
  local line word arg cmds
  cmds="$(lca_subcommands)"
  [[ -n "${cmds}" ]] || return 1        # cannot tell: never claim a failure
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"          # strip leading blanks
    line="${line#$ }"; line="${line#sudo }"
    word="$(awk '{print $2}' <<<"${line}")"
    [[ -n "${word}" ]] || continue
    if ! grep -qx -- "${word}" <<<"${cmds}"; then
      (( $(wc -w <<<"${line}") <= 3 )) && return 0
      continue
    fi
    [[ "${word}" == "logs" ]] || continue
    # 'lca logs [-n N] [-f] [SOURCE]' — find the first token that is not a flag
    # or its number, and check it against the sources logs.sh accepts.
    arg="$(awk '{for (i = 3; i <= NF; i++) {
                  if ($i ~ /^-/) { i++; continue }
                  print $i; exit } }' <<<"${line}")"
    [[ -n "${arg}" ]] || continue
    case "${arg}" in
      ollama|webui|setup|all) ;;
      *) return 0 ;;
    esac
  done < <(grep -oE '^[[:space:]]*([$][[:space:]])?(sudo[[:space:]]+)?lca[[:space:]]+[a-z][a-z-]*.*' <<<"$1")
  return 1
}

says_where()  { grep -qiE 'terminal|ssh|on (your|the|this) server' <<<"$1"; }
# The handover has two shapes and this saw only one. The prompt tells the model
# to open with a comment line and then the recipe, and a small model routinely
# emits the comment plus a bare 'lca' with the mkdir/cd dropped:
#
#     # in a terminal on the server (SSH in from your phone)
#     lca
#
# Measured on the starter question "a systemd service won't start — walk me
# through diagnosing it": three of six answers opened that way, and this
# matcher counted one. So the number this bench prints for its own headline
# failure was a third of the truth, on exactly the questions it exists to
# protect. The comment line is quoted verbatim from the prompt, which makes it
# the more reliable half of the signature, not the weaker one.
hijacked() {
  grep -qE 'mkdir -p [^&]*&&|cd [^&]*&& *lca' <<<"$1" && return 0
  # The header line AND a line that is just 'lca'. Both halves are needed.
  #
  # The header alone was the first attempt, and it fired on the best possible
  # answer: asked "how do I take a backup right now?" the model replies
  #
  #     # in a terminal on the server (SSH in from your phone)
  #     lca backup
  #
  # which is exactly right — the prompt teaches both the location hint and the
  # command. Counting that as the handover firing took this metric from 0/6 to
  # 6/6 on a question whose answers had not changed at all. Being sent to the
  # coding AGENT is the failure, and that is the bare word on its own.
  grep -qiF 'in a terminal on the server' <<<"$1" \
    && grep -qE '^[[:space:]]*lca[[:space:]]*$' <<<"$1"
}
is_tutorial() {
  # Our own recipe contains 'mkdir', so strip it before looking for setup
  # steps — otherwise the fix reads as the failure it was written to prevent.
  # Whole lines, via grep -v rather than a sed substitution: it is both what
  # is meant (the recipe occupies its own line) and free of SC2001.
  local body; body="$(grep -v 'mkdir -p ~/my-project' <<<"$1" || true)"
  grep -qiE '^[[:space:]]*(#+[[:space:]]*)?(step[[:space:]]*[0-9]|[0-9][.)][[:space:]])' <<<"$1" \
    && grep -qiE 'npm init|python3? -m venv|pip install|npx create|mkdir' <<<"${body}"
}

# Rates are over the samples that ANSWERED, not over the samples requested.
#
# A request can come back empty — Ollama still loading a model, a dropped
# connection, a 500 — and the loop already skips those. But the denominator was
# SAMPLES, so every skip silently deflated every rate. Measured on the 7b rung:
# one empty sample in six printed "hands over 5/6", which reads as a one-in-six
# failure and was actually five out of five. In a tool whose entire output is
# rates, and whose stated purpose is judging small differences between prompts,
# that is the number lying about exactly what it is for.
bench() {
  local label="$1" question="$2" i out
  local over=0 where=0 tut=0 hij=0 tool=0 bad=0 got=0
  for (( i = 0; i < SAMPLES; i++ )); do
    out="$(ask "${question}" "$(( 1000 + i ))" || true)"
    if [[ -z "${out}" ]]; then
      warn "empty answer for '${label}' sample ${i} — is '${MODEL}' pulled?"
      continue
    fi
    got=$(( got + 1 ))
    hands_over  "${out}" && over=$(( over + 1 ))
    says_where  "${out}" && where=$(( where + 1 ))
    is_tutorial "${out}" && tut=$(( tut + 1 ))
    hijacked    "${out}" && hij=$(( hij + 1 ))
    tool_called "${out}" && tool=$(( tool + 1 ))
    bad_command "${out}" && bad=$(( bad + 1 ))
  done
  if (( got == 0 )); then
    warn "  ${label}: NO sample answered — nothing was measured. Is '${MODEL}' pulled and Ollama up?"
    return 0
  fi
  printf '  %-8s hands over %s/%s   says where %s/%s   tutorial %s/%s   handover-fired %s/%s   tool-call %s/%s   bad-command %s/%s\n' \
    "${label}" "${over}" "${got}" "${where}" "${got}" \
    "${tut}" "${got}" "${hij}" "${got}" "${tool}" "${got}" "${bad}" "${got}"
  # Said out loud, because a denominator quietly smaller than the -n you asked
  # for is the difference between two runs you can compare and two you cannot.
  (( got == SAMPLES )) \
    || warn "  ^ ${label}: ${got} of ${SAMPLES} samples answered; the rates above are over ${got}, not ${SAMPLES}"
}

main() {
  parse_args "$@"
  require_cmd curl jq
  load_system
  step "Benching the system prompt against ${MODEL} (${SAMPLES} samples each)"
  ensure_ollama_up_announced 60 \
    || die "Ollama is not answering at $(ollama_url) — start it, then re-run."
  model_present "${MODEL}" || die "Model '${MODEL}' is not downloaded. $(pull_advice "${MODEL}")"

  local chars; chars="$(wc -c <<<"${SYSTEM}")"
  info "Prompt is ${chars} chars, roughly $(( chars / 4 )) tokens of the ${OLLAMA_CONTEXT_LENGTH} context — spent on every message."
  info "This asks the model $(( SAMPLES * 6 )) times; on a CPU box that is minutes, not seconds."
  echo

  ok "WANTED: these hand over and say where; tutorial and tool-call stay 0"
  bench build "${BENCH_BUILD}"
  bench wishlist "${BENCH_WISHLIST}"
  bench terminal "${BENCH_TERMINAL}"
  echo
  ok "WANTED: these answer the question — 'handover-fired' and 'tool-call' must stay 0"
  bench backup  "${BENCH_BACKUP}"
  bench explain "${BENCH_EXPLAIN}"
  bench service "${BENCH_SERVICE}"
  echo
  info "Compare candidates with the same -n. Differences at n<6 are usually noise."
}

# Sourceable so the individual matchers can be exercised without a model —
# same pattern as scripts/tune.sh, scripts/apply.sh and scripts/motd.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
# scripts/speed.sh — measure how fast this machine actually generates tokens,
# and say plainly whether that is normal or something is wrong.
#
# docs/PERFORMANCE.md ends with "a change you cannot measure is not an
# improvement" and then hands you a curl|jq snippet. This is that snippet grown
# up: it measures, remembers the last result so you can compare, and names the
# single highest-impact thing to change.
#
#   lca speed              measure and give a verdict
#   lca speed --tokens 200 longer sample (slower, steadier number)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_env

# Counting is used as the benchmark prompt on purpose: it never stops early, so
# the sample is always the full num_predict. A prompt like "write a haiku"
# finishes in ~19 tokens and gives a noisy, unrepresentative number.
BENCH_PROMPT="Count from 1 to 200, separated by commas."

STATE_DIR="${HOME}/.cache/local-code-agent"
BASELINE="${STATE_DIR}/speed-baseline"

usage() {
  cat <<EOF
Usage: lca speed [--tokens N] [-m MODEL]

  --tokens N   how many tokens to generate for the measurement (default 80)
  -m MODEL     measure MODEL instead of the configured one (${MODEL_NAME})

Measures generation speed with the model's own timing counters, compares it
against the last run, and explains what limits it on this machine.

Comparing two models before committing to one:
  lca speed -m qwen2.5-coder:3b
  lca speed -m qwen2.5-coder:7b
EOF
}

# swap_in_use_mb — MiB of swap the Ollama server itself is using. Reading the
# process rather than the system total matters: swap used by something else is
# not what makes inference crawl, and reporting it would send the user chasing
# the wrong thing.
swap_in_use_mb() {
  local pid kb=""
  pid="$(pgrep -x ollama 2>/dev/null | head -1 || true)"
  if [[ -n "${pid}" && -r "/proc/${pid}/status" ]]; then
    kb="$(awk '/^VmSwap:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
  fi
  [[ "${kb}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' $(( kb / 1024 ))
}

main() {
  local tokens=80 arg
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --tokens) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--tokens needs a number"; tokens="$2"; shift 2 ;;
      # A flag rather than the MODEL_NAME environment variable, which load_env
      # overwrites from .env — see the same note in ask.sh.
      -m|--model) [[ -n "${2:-}" ]] || die "-m needs a model name"; MODEL_NAME="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) arg="$1"; usage >&2; die "Unknown option: ${arg}" ;;
    esac
  done

  require_cmd curl jq
  ensure_ollama_up_announced 60 || true
  wait_for_ollama 5 >/dev/null 2>&1 \
    || die "Ollama is not answering at $(ollama_url). Try: lca check"
  model_present "${MODEL_NAME}" \
    || die "Model '${MODEL_NAME}' is not downloaded. $(pull_advice "${MODEL_NAME}")"

  step "Measuring generation speed"
  info "Model:  ${MODEL_NAME}"
  info "RAM:    $(detect_ram_gib) GiB"

  # measure TOKENS — POST a benchmark request and echo the raw JSON response.
  measure() {
    local n="$1" payload
    payload="$(jq -n --arg m "${MODEL_NAME}" --arg p "${BENCH_PROMPT}" --arg n "${n}" \
      '{model:$m, prompt:$p, stream:false, options:{num_predict:($n|tonumber)}}')"
    curl -sS --max-time 900 -X POST "$(ollama_url)/api/generate" \
      -H 'Content-Type: application/json' -d "${payload}"
  }

  # Measure a WARM model. A cold start drags the model in from disk, and that
  # first request's prompt-eval rate is dominated by warm-up rather than by the
  # machine — reporting it would understate reading speed several-fold. What the
  # user actually experiences mid-session is the warm number, so load the model
  # first and report the load cost separately.
  local load_ns=0 warm
  if [[ -z "$(ollama_processor "${MODEL_NAME}" 2>/dev/null || true)" ]]; then
    info "Loading the model into RAM first — this is the one-off cost of the first message..."
    warm="$(measure 1)" || die "The request to Ollama failed. Is the service healthy? Try: lca check"
    load_ns="$(jq -r '.load_duration // 0' <<<"${warm}")"
  fi

  info "Generating ${tokens} tokens — this takes about as long as one real answer..."
  local response
  response="$(measure "${tokens}")" \
    || die "The request to Ollama failed. Is the service healthy? Try: lca check"

  # Reading speed gets its OWN request, with a big prompt that differs every
  # run — see read_probe_prompt(). Taking it from the generation request above
  # measured a cached 43-token prefix and reported 160-213 tokens/second on a
  # machine that reads at 20.
  #
  # It costs about half a minute and it is the half of the answer that actually
  # explains a slow code edit, so it is not optional. Announced, because a
  # silent extra wait in a benchmark reads as a hang.
  info "Reading a realistic prompt — this is what a code edit really waits on..."
  local read_response read_count read_ns read_tps=""
  read_response="$(read_probe_prompt | jq -Rs --arg m "${MODEL_NAME}" \
      '{model:$m, prompt:., stream:false, options:{num_predict:1}}' \
    | curl -sS --max-time 900 -X POST "$(ollama_url)/api/generate" \
        -H 'Content-Type: application/json' -d @- || true)"
  read_count="$(jq -r '.prompt_eval_count // 0' <<<"${read_response}" 2>/dev/null || echo 0)"
  read_ns="$(jq -r '.prompt_eval_duration // 0' <<<"${read_response}" 2>/dev/null || echo 0)"

  # Deliberately NOT reading prompt_eval_* off this response. That is where the
  # 160-213 tokens/second came from: this request re-sends the same 43-token
  # benchmark prompt every run, so Ollama answers its prefix from cache and the
  # counters describe the cache, not the machine. The probe above is the only
  # honest source, and leaving these here to be picked up again by accident is
  # how the bug would come back.
  local eval_count eval_ns
  eval_count="$(jq -r '.eval_count // empty' <<<"${response}")"
  eval_ns="$(jq -r '.eval_duration // empty' <<<"${response}")"
  [[ -n "${eval_count}" && -n "${eval_ns}" ]] \
    || die "Ollama did not return timing counters. Response: $(head -c 200 <<<"${response}")"

  local tps
  tps="$(tokens_per_second "${eval_count}" "${eval_ns}")" \
    || die "Could not compute a rate from ${eval_count} tokens in ${eval_ns}ns."

  # Placement is the single biggest determinant of what "normal" means here, so
  # everything below is interpreted through it.
  # Classified against the hardware, not off the string. "It contains a slash,
  # therefore split across CPU and GPU" is a statement about a card, and this
  # asked no question about whether one exists — so on a CPU-only box, where
  # Ollama 0.32.5 prints "13%/87% CPU/GPU", the verdict below told the reader
  # their model was partly offloaded and offered to size one to their VRAM.
  # Measured here at 5.3 tokens/second on 7b: plain CPU inference.
  local placement="" where="cpu"
  placement="$(ollama_processor "${MODEL_NAME}" 2>/dev/null || true)"
  case "$(gpu_state_for_placement "${placement}")" in
    split)  where="split" ;;
    active) where="gpu" ;;
    *)      where="cpu" ;;
  esac

  step "Results"
  printf '  generation      %s tokens/second\n' "${tps}"
  if [[ "${read_count}" =~ ^[0-9]+$ ]] && (( read_count > 200 )) && (( read_ns > 0 )); then
    read_tps="$(tokens_per_second "${read_count}" "${read_ns}")"
    printf '  reading input   %s tokens/second (over %s tokens)\n' "${read_tps}" "${read_count}"
  fi
  # The two rates are inputs, not an answer. Somebody runs this because a code
  # edit felt slow, and neither number tells them how slow an edit is — they
  # would have to already know aider sends ~2.8k tokens, and the reason they
  # are here is that they do not.
  #
  # Computed from the rates just measured, so it is this machine's number: the
  # 3b rung on a base droplet is faster on both counts and says so.
  local edit_s
  if [[ -n "${read_tps}" ]] && edit_s="$(aider_edit_seconds "${read_tps}" "${tps}")"; then
    printf '  one code edit   ~%s  (aider sends ~%s tokens and gets ~%s back: %ss reading, %ss writing)\n' \
      "$(human_duration "${edit_s}")" \
      "$(awk -v t="${LCA_EDIT_PROMPT_TOKENS}" 'BEGIN { printf "%.1fk", t / 1000 }')" \
      "${LCA_EDIT_REPLY_TOKENS}" \
      "$(awk -v t="${LCA_EDIT_PROMPT_TOKENS}" -v r="${read_tps}" 'BEGIN { printf "%d", t / r }')" \
      "$(awk -v t="${LCA_EDIT_REPLY_TOKENS}" -v g="${tps}" 'BEGIN { printf "%d", t / g }')"
  fi
  local load_s=""
  if [[ "${load_ns}" =~ ^[0-9]+$ ]] && (( load_ns > 1000000000 )); then
    load_s="$(awk -v n="${load_ns}" 'BEGIN { printf "%.1f", n / 1000000000 }')"
    printf '  first message   %ss extra to load the model (only after it goes idle — OLLAMA_KEEP_ALIVE=%s)\n' \
      "${load_s}" "${OLLAMA_KEEP_ALIVE:-30m}"
  fi
  printf '  running on      %s\n' "${placement:-unknown (model not resident — run again)}"
  # Ollama's own words, quoted verbatim above — and on a machine with no card
  # they name a device that is not there. Say so on the line below rather than
  # leaving the reader to reconcile "87% GPU" with a CPU verdict further down.
  if [[ "${where}" == "cpu" && "${placement}" == *GPU* ]]; then
    printf '                  (no NVIDIA GPU on this machine — that is Ollama'"'"'s own memory split, not a card)\n'
  fi

  # On CPU, generation is memory-bandwidth bound: every token reads the whole
  # model out of RAM. Reporting the implied bandwidth turns an abstract
  # tokens/second into a number that can be judged, and it is comparable across
  # model sizes in a way that tokens/second is not.
  local params gbs=""
  if params="$(model_params_b "${MODEL_NAME}")"; then
    gbs="$(awk -v t="${tps}" -v p="${params}" 'BEGIN { printf "%.1f", t * p * 0.6 }')"
    printf '  memory traffic  %s GB/s (%sB model at ~0.6 GB per billion)\n' "${gbs}" "${params}"
  fi

  # Compare against the previous run before overwriting it.
  echo
  if [[ -r "${BASELINE}" ]]; then
    local prev_model prev_tps
    # shellcheck disable=SC1090
    prev_model="$(awk -F= '/^model=/ {print $2}' "${BASELINE}")"
    prev_tps="$(awk -F= '/^tps=/ {print $2}' "${BASELINE}")"
    if [[ "${prev_model}" == "${MODEL_NAME}" && -n "${prev_tps}" ]]; then
      # +/-10% is deliberately wide. Back-to-back runs on the same machine
      # vary by a few percent (other processes, a shared-VM neighbour), and
      # reporting that as "slower" would send someone hunting a regression
      # that is really just noise.
      awk -v now="${tps}" -v was="${prev_tps}" 'BEGIN {
        d = (was > 0) ? (now - was) / was * 100 : 0
        if (d > 10)       printf "  vs last run:    %.1f -> %.1f tok/s (%+.0f%% — faster)\n", was, now, d
        else if (d < -10) printf "  vs last run:    %.1f -> %.1f tok/s (%+.0f%% — slower)\n", was, now, d
        else              printf "  vs last run:    %.1f -> %.1f tok/s (no real change)\n", was, now
      }'
    elif [[ -n "${prev_model}" ]]; then
      printf '  vs last run:    not comparable (last run used %s)\n' "${prev_model}"
    fi
  fi
  # Not bare under 'set -e'. ~/.cache/local-code-agent becomes root-owned the
  # moment anything here is run once under sudo, and a failed write then killed
  # this script between the numbers and the verdict — losing the one section
  # that says what they mean. A baseline is a nicety; the explanation is the
  # command.
  # Subshell, not a group: a redirect that cannot open its target is reported
  # by bash before a group's own '2>/dev/null' applies, so the raw error would
  # print above the warning that explains it.
  if ! ( mkdir -p "${STATE_DIR}" \
         && printf 'model=%s\ntps=%s\nplacement=%s\n' \
              "${MODEL_NAME}" "${tps}" "${placement}" > "${BASELINE}" ) 2>/dev/null; then
    warn "Could not save this result to ${BASELINE}, so the next run has nothing to compare against. Check who owns it: ls -ld ${STATE_DIR}"
  fi

  # ---- verdict -----------------------------------------------------------
  # Ordered by impact: report the thing that actually dominates, not a list.
  step "What this means"
  local swap_mb=""
  swap_mb="$(swap_in_use_mb || true)"

  # A long load is felt on EVERY first message of a session, so it is worth
  # naming even when generation speed is fine — and unlike generation speed it
  # can be removed outright. Verified against Ollama: keep_alive=-1 shows
  # "Forever" in the UNTIL column of 'ollama ps'.
  if [[ -n "${load_s}" ]] && awk -v s="${load_s}" 'BEGIN { exit !(s > 5) }' \
     && [[ "${OLLAMA_KEEP_ALIVE:-30m}" != -* ]]; then
    info "Every first message after ${OLLAMA_KEEP_ALIVE:-30m} idle waits ${load_s}s for this load."
    info "To pay it once and never again, set OLLAMA_KEEP_ALIVE=-1 in .env, then: sudo lca apply"
    info "(the model then stays in RAM permanently)"
  fi

  if [[ "${swap_mb}" =~ ^[0-9]+$ ]] && (( swap_mb > 256 )); then
    warn "Ollama has ${swap_mb} MiB swapped out — the model does not fit in RAM."
    info "This costs far more than anything else on this page. Take a smaller model:"
    info "  lca model --list-recommended"
  elif [[ "${where}" == "split" ]]; then
    warn "The model is split across CPU and GPU (${placement})."
    info "A partly-offloaded model runs close to CPU speed — the CPU half sets the pace."
    local vram fits
    if vram="$(gpu_vram_mib)" && fits="$(largest_model_for_vram "${vram}")"; then
      info "Your card has $(( vram / 1024 )) GB of VRAM, which fits a model up to about ${fits}B entirely."
      info "Pick one at or below that and expect several times this speed:"
    else
      info "A model that fits your VRAM completely will be several times faster:"
    fi
    info "  lca model --list-recommended"
  elif [[ "${where}" == "gpu" ]]; then
    if awk -v t="${tps}" 'BEGIN { exit !(t < 15) }'; then
      warn "On the GPU but only ${tps} tokens/second — that is low for GPU inference."
      info "Usually the card is busy, thermally throttled, or sharing VRAM with a display."
    else
      ok "${tps} tokens/second on the GPU — this is working as intended."
    fi
  else
    # CPU. Judge the memory bandwidth rather than tokens/second: tok/s is
    # meaningless without the model size, but any server-class machine should
    # move well over 8 GB/s from RAM.
    if [[ -n "${gbs}" ]] && awk -v g="${gbs}" 'BEGIN { exit !(g < 8) }'; then
      warn "Only ${gbs} GB/s of memory traffic — below what RAM alone should manage."
      info "Something is competing for this machine: another heavy process, a noisy"
      info "neighbour on a shared VM, or swap. Check with: top"
    else
      ok "${tps} tokens/second on the CPU${gbs:+ (${gbs} GB/s)} — normal for CPU inference."
    fi
    if [[ -n "${params}" ]] && (( params > 3 )); then
      info "Want it faster today? A smaller model is the only big CPU-side lever:"
      info "  lca model --list-recommended"
    fi
    # Said here because the line above is the right answer for a CHAT reply and
    # the wrong emphasis for a code edit. Most of an edit is Ollama reading
    # aider's prompt, and that prompt is mostly aider's own scaffolding — so
    # trimming what gets sent is a lever, and one nothing here ever mentioned.
    #
    # Deliberately not oversold: CONVENTIONS.md is 253 tokens of ~2,800
    # (measured), so it is a tenth. Saying "a tenth" is worth more than
    # implying a switch makes this fast.
    if [[ -n "${read_tps}" ]]; then
      info "Most of a code edit is Ollama READING aider's prompt, not writing the reply."
      info "  Send less: a smaller repo map, or AIDER_CONVENTIONS=false in .env"
      info "  (worth about a tenth of the prompt — a trim, not a fix)."
    fi
    case "$(gpu_state "${MODEL_NAME}")" in
      no-driver)
        warn "An NVIDIA card is in this machine but no working driver was found."
        warn "That is why you are on the CPU. Fixing it is worth roughly 10x — see docs/GPU.md."
        ;;
      idle)
        warn "The NVIDIA driver works, but Ollama is still using the CPU."
        warn "Usually the model is too big for VRAM, or Ollama cannot see the card. See docs/GPU.md."
        ;;
      *)
        info "The one change that beats everything else is a GPU — see docs/GPU.md."
        ;;
    esac
  fi
}

main "$@"

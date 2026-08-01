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
      *) arg="$1"; usage; die "Unknown option: ${arg}" ;;
    esac
  done

  require_cmd curl jq
  ensure_ollama_up_announced 60 || true
  wait_for_ollama 5 >/dev/null 2>&1 \
    || die "Ollama is not answering at $(ollama_url). Try: lca check"
  model_present "${MODEL_NAME}" \
    || die "Model '${MODEL_NAME}' is not downloaded. Pull it with: ollama pull ${MODEL_NAME}"

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

  local eval_count eval_ns prompt_count prompt_ns
  eval_count="$(jq -r '.eval_count // empty' <<<"${response}")"
  eval_ns="$(jq -r '.eval_duration // empty' <<<"${response}")"
  prompt_count="$(jq -r '.prompt_eval_count // 0' <<<"${response}")"
  prompt_ns="$(jq -r '.prompt_eval_duration // 0' <<<"${response}")"
  [[ -n "${eval_count}" && -n "${eval_ns}" ]] \
    || die "Ollama did not return timing counters. Response: $(head -c 200 <<<"${response}")"

  local tps
  tps="$(tokens_per_second "${eval_count}" "${eval_ns}")" \
    || die "Could not compute a rate from ${eval_count} tokens in ${eval_ns}ns."

  # Placement is the single biggest determinant of what "normal" means here, so
  # everything below is interpreted through it.
  local placement="" where="cpu"
  placement="$(ollama_processor "${MODEL_NAME}" 2>/dev/null || true)"
  if [[ "${placement}" == *"/"* ]]; then
    where="split"
  elif [[ "${placement}" == *GPU* ]]; then
    where="gpu"
  fi

  step "Results"
  printf '  generation      %s tokens/second\n' "${tps}"
  if [[ "${prompt_count}" =~ ^[0-9]+$ ]] && (( prompt_count > 0 )) && (( prompt_ns > 0 )); then
    printf '  reading input   %s tokens/second\n' "$(tokens_per_second "${prompt_count}" "${prompt_ns}")"
  fi
  local load_s=""
  if [[ "${load_ns}" =~ ^[0-9]+$ ]] && (( load_ns > 1000000000 )); then
    load_s="$(awk -v n="${load_ns}" 'BEGIN { printf "%.1f", n / 1000000000 }')"
    printf '  first message   %ss extra to load the model (only after it goes idle — OLLAMA_KEEP_ALIVE=%s)\n' \
      "${load_s}" "${OLLAMA_KEEP_ALIVE:-30m}"
  fi
  printf '  running on      %s\n' "${placement:-unknown (model not resident — run again)}"

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
  mkdir -p "${STATE_DIR}"
  printf 'model=%s\ntps=%s\nplacement=%s\n' "${MODEL_NAME}" "${tps}" "${placement}" > "${BASELINE}"

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
    info "To pay it once and never again, set OLLAMA_KEEP_ALIVE=-1 in .env and re-run"
    info "scripts/install_ollama.sh — the model then stays in RAM permanently."
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

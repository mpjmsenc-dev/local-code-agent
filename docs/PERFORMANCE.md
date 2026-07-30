# Performance — making it faster, honestly

Local inference on a CPU is a reading pace, not instant. This page explains what
actually controls the speed, in the order that matters, so you can spend effort
where it pays.

## First: find out what you are actually running on

```bash
./check-system.sh          # reports CPU vs GPU placement for your model
lca test                   # same, as part of the end-to-end self-test
```

Look for a line like `model 'qwen2.5-coder:7b' is running on the GPU (100% GPU)`
or `... on the CPU (100% CPU)`. Everything below depends on which one you see —
guessing here wastes the most time.

## The one change that matters most: a GPU

Nothing else is close. A model that fits entirely in VRAM runs roughly an order
of magnitude faster than the same model on CPU — the difference between reading
pace and a response that feels immediate.

| Situation | What to expect |
|---|---|
| CPU only (a DigitalOcean Basic droplet) | a few tokens/second; usable, deliberate |
| GPU, model fits in VRAM (`100% GPU`) | tens of tokens/second |
| GPU, model too big (`38%/62% CPU/GPU`) | barely better than CPU — the CPU part dominates |

A real measurement, not a guess: on a CPU-only x86_64 box with 16 GiB RAM,
`qwen2.5-coder:7b` produced **~6 tokens/second** using the snippet at the bottom
of this page. Use that as your baseline — if you measure much less, something
else is wrong (swap, a too-large model, a busy machine).

That last row is the trap. A partially-offloaded model is **not** "most of the
speed". If you have a GPU, prefer a model that fits its VRAM completely:

| VRAM | Fits comfortably at q4 |
|---|---|
| 8 GB | 7–8B |
| 12 GB | 13–14B |
| 24 GB (e.g. RTX 3090) | 14B easily; 32B is tight but usually fits |

You do **not** need a GPU for this stack to work — it is designed around CPU
inference and auto-tune picks a model your RAM can actually run. A GPU is a
comfort upgrade, not a requirement.

## If you are on CPU

In descending order of impact:

**1. Use a smaller model.** This is the biggest CPU-side lever by far. Speed
scales roughly with parameter count: a 3B model answers about 4–5× faster than a
14B one. For short edits and questions the smaller model is often good enough.

```bash
./update-model.sh --list-recommended    # what fits this machine
./update-model.sh qwen2.5-coder:3b      # pin a smaller one
```

**2. Keep the context small.** Every token in the prompt is work. `run-agent.sh`
already sizes aider's repo map to your window, but you control the rest:

- In aider, `/clear` drops old history, and `/drop` removes files you are done
  with. A long session gets slower as history grows.
- Add specific files rather than whole directories.
- `OLLAMA_CONTEXT_LENGTH` in `.env` caps the window. Bigger is not better on CPU:
  it costs memory and time whether or not you use it.

**3. Keep the model warm.** The first request after idle pays the load time
(seconds to a minute). `OLLAMA_KEEP_ALIVE` (default `30m`) controls how long it
stays resident. Raise it if you work in bursts and have RAM to spare; lower it
if the box is doing other things.

**4. More cores help, more RAM does not.** Ollama uses every core automatically —
nothing to configure. Extra RAM beyond what the model needs does not make
inference faster; it only lets auto-tune choose a *bigger* (slower) model on the
next boot. If you resized for RAM and it got slower, that is why.

## What will not help

- **Quantization fiddling.** Ollama's default tags are already q4-ish, which is
  the sensible speed/quality point. Chasing q2 saves little and costs noticeably
  in output quality — on a small local model you cannot spare it.
- **Running two models at once.** `OLLAMA_MAX_LOADED_MODELS=1` is set on purpose;
  a second resident model competes for the same RAM and cores.
- **Swap.** If a model does not fit in RAM it will "work" via swap at
  unusable speed. `check-system.sh` warns about the RAM headroom instead —
  believe it, and take a smaller model.

## Measuring, not guessing

```bash
ollama ps    # PROCESSOR column: 100% GPU / 100% CPU / a split
```

For a rough tokens/second number, time a fixed prompt:

```bash
time curl -s http://127.0.0.1:11434/api/generate \
  -d '{"model":"'"$(grep ^MODEL_NAME= .env | cut -d= -f2)"'","prompt":"Write a haiku about disks.","stream":false}' \
  | jq -r '.eval_count, .eval_duration' 
# tokens/second ≈ eval_count / (eval_duration / 1e9)
```

Compare that number before and after a change. A change you cannot measure is
not an improvement.

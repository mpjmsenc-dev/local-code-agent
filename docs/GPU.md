# GPU.md — adding a graphics card, and proving it is being used

A GPU is the one change that makes local inference feel instant instead of
deliberate. It is also the change most often *believed* to have worked when it
has not: the driver installs, everything keeps running, and the model quietly
stays on the CPU. This page is about proving it, not assuming it.

Nothing here is required. The stack is designed around CPU inference and works
without a card.

## First: which situation are you in?

```bash
lca speed
```

The `running on` line is the answer, and `lca speed` names the situation
directly. There are five, and they need completely different fixes:

| What you see | What it means | Fix |
|---|---|---|
| `100% GPU` | Working. | Nothing. |
| `100% CPU`, no card | No GPU in the machine. | Add one, or stay on CPU. |
| `100% CPU`, card present, no driver | The silent case — everything works, 10× slower, nothing complains. | Install the driver (below). |
| `100% CPU`, driver works | Ollama cannot use the card, or the model does not fit VRAM. | See "Driver works but Ollama ignores it". |
| `38%/62% CPU/GPU` | Partially offloaded. **Not** "most of the speed" — the CPU half sets the pace. | Use a smaller model (below). |

## Choosing a model that actually fits

This is the mistake worth avoiding. A model that spills out of VRAM runs at
close to CPU speed, so a 32B model on a 24 GB card can easily be *slower* than a
14B one that fits entirely.

Roughly, a q4 model needs **0.6 GB per billion parameters**, plus ~1.5 GB for
context and CUDA overhead:

| VRAM | Fits entirely (q4) | Sensible choice |
|---|---|---|
| 8 GB | up to ~10B | `qwen2.5-coder:7b` |
| 12 GB | up to ~17B | `qwen2.5-coder:14b` |
| 24 GB (RTX 3090 / 4090) | up to ~37B | `qwen2.5-coder:14b` comfortably, `:32b` fits with room to spare |

`lca speed` does this arithmetic for your card and tells you the number.

```bash
lca model qwen2.5-coder:32b     # pins it; auto-tune is disabled and says so
lca speed                       # confirm: '100% GPU', and compare tok/s
```

Auto-tune sizes models by **RAM, not VRAM** — it cannot know what you intend to
run on the card. On a GPU box, pin the model yourself with `lca model`. That is
why pinning turns `AUTO_TUNE` off: otherwise the next reboot would overwrite
your choice.

## Installing the driver (Ubuntu 24.04)

Ubuntu can pick the right driver for you:

```bash
sudo ubuntu-drivers install
sudo reboot
```

After the reboot, the driver is working when this prints your card and its
memory:

```bash
nvidia-smi
```

If `nvidia-smi` is missing or errors, the driver is not loaded — no amount of
Ollama configuration will help until it is. Secure Boot is a common cause: an
unsigned NVIDIA module will refuse to load, and either enrolling the key at the
MOK prompt or disabling Secure Boot in firmware resolves it.

Then restart Ollama so it re-detects the hardware, and confirm:

```bash
sudo systemctl restart ollama
lca speed
```

## Driver works but Ollama ignores it

In order of likelihood:

1. **The model does not fit.** See the table above. This is by far the most
   common cause, and it shows up as a split rather than pure CPU.
2. **Ollama was installed before the driver.** Restart it:
   `sudo systemctl restart ollama`.
3. **Not enough free VRAM.** A desktop session or another process may hold it —
   `nvidia-smi` lists what is using the card.
4. **Ollama's logs say why.** They are explicit about GPU discovery:
   `journalctl -u ollama -n 100 | grep -i -e gpu -e cuda`.

## In a VM (VMware, Proxmox, ESXi)

A virtual machine does not see a host GPU by default. You need **PCI
passthrough**: IOMMU enabled in the host firmware (Intel VT-d / AMD-Vi), the
card bound to a passthrough driver on the host rather than its own, and the
device attached to the guest. Once that is done the guest treats it as ordinary
hardware and everything above applies unchanged.

One detail worth knowing: with passthrough, the card may not appear in the
guest's `lspci` under a recognisable name. `lca speed` handles this — it trusts
a working `nvidia-smi` over `lspci`, so a passed-through card is reported
correctly rather than as "no GPU".

## Was it worth it?

```bash
lca speed
```

It remembers your previous run and prints the delta, so the before/after is a
number rather than an impression. Expect roughly an order of magnitude going
from CPU to a fully-offloaded model — from a reading pace to a response that
arrives as fast as you can read it.

If the number did not move, you are still on the CPU. Go back to the table at
the top.

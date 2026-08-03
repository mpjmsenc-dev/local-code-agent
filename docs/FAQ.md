# FAQ.md

**Is my data really private?**
Yes. Models run on your VM; prompts and code never leave it. Aider is configured
with telemetry/analytics off (`config/aider.conf.yml`), and Open WebUI is started
with `DO_NOT_TRACK`, `SCARF_NO_ANALYTICS` and `ANONYMIZED_TELEMETRY` set so it
does not phone home either. Phone access rides an encrypted Tailscale tunnel, and
`netmode.sh offline` gives you a provable guarantee: the stack physically cannot
reach the internet, and chat still works.

**Is this as good as Claude?**
No — see "Honest expectations" in the [README](../README.md). A 7b/14b local
model is a capable junior assistant, not a frontier model. It shines on
boilerplate, small edits, explanations, and privacy-critical work.

**Can the phone chat build me a whole app?**
No, and it will tell you so rather than pretending. The chat is a text box with
no filesystem — it cannot create files, run commands or see your project, and
that limit is about the door, not the model: more RAM buys a bigger model, not
the ability to write files. Asked to build something it hands the job to the
one thing here that can, which is aider:

```bash
# in a terminal on the server (SSH in from your phone)
mkdir -p ~/my-project && cd ~/my-project && lca
```

`lca chat` prints that SSH address as a QR code next to the chat one, so the
phone can reach both. Note `lca ask` is *not* it — that is one-shot text, the
same as the chat. What the chat is genuinely good at: explaining an error,
reviewing a snippet you paste, writing one complete file you copy, and
answering questions about this box.

If yours instead writes a long setup tutorial it never finishes, it is running
an older assistant prompt — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md), or just run `lca check`.

**What does it cost?**
Only the server. A 4 vCPU / 8 GB DO Basic droplet runs at DO's standard monthly
price (per-second billing; powered-off droplets still bill — see
[DO.md](DO.md)). There are no per-token or per-seat costs — no AI API is involved.

**Can I use a different model than qwen2.5-coder?**
Yes: `./update-model.sh <any-ollama-model>` (browse ollama.com/library). It
pulls, validates with a real generation, and only then makes it the default —
and pins it (`AUTO_TUNE=false`) so a reboot won't override your choice.

**Why is the first answer after a pause slow?**
The model is loaded into RAM on demand and unloaded after `OLLAMA_KEEP_ALIVE`
(default 30m) of idleness. The first request pays the load time.

**Why does it "forget" earlier messages in a long chat, or lose track in a big file?**
Local models have a fixed context window (`OLLAMA_CONTEXT_LENGTH`, set by
auto-tune per the RAM ladder: 4096–16384 tokens). Everything shares it — the
system prompt, chat history, open files, aider's repo map, and the reply.
`run-agent.sh` tells aider the *real* window size, so aider trims the oldest
history to stay within budget instead of letting Ollama silently drop it. Keep
sessions focused (aider's `/clear`, close finished files); for a bigger window,
add RAM and auto-tune raises the rung on the next boot.

**Can several people use it?**
Open WebUI supports multiple accounts (as admin, create them — keep public
signups locked). They share one model server, so heavy simultaneous use queues.

**Does offline mode break chat from my phone?**
No — that's the point. The phone reaches WebUI over Tailscale, which stays open;
inference is local. Only outbound internet (updates, model pulls, any telemetry)
is cut.

**Do I need a GPU?**
No, everything here is CPU-tuned. With an NVIDIA GPU, Ollama uses it
automatically — the rest of the stack is unchanged.

**How do I update the software?**
`git -C /opt/local-code-agent pull` then re-run `./setup.sh` (idempotent —
it upgrades OS packages, aider, and recreates the WebUI container from the
latest image). Models update with `ollama pull <model>`.

**Can I run this on the free Oracle Cloud / other clouds / my own hardware?**
Any Ubuntu 24.04 / Debian VM with systemd works, x86_64 or arm64 — see
[INSTALL.md](INSTALL.md). On arm64 the same scripts run unchanged.

**Where is my data if I want to move or leave?**
`./backup.sh` produces one tarball with your chats, config, and model list;
[MIGRATE.md](MIGRATE.md) walks the move. No lock-in anywhere in the stack.

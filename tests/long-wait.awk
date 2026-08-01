# tests/long-wait.awk — find long waits for an Ollama that nobody started.
#
# 'wait_for_ollama N' with a two- or three-digit N only POLLS; it starts
# nothing. Reaching for it without first starting the server is how 'lca' came
# to sit silent for 60 seconds on any host without systemd, waiting for
# something nothing was starting, and then advise 'systemctl restart' on a box
# that has no systemd.
#
# A long wait is legitimate only when the code has just STARTED what it is
# waiting for — install_ollama.sh, restart_ollama and start_ollama_bg all do
# exactly that. Printing something first is NOT enough, and was tried: with
# 'info|warn|step' in the allow list, a 60-second silent poll under the heading
# "==> Switching default model" counted as announced, which is the bug wearing
# a hat. The mutation that exposed that is in tests/test-lib.sh.
#
# FNR, not NR: NR keeps counting across files, so the reported line numbers
# pointed into the middle of nowhere (setup.sh:1488 for a 150-line script).
FNR == 1 { delete hist }
{ hist[FNR] = $0 }

/wait_for_ollama ([1-9][0-9]|[0-9][0-9][0-9])/ && $0 !~ /^[[:space:]]*#/ {
  allowed = 0
  for (i = FNR - 5; i <= FNR; i++) {
    if (i < 1) continue
    # Comments are not evidence. Skipping this let a mutation through: the
    # comment ABOVE the bare wait explained the announced helper by name, and
    # the rule read its own prose as proof the server had been started.
    if (hist[i] ~ /^[[:space:]]*#/) continue
    if (hist[i] ~ /systemctl (re)?start ollama/) allowed = 1
    if (hist[i] ~ /nohup ollama serve/)          allowed = 1
    if (hist[i] ~ /ensure_ollama_up/)            allowed = 1
  }
  if (!allowed) printf "%s:%d:%s\n", FILENAME, FNR, $0
}

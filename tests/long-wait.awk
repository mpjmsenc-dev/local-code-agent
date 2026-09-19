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
# a hat.
#
# Every rule below is DRIVEN, one fixture each, by
# 'the long-wait scanner reports what it must and excuses what it must' in
# tests/test-lib.sh. That gate did not exist until an audit asked what was
# exercising this file and found the answer was nothing: the scanner was run
# once, over the real tree, and a tree with no offending line cannot tell a
# working scanner from a broken one. This header used to claim the mutation
# lived in the suite. It did not.
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
    # A start spelled across lines. start_ollama_bg builds its environment from
    # config/ollama.env, so the command is "nohup env \ ... \ ollama serve
    # >LOG 2>&1 &". Anchored on the trailing '&': that is what makes it a START
    # rather than a sentence about one, so a warn() that merely tells the
    # reader to run 'ollama serve' still counts as silence.
    #
    # An unanchored /nohup ollama serve/ sat here as well, left behind when the
    # command changed shape. It matched nothing this scanner visits, so it
    # looked harmless — but it excused any line CONTAINING those words, which
    # is exactly the warn() the sentence above says must not be excused. A rule
    # that never fires is not a rule that does nothing; it is a rule nobody has
    # checked. Removed, and the case it used to let through is now a fixture.
    if (hist[i] ~ /ollama serve.*&[[:space:]]*$/)  allowed = 1
    if (hist[i] ~ /ensure_ollama_up/)            allowed = 1
  }
  if (!allowed) printf "%s:%d:%s\n", FILENAME, FNR, $0
}

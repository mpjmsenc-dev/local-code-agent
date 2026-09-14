# duplicate-defs.awk — functions a shell script defines more than once.
#
# A test suite here is a linear script, so a second definition silently
# replaces the first: every call before it gets one implementation and every
# call after it gets another, with nothing to say so. url_for was defined twice
# eleven thousand lines apart — once over OLLAMA_HOST, once over WEBUI_PORT —
# and the only thing keeping that from being a wrong answer was that no caller
# happened to sit on the wrong side of the second one.
#
# Two kinds of DATA have to be skipped, because this file is full of both and
# each contains function definitions on purpose:
#
#   a quoted heredoc      — the fixtures, which exist to be scanned
#   a single-quoted string spanning several lines — the shims handed to
#                           restore_sandbox and friends, which are code for
#                           ANOTHER shell, appended to a sandbox's lib.sh
#
# Apostrophe counting is how the second is tracked: an odd number of them on a
# line opens or closes a literal. Comment lines are skipped before counting,
# since an apostrophe in prose is not a quote.

!inhd && !insq && match($0, /<<\x27[A-Za-z_][A-Za-z0-9_]*\x27/) {
  hd = substr($0, RSTART + 3, RLENGTH - 4); inhd = 1; hdline = FNR; next
}
inhd && $0 == hd { inhd = 0; next }
inhd { next }

{
  line = $0
  if (!insq && line ~ /^[[:space:]]*#/) next
  n = gsub(/\x27/, "\x27", line)
  was = insq
  if (n % 2) { insq = !insq; if (insq) sqline = FNR }
  if (was) next
}

match($0, /^[a-z_][a-z0-9_]*\(\) *\{/) {
  fn = $0; sub(/\(\).*/, "", fn)
  count[fn]++
  where[fn] = where[fn] " " FNR
}

# Both skips above are heuristics, and a heuristic that guesses wrong here does
# not produce a false accusation — it produces SILENCE, which reads exactly
# like a clean file. One apostrophe in a double-quoted grep pattern opened a
# literal that never closed, and every line after it went unscanned. Reaching
# the end still inside either state is therefore reported as loudly as a
# duplicate: what follows an unclosed opener was never looked at.
END {
  if (inhd) printf "UNSCANNED: the quoted heredoc opened at line %s never closed, so every line after it was skipped\n", hdline
  if (insq) printf "UNSCANNED: the odd apostrophe at line %s left this scanner inside a literal, so every line after it was skipped\n", sqline
  for (f in count) if (count[f] > 1) printf "%s defined %s times, at lines:%s\n", f, count[f], where[f]
}

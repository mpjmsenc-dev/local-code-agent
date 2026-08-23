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
  hd = substr($0, RSTART + 3, RLENGTH - 4); inhd = 1; next
}
inhd && $0 == hd { inhd = 0; next }
inhd { next }

{
  line = $0
  if (!insq && line ~ /^[[:space:]]*#/) next
  n = gsub(/\x27/, "\x27", line)
  was = insq
  if (n % 2) insq = !insq
  if (was) next
}

match($0, /^[a-z_][a-z0-9_]*\(\) *\{/) {
  fn = $0; sub(/\(\).*/, "", fn)
  count[fn]++
  where[fn] = where[fn] " " FNR
}

END {
  for (f in count) if (count[f] > 1) printf "%s defined %s times, at lines:%s\n", f, count[f], where[f]
}

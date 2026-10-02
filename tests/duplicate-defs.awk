# duplicate-defs.awk — functions a shell script defines more than once.
#
# Run through the shared lexer, which decides what is code and what is data:
#
#   awk -f tests/shell-lex.awk -f tests/duplicate-defs.awk FILE
#
# A test suite here is a linear script, so a second definition silently
# replaces the first: every call before it gets one implementation and every
# call after it gets another, with nothing to say so. url_for was defined twice
# eleven thousand lines apart — once over OLLAMA_HOST, once over WEBUI_PORT —
# and the only thing keeping that from being a wrong answer was that no caller
# happened to sit on the wrong side of the second one.
#
# This file used to do its own quote tracking, by counting apostrophes and
# skipping comment lines before the count. The guard was written against the
# right idea — an apostrophe in prose is not a quote — and applied to the wrong
# scope: it covered '#' comments and not the far commoner case of an apostrophe
# inside a double-quoted string. tests/shell-lex.awk now answers that question
# for every scanner here, and says so loudly when it cannot.

LEX_CODE && match($0, /^[a-z_][a-z0-9_]*\(\) *\{/) {
  fn = $0; sub(/\(\).*/, "", fn)
  count[fn]++
  where[fn] = where[fn] " " FNR
}

END {
  for (f in count) if (count[f] > 1) printf "%s defined %s times, at lines:%s\n", f, count[f], where[f]
}

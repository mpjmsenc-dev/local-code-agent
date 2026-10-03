# tests/shell-lex.awk — where a shell script's own CODE is, and where its DATA
# is. Included ahead of another awk program, whose rules then read LEX_CODE (the
# line STARTS in code) and LEX_ENDS_IN_CODE (it ends there, as the closing line
# of a multi-line quoted program does) instead of each re-deriving the answer
# and each getting it wrong differently:
#
#   awk -f tests/shell-lex.awk -f tests/duplicate-defs.awk FILE
#   awk -f tests/shell-lex.awk -e '<program>'              FILE
#
# It exists because every scanner in tests/ had independently reinvented this
# and four of them were wrong. The duplicate scanner counted apostrophes to
# track single-quoted strings; the apostrophe in the description
#
#   check "...and the suite left the live machine's login banner alone"
#
# is not a quote to the shell — it sits inside double quotes — but it was one
# to the counter, which then read the whole rest of the file as string data and
# reported no duplicates because it could no longer see any definitions at all.
# It was the LAST line of the file, so nothing real followed it and the only
# thing that failed was the gate's own non-vacuity probe, which appends a known
# duplicate and requires the scanner to find it. That probe is the sole reason
# this was not silent.
#
# The other three did not track quoting at all, and a definition inside a
# multi-line single-quoted shim — code for ANOTHER shell, appended to a
# sandbox's lib.sh, at column 0 — reached all of them:
#
#   reachable.awk    reported it as a function nothing calls: a false
#                    accusation, which its own header promises it never makes.
#   source_grep_gates classified it as a real gate that reads repo source.
#   justified_gates   accepted a '# SOURCE-GREP:' marker written inside a shim
#                     as justifying it.
#
# So: one lexer, one fixture (quoting-fixture.sh, which tests/test-lib.sh writes
# into its sandbox), one place to be wrong.
#
# What it tracks, per character, in the states the shell actually has:
#
#   single quotes  nothing escapes inside them; only ' ends one
#   double quotes  a backslash escapes the next character; an apostrophe in
#                  here is TEXT, which is the bug this file was written for
#   backslash      outside quotes, escapes the next character
#   comments       a '#' at the start of a word outside quotes ends the line,
#                  so prose is never lexed. '${x#y}' and '$#' are not comments
#                  because the '#' is not preceded by whitespace.
#   heredoc       <<TAG, <<'TAG', <<"TAG" and the <<- forms are all data until
#                  the terminator. The QUOTED ones were the only kind any
#                  scanner here used to skip, and this file's own end-of-input
#                  check is what found that: scripts/agent-selftest.sh writes
#                  its usage text with a bare <<EOF, and the apostrophe in
#                  "this machine's measured speed" — prose, inside data — put
#                  the lexer inside a single-quoted string for the next sixteen
#                  lines. <<< is a here-string, not a heredoc, and is excluded.
#
#   substitution   "$(...)" re-enters an unquoted context inside the double
#                  quotes, so the quotes within it nest; it ends at its own
#                  matching ')'. $((...)) balances the same way. $'...' is a
#                  single-quoted string in which a backslash escapes.
#
# Command substitution was once left out, on two arguments: that a nested quote
# pair toggles twice either way and leaves the state where it found it, and that
# anything else would reach the END rule below and fail loudly. Neither held.
# model="$(grep -n 'step "4/7' f)" hands a lexer that stays double-quoted an
# ODD number of quotes; it fell out of step there and came back into step at
# some later stray quote, long before the end of the file, so the END rule saw
# nothing. tests/test-lib.sh was read out of step in 17 places — real gates
# as data, awk programs and shims as code — while every scanner here reported a
# clean, confident nothing.

BEGIN { LEX_SQ = sprintf("%c", 39); LEX_DQ = sprintf("%c", 34); LEX_BS = sprintf("%c", 92) }

# Two-pass callers (reachable.awk reads the same file twice) must not inherit
# the first pass's closing state.
FNR == 1 { lex_depth = 0; lex_ctx[0] = "top"; lex_sq = 0; lex_dq = 0; lex_hd = 0; lex_hd_tag = ""; lex_hd_dash = 0 }

{
  # The state at the START of the line decides what the line IS; the scan then
  # advances that state for the next one. Consumers see the former.
  LEX_HEREDOC = lex_hd
  LEX_OPENS_HEREDOC = 0
  if (lex_hd) {
    LEX_CODE = 0
    LEX_ENDS_IN_CODE = 0
    # <<- strips leading TABS from the terminator, and only tabs.
    lex_end = $0
    if (lex_hd_dash) sub(/^\t+/, "", lex_end)
    if (lex_end == lex_hd_tag) { lex_hd = 0; lex_hd_tag = ""; lex_hd_dash = 0 }
  } else {
    # Code is what the shell reads as words: the top level, or inside a $(...)
    # at any depth. Inside quotes it is data, however deep.
    LEX_CODE = (lex_ctx[lex_depth] == "top" || lex_ctx[lex_depth] == "sub")
    if (LEX_CODE) lex_open_heredoc($0)
    # Scanned even when LEX_CODE is 0: that is a line in the middle of a
    # multi-line string, and finding where the string ENDS is the whole job.
    lex_scan($0)
    # A line that STARTS in data can still END in code: the closing line of a
    # multi-line awk program or shim carries the file it runs on and the pipe
    # after it. LEX_CODE alone skipped all of that.
    LEX_ENDS_IN_CODE = (!lex_hd && (lex_ctx[lex_depth] == "top" || lex_ctx[lex_depth] == "sub"))
  }
}

# The opener, in every spelling bash accepts. A here-string is masked out
# first: '<<<foo' contains '<<foo' and would otherwise be read as a heredoc
# whose terminator never comes, which is the silent-blindness failure again.
function lex_open_heredoc(line,   probe, tok) {
  probe = line
  gsub(/<<</, "@@@", probe)
  if (!match(probe, /<<-?[[:space:]]*[\x27"]?[A-Za-z_][A-Za-z0-9_]*/)) return
  tok = substr(probe, RSTART, RLENGTH)
  lex_hd_dash = (tok ~ /^<<-/)
  sub(/^<<-?[[:space:]]*/, "", tok)
  gsub(/[\x27"]/, "", tok)
  lex_hd_tag = tok
  lex_hd = 1
  LEX_OPENS_HEREDOC = 1
}

# A stack of contexts, because quotes nest inside a substitution inside quotes.
# lex_sq and lex_dq are kept, derived, for the END rule's message.
function lex_push(c) { lex_ctx[++lex_depth] = c; lex_paren[lex_depth] = (c == "sub") ? 1 : 0 }
function lex_pop()   { if (lex_depth > 0) lex_depth-- }
function lex_scan(line,   i, n, c, nx, prev, top) {
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1); nx = substr(line, i + 1, 1); top = lex_ctx[lex_depth]
    if (top == "sq")   { if (c == LEX_SQ) lex_pop(); continue }
    if (top == "ansi") { if (c == LEX_BS) { i++; continue }; if (c == LEX_SQ) lex_pop(); continue }
    if (top == "dq") {
      if (c == LEX_BS) { i++; continue }
      if (c == LEX_DQ) { lex_pop(); continue }
      if (c == "$" && nx == "(") { lex_push("sub"); i++ }
      continue
    }
    # The top level, or a substitution: the shell is reading words here.
    if (c == LEX_BS) { i++; continue }
    if (c == "$" && nx == LEX_SQ) { lex_push("ansi"); i++; continue }
    if (c == "$" && nx == "(")    { lex_push("sub"); i++; continue }
    if (c == LEX_SQ) { lex_push("sq"); continue }
    if (c == LEX_DQ) { lex_push("dq"); continue }
    if (top == "sub" && c == "(") { lex_paren[lex_depth]++; continue }
    if (top == "sub" && c == ")") { if (--lex_paren[lex_depth] == 0) lex_pop(); continue }
    if (c == "#") {
      prev = (i == 1) ? " " : substr(line, i - 1, 1)
      if (prev == " " || prev == "\t") break
    }
  }
  lex_sq = (lex_ctx[lex_depth] == "sq" || lex_ctx[lex_depth] == "ansi")
  lex_dq = (lex_ctx[lex_depth] == "dq")
}

# The failure this whole file is about was SILENT: a scanner that stops seeing
# code reports nothing and reads exactly like a scanner that found nothing. A
# file that ends inside a quote is either malformed or lexed wrongly, and
# either way every verdict after that point is worthless — so say so and exit
# non-zero instead of printing an empty, confident answer.
#
# This END rule runs before the consumer's, because this file is named first.
END {
  if (lex_hd) {
    printf("shell-lex.awk: reached the end of %s inside a heredoc opened with <<%s%s%s — every verdict past that point was computed over data\n",
           FILENAME, LEX_SQ, lex_hd_tag, LEX_SQ) > "/dev/stderr"
    exit 2
  }
  if (lex_depth > 0) {
    printf("shell-lex.awk: reached the end of %s still inside %s — the scanner stopped seeing code there, and anything it reported after it is worthless\n",
           FILENAME, (lex_sq ? "a single-quoted string" : lex_dq ? "a double-quoted string" : "a $(...) substitution")) > "/dev/stderr"
    exit 2
  }
}

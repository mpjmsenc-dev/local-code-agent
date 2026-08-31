# reachable.awk — the functions a shell script defines that nothing can reach.
#
# Run through the shared lexer, and give it the SAME file twice: the first pass
# collects the definitions, the second builds the call graph over names it now
# knows.
#
#   awk -f tests/shell-lex.awk -f tests/reachable.awk FILE FILE
#
# It exists because a gate that is defined and never run passes, having done
# nothing — which is the defect this whole suite is about, turned on itself.
# Converting install_is_truncation_safe to a driven test dropped the 'check'
# line that ran it, and nothing noticed.
#
# Roots are top-level mentions: a 'check' invocation, or any call made outside
# a function body. An edge is a name mentioned inside a function body. Both are
# matched as bare words, which is generous — a name inside a string counts as a
# call — so this errs towards calling things reachable. False silence, never a
# false accusation.
#
# That promise was not kept until tests/shell-lex.awk existed. This file skipped
# quoted heredocs and nothing else, so a definition at column 0 inside a
# multi-line single-quoted shim — code for ANOTHER shell, appended to a
# sandbox's lib.sh — was collected as one of this file's own functions, and
# then reported as dead because nothing in this file calls it. A false
# accusation, in the one scanner whose header promises it cannot make one.

# Names something other than this file calls. Anything listed here is excused
# from the report, so it carries its reason. The list lives in the scanner
# rather than beside the gate because a shell array naming these would itself
# be a top-level mention — the exemption would root them, and the exemption
# machinery would then be doing nothing.
BEGIN {
  exempt["command_not_found_handle"] = "bash calls it for any unqualified name it cannot resolve"
}

# --- pass 1: what does this file define? ------------------------------------
FNR == NR {
  if (LEX_CODE && match($0, /^[a-z_][a-z0-9_]*\(\) *\{/)) {
    fn = $0; sub(/\(\).*/, "", fn); defined[fn] = 1
  }
  next
}

# --- pass 2: who mentions whom? ---------------------------------------------
# The line that OPENS a heredoc is still code, and in this suite it is
# routinely the check line naming the gate whose fixture follows. Scan it; the
# lexer marks the data underneath as not-code and the next rule drops it.
LEX_OPENS_HEREDOC { scan($0, ($0 ~ /^check[[:space:]]/) ? "" : cur); next }
# Heredoc bodies are dropped, as they always were. Lines inside a multi-line
# QUOTED STRING are not: this pass is deliberately generous — "a name inside a
# string counts as a call" is the whole reason it errs towards silence — and
# skipping them cost twelve live gates their only mention and reported every
# one of them as dead. Only pass 1 above needs LEX_CODE, because what a
# definition inside data is not is a definition.
LEX_HEREDOC { next }
/^[[:space:]]*#/ { next }

# LEX_CODE here so a definition written inside a shim cannot take ownership of
# the real lines that follow it.
LEX_CODE && match($0, /^[a-z_][a-z0-9_]*\(\) *\{/) {
  cur = $0; sub(/\(\).*/, "", cur)
  # A one-line definition opens and closes on the same line; treating it as
  # open would attribute the whole rest of the file to it.
  if ($0 ~ /\}[[:space:]]*$/) { scan($0, cur); cur = "" }
  next
}
cur != "" && /^\}/ { cur = ""; next }
# A check invocation is always top level here. Saying so explicitly stops a
# function whose closing brace is not in column 0 from swallowing the very line
# that runs it — three gates read as dead for exactly that reason.
/^check[[:space:]]/ { cur = ""; scan($0, ""); next }
{ scan($0, cur) }

function scan(line, owner,   n, i, parts, w) {
  gsub(/[^A-Za-z0-9_]/, " ", line)
  n = split(line, parts, " ")
  for (i = 1; i <= n; i++) {
    w = parts[i]
    if (!(w in defined)) continue
    if (owner == "") root[w] = 1
    else if (owner != w) edge[owner "\t" w] = 1
  }
}

END {
  for (r in root) live[r] = 1
  changed = 1
  while (changed) {
    changed = 0
    for (e in edge) {
      split(e, p, "\t")
      if ((p[1] in live) && !(p[2] in live)) { live[p[2]] = 1; changed = 1 }
    }
  }
  for (f in defined) if (!(f in live) && !(f in exempt)) print f
}

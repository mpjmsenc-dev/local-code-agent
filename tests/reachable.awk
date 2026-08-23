# reachable.awk — the functions a shell script defines that nothing can reach.
#
# Give it the SAME file twice: the first pass collects the definitions, the
# second builds the call graph over names it now knows.
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

# --- pass 1: what does this file define? ------------------------------------
FNR == NR {
  # A quoted heredoc is data, not code. Fixtures in this suite deliberately
  # contain function definitions, and counting those as real ones would make
  # every fixture look like dead code.
  if (!inhd && match($0, /<<\x27[A-Za-z_][A-Za-z0-9_]*\x27/)) {
    hd = substr($0, RSTART + 3, RLENGTH - 4); inhd = 1; next
  }
  if (inhd && $0 == hd) { inhd = 0; next }
  if (inhd) next
  if (match($0, /^[a-z_][a-z0-9_]*\(\) *\{/)) {
    fn = $0; sub(/\(\).*/, "", fn); defined[fn] = 1
  }
  next
}

# --- pass 2: who mentions whom? ---------------------------------------------
{
  if (!inhd2 && match($0, /<<\x27[A-Za-z_][A-Za-z0-9_]*\x27/)) {
    # The line that OPENS a heredoc is still code, and in this suite it is
    # routinely the check line naming the gate whose fixture follows. Scan it,
    # then skip the data underneath.
    hd2 = substr($0, RSTART + 3, RLENGTH - 4); inhd2 = 1
    scan($0, ($0 ~ /^check[[:space:]]/) ? "" : cur)
    next
  }
  if (inhd2 && $0 == hd2) { inhd2 = 0; next }
  if (inhd2) next
  if ($0 ~ /^[[:space:]]*#/) next
  if (match($0, /^[a-z_][a-z0-9_]*\(\) *\{/)) {
    cur = $0; sub(/\(\).*/, "", cur)
    # A one-line definition opens and closes on the same line; treating it as
    # open would attribute the whole rest of the file to it.
    if ($0 ~ /\}[[:space:]]*$/) { scan($0, cur); cur = "" }
    next
  }
  if (cur != "" && $0 ~ /^\}/) { cur = ""; next }
  # A check invocation is always top level here. Saying so explicitly stops a
  # function whose closing brace is not in column 0 from swallowing the very
  # line that runs it — three gates read as dead for exactly that reason.
  if ($0 ~ /^check[[:space:]]/) { cur = ""; scan($0, ""); next }
  scan($0, cur)
}

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
  for (f in defined) if (!(f in live)) print f
}

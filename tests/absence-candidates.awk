# tests/absence-candidates.awk — which of a suite's functions are SHAPED like
# absence rules: gates that read the repository's text and fail when they find
# something. Run after the shared lexer, over the same file twice — the first
# pass collects the names 'check' lines run, the second judges function bodies:
#
#   awk -f tests/shell-lex.awk -f tests/absence-candidates.awk FILE FILE
#
# A TRIPWIRE, NOT THE CENSUS. tests/absence-rule-census.tsv is the census, and it
# was made by reading each function's body. Measured against the first full
# reading, which was made without it, this finds 101 of that reading's 108
# absence rules. It also flags 40 functions a reader found are not absence
# rules — they are NOT rows in the census, with their reasons. (Readings of what
# it flagged found 37 more absence rules, but those cannot measure its recall:
# it chose them.)
#
# The seven it misses, by shape. A new rule written one of these ways gets past
# it, and is caught only by somebody adding it to the census:
#
#   the scan happens in a helper the gate calls, so the gate's own body names no
#   repository path — every_drift_key_is_reported, ollama_advice_is_conditional,
#   sudo_asks_out_loud, unbacked_settings, undocumented_settings
#
#   the file arrives as "$1" and is read inside a quoted awk program —
#   asks_before_it_concludes
#
#   a pinned count other than zero, "(( n == 1 ))" — image_is_named_once
#
# What it counts as the shape: a body that names a repository path (the same
# variables the source-grep classifier knows, and git ls-files) AND fails on a
# finding — [[ -z "${hits}" ]] ||, ! grep, ! awk, (( n == 0 )), a ratchet
# (( n <= N )), (( ${#list[@]} == 0 )), or a failure flag or 'return 1' inside a
# loop. Lines are judged when they start OR end in code (LEX_CODE,
# LEX_ENDS_IN_CODE); a definition and its closing brace must start in code.
FNR == 1 { pass++ }
pass == 1 {
  if (!LEX_CODE) next
  if (cont) { n = $0; sub(/^[[:space:]]+/, "", n); split(n, w, /[[:space:]]/); if (w[1] ~ /^[a-z_][a-z0-9_]*$/) runs[w[1]] = 1; cont = 0 }
  if ($0 ~ /^[[:space:]]*check[[:space:]]+"/) {
    line = $0; sub(/^[[:space:]]*check[[:space:]]+"([^"\\]|\\.)*"[[:space:]]*/, "", line)
    if (line ~ /^\\[[:space:]]*$/) { cont = 1; next }
    split(line, w, /[[:space:]]/); if (w[1] ~ /^[a-z_][a-z0-9_]*$/) runs[w[1]] = 1
  }
  next
}
pass == 2 {
  if (LEX_OPENS_HEREDOC && !inb) next
  if (!LEX_CODE && !LEX_ENDS_IN_CODE) next
  if (LEX_CODE && $0 ~ /^[a-z_][a-z0-9_]*\(\) *\{/) {
    fn = $0; sub(/\(\).*/, "", fn); src = 0; shape = 0; loop = 0; flag = 0
    inb = ($0 !~ /\}[[:space:]]*$/)
    if (!inb) { body = $0; judge(body); report() }
    else { judge($0) }
    next
  }
  if (!inb) next
  if ($0 ~ /^[[:space:]]*#/) next
  judge($0)
  if (LEX_CODE && $0 ~ /^\}/) { report(); inb = 0 }
}
function judge(l) {
  if (l ~ /\$\{(REPO|TESTS_DIR|APPLY|CENSUS|CONFIG_CENSUS|MOTD|SUGGESTIONS)\}|\$\{(DOC_SURFACES|LCA_TARGETS)\[|ls-files/) src = 1
  if (l ~ /\[\[ -z "\$\{[A-Za-z_]+\}" \]\] *\|\|/) shape = 1
  if (l ~ /(^|[;&|{(]|[[:space:]])! +(grep|awk)([[:space:]]|$)/) shape = 1
  if (l ~ /\(\( *[a-z_]+ *== *0 *\)\)/) shape = 1
  if (l ~ /\(\( *\$\{#[A-Za-z_]+\[@\]\} *== *0 *\)\)/) shape = 1
  if (l ~ /\(\( *[a-z_]+ *<= *[0-9]+ *\)\)/) shape = 1
  if (l ~ /(^|[[:space:]])while[[:space:]].*read/ || l ~ /(^|[[:space:]])for[[:space:]]+[a-z_]+[[:space:]]+in[[:space:]]/ || l ~ /(^|[[:space:]])for[[:space:]]*\(\(/) loop = 1
  if (l ~ /[a-z_]*(bad|dead|fail|mismatch|drift|undocumented|missing|wrong|stale)[a-z_]*=1/) flag = 1
  if (l ~ /(^|[;{[:space:]])return 1([;}[:space:]]|$)/) flag = 1
}
function report() { if ((src && (shape || (loop && flag))) && (fn in runs)) print fn }

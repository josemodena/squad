# Read the YAML front matter of a Squad settings file and print shell
# assignments, one per key, named SQUAD_<KEY IN UPPER CASE>.
#
# It understands the three shapes a settings file uses: a scalar
# (key: value), an inline list (key: [a, b]) and a block list (key: on its
# own line, then indented "- item" lines). A list becomes one value with a
# newline between items, so a caller reads it with "while IFS= read -r".
# Anything else in the front matter is ignored rather than guessed at.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function unquote(s) {
  if (s ~ /^".*"$/) return substr(s, 2, length(s) - 2)
  if (s ~ /^'.*'$/) return substr(s, 2, length(s) - 2)
  return s
}

function shq(s,   r) { r = s; gsub(/'/, "'\\''", r); return "'" r "'" }

function append(k, item) {
  if (!(k in buf) || buf[k] == "") buf[k] = item
  else buf[k] = buf[k] "\n" item
}

BEGIN { started = 0; finished = 0; key = "" }

{
  line = $0
  sub(/\r$/, "", line)

  if (!started) { if (line ~ /^---[ \t]*$/) started = 1; next }
  if (finished) next
  if (line ~ /^(---|\.\.\.)[ \t]*$/) { finished = 1; next }
  if (line ~ /^[ \t]*#/) next
  if (line ~ /^[ \t]*$/) next

  if (line ~ /^[ \t]+-[ \t]*/) {
    if (key == "") next
    item = line
    sub(/^[ \t]+-[ \t]*/, "", item)
    item = unquote(trim(item))
    if (item != "") append(key, item)
    next
  }

  if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/) {
    k = line
    sub(/[ \t]*:.*$/, "", k)
    v = line
    sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*/, "", v)
    v = trim(v)
    sub(/[ \t]+#.*$/, "", v)
    v = trim(v)

    if (v == "") { key = k; buf[k] = ""; next }
    key = ""

    if (v ~ /^\[.*\]$/) {
      inner = substr(v, 2, length(v) - 2)
      n = split(inner, parts, ",")
      buf[k] = ""
      for (i = 1; i <= n; i++) {
        p = unquote(trim(parts[i]))
        if (p != "") append(k, p)
      }
      next
    }

    buf[k] = unquote(v)
    next
  }
}

END { for (k in buf) printf "SQUAD_%s=%s\n", toupper(k), shq(buf[k]) }

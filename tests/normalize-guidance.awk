BEGIN {
  ulid_pattern = "[0-7]"
  for (i = 1; i < 26; i++) ulid_pattern = ulid_pattern "[0-9A-HJKMNP-TV-Z]"
}
function replace_literal(text, from, to,    at, result) {
  if (from == "") return text
  result = ""
  while ((at = index(text, from)) != 0) {
    result = result substr(text, 1, at - 1) to
    text = substr(text, at + length(from))
  }
  return result text
}
{
  line = replace_literal($0, real_t, "<T>")
  line = replace_literal(line, t, "<T>")
  gsub(/\/(private\/)?(tmp|var\/folders)\/[^[:space:]"'"'"']*lua_[A-Za-z0-9]+[^[:space:]"'"'"']*/, "<TMPFILE>", line)
  gsub(/message-[0-9a-f]+-[0-9a-f]+-lua_[A-Za-z0-9]+/, "<MSGID>", line)
  # Replace only complete ULID tokens; do not rewrite embedded identifiers.
  normalized = ""
  i = 1
  while (i <= length(line)) {
    candidate = substr(line, i, 26)
    before = i > 1 ? substr(line, i - 1, 1) : ""
    after = i + 26 <= length(line) ? substr(line, i + 26, 1) : ""
    if (length(candidate) == 26 && candidate ~ ("^" ulid_pattern "$")) {
      before_word = before ~ /[[:alnum:]_]/
      after_word = after ~ /[[:alnum:]_]/
      if (!before_word && !after_word) {
        normalized = normalized "<ULID>"
        i += 26
        continue
      }
    }
    normalized = normalized substr(line, i, 1)
    i++
  }
  line = normalized
  gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/, "<TIME>", line)
  gsub(/"REMUDA_SESSION_CAPABILITY":"[^"]+"/, "\"REMUDA_SESSION_CAPABILITY\":\"<CAP>\"", line)
  gsub(/REMUDA_SESSION_CAPABILITY="?[A-Za-z0-9_-]+/, "REMUDA_SESSION_CAPABILITY=\"<CAP>", line)
  print line
}

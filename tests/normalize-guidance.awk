BEGIN {
  for (i = 0; i < 26; i++) ulid_pattern = ulid_pattern "[0-9A-HJKMNP-TV-Z]"
}
function replace_literal(text, from, to,    at, result) {
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
  gsub(ulid_pattern, "<ULID>", line)
  gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/, "<TIME>", line)
  gsub(/"REMUDA_SESSION_CAPABILITY"[[:space:]]*:[[:space:]]*"[^"]+"/, "\"REMUDA_SESSION_CAPABILITY\":\"<CAP>\"", line)
  gsub(/REMUDA_SESSION_CAPABILITY="?[A-Za-z0-9_-]+/, "REMUDA_SESSION_CAPABILITY=\"<CAP>", line)
  print line
}

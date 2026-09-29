BEGIN {
  ulid_pattern = "[0-7]"
  for (i = 1; i < 26; i++) ulid_pattern = ulid_pattern "[0-9A-HJKMNP-TV-Z]"
}
function replace_literal(text, from, to,    at, result, next_at) {
  if (from == "") return text
  result = ""
  while ((at = index(text, from)) != 0) {
    result = result substr(text, 1, at - 1) to
    # Advance over the literal match. The explicit length check keeps this
    # loop bounded even on awk implementations with unusual index semantics.
    next_at = at + length(from)
    if (next_at <= at) break
    text = substr(text, next_at)
  }
  return result text
}
function replace_capabilities(text,    json_key, shell_key, at, value_start, value_end, quote, ch, scan) {
  # Avoid a gsub replacement that still satisfies the broad JSON value pattern.
  # Advance beyond each inserted placeholder so every original occurrence is
  # handled once, including duplicate keys on one line.
  json_key = "\"REMUDA_SESSION_CAPABILITY\":\""
  scan = 1
  while ((at = index(substr(text, scan), json_key)) != 0) {
    at += scan - 1
    value_start = at + length(json_key)
    value_end = index(substr(text, value_start), "\"")
    if (value_end == 0) break
    value_end += value_start - 1
    if (value_end > value_start) {
      text = substr(text, 1, value_start - 1) "<CAP>" substr(text, value_end)
      scan = value_start + 5
    } else {
      scan = value_end + 1
    }
  }

  shell_key = "REMUDA_SESSION_CAPABILITY="
  scan = 1
  while ((at = index(substr(text, scan), shell_key)) != 0) {
    at += scan - 1
    value_start = at + length(shell_key)
    quote = substr(text, value_start, 1) == "\""
    if (quote) value_start++
    value_end = value_start
    while (value_end <= length(text)) {
      ch = substr(text, value_end, 1)
      if (ch !~ /^[A-Za-z0-9_-]$/) break
      value_end++
    }
    if (value_end > value_start) {
      text = substr(text, 1, value_start - 1) "<CAP>" substr(text, value_end)
      scan = value_start + 5
    } else {
      scan = value_start
      if (scan <= at) scan = at + length(shell_key)
    }
  }
  return text
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
  line = replace_capabilities(line)
  print line
}

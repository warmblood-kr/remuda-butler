-- Unit and safety checks for packages/butler/md2html.lua.
-- Run from the repo root: luajit tests/md2html.lua
local md = dofile("packages/butler/md2html.lua")
local c = md.convert
local count = 0

local function eq(input, want)
  count = count + 1
  local got = c(input)
  if got ~= want then
    error(("case %d\n input: %s\n  want: %s\n   got: %s"):format(count, input, want, tostring(got)), 2)
  end
end

-- Every '<' in the output must open one of the tags the converter emits.
local ALLOWED = { p = 1, br = 1, strong = 1, em = 1, code = 1, pre = 1, a = 1, ul = 1, ol = 1,
  li = 1, blockquote = 1, hr = 1, table = 1, thead = 1, tbody = 1, tr = 1, th = 1, td = 1,
  h1 = 1, h2 = 1, h3 = 1, h4 = 1, h5 = 1, h6 = 1 }
local function safe(input)
  count = count + 1
  local got = c(input)
  for tag, attrs in got:gmatch("<(/?%w*)([^>]*)>?") do
    local name = tag:gsub("^/", "")
    local ok = ALLOWED[name]
      and (attrs == "" or attrs:match('^ href="[^"<>]*"$') or attrs:match('^ class="language%-[%w_+%-]+"$')
        or attrs:match('^ start="%d+"$'))
    if not ok then error(("unsafe tag in case %d\n input: %s\n   got: %s"):format(count, input, got), 2) end
  end
  for href in got:gmatch('href="([^"]*)"') do
    local lower = href:lower()
    if not (lower:match("^https?://") or lower:match("^mailto:")) then
      error(("unsafe href in case %d\n input: %s\n   got: %s"):format(count, input, got), 2)
    end
  end
  assert(not got:find("\1", 1, true), "placeholder leaked: " .. got)
  return got
end

-- paragraphs and inline
eq("", "")
eq("hello", "<p>hello</p>")
eq("a\nb\n\nc", "<p>a<br>b</p><p>c</p>")
eq("a\r\nb", "<p>a<br>b</p>")
eq("**bold** and *it* and `co<de>`", "<p><strong>bold</strong> and <em>it</em> and <code>co&lt;de&gt;</code></p>")
eq("한글 **굵게** *기울임*", "<p>한글 <strong>굵게</strong> <em>기울임</em></p>")
eq("2*3*4 and a * b * c", "<p>2*3*4 and a * b * c</p>")
eq("`**not bold**`", "<p><code>**not bold**</code></p>")
eq("snake_case_name stays", "<p>snake_case_name stays</p>")
eq("a & b < c > d \"q\" 'r'", "<p>a &amp; b &lt; c &gt; d &quot;q&quot; &#39;r&#39;</p>")
-- links
eq("[site](https://example.com/a?b=1&c=2)", '<p><a href="https://example.com/a?b=1&amp;c=2">site</a></p>')
eq("[m](mailto:a@b.co) [**b**](http://x.y)", '<p><a href="mailto:a@b.co">m</a> <a href="http://x.y"><strong>b</strong></a></p>')
eq("[x](javascript:alert(1))", "<p>[x](javascript:alert(1))</p>")
eq("[x](/relative)", "<p>[x](/relative)</p>")
-- a code span in the URL must not put a tag inside the href: the link stays literal
eq("[x](https://a.b/`c`)", "<p>[x](https://a.b/<code>c</code>)</p>")
-- headings, rule
eq("# T\n## *S*\ntext", "<h1>T</h1><h2><em>S</em></h2><p>text</p>")
eq("####### seven", "<p>####### seven</p>")
eq("#nospace", "<p>#nospace</p>")
eq("a\n\n---\n\nb", "<p>a</p><hr><p>b</p>")
-- lists
eq("- a\n- **b**\n* c", "<ul><li>a</li><li><strong>b</strong></li><li>c</li></ul>")
eq("intro\n- a\n- b", "<p>intro</p><ul><li>a</li><li>b</li></ul>")
eq("1. a\n2. b", "<ol><li>a</li><li>b</li></ol>")
eq("3. a\n4) b", '<ol start="3"><li>a</li><li>b</li></ol>')
-- quote
eq("> q1\n> *q2*\nafter", "<blockquote><p>q1<br><em>q2</em></p></blockquote><p>after</p>")
-- fenced code
eq("```lua\nlocal x = '<b>'\n**no**\n```\nafter",
  '<pre><code class="language-lua">local x = &#39;&lt;b&gt;&#39;\n**no**\n</code></pre><p>after</p>')
eq("```\nunclosed <i>", "<pre><code>unclosed &lt;i&gt;\n</code></pre>")
-- table
eq("| A | B |\n|---|:-:|\n| 1 | `x` |\n| **2** | y |\nafter",
  "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td><code>x</code></td></tr>"
  .. "<tr><td><strong>2</strong></td><td>y</td></tr></tbody></table><p>after</p>")
eq("a | b", "<p>a | b</p>")

-- XSS: nothing below may yield a tag or attribute outside the allowlist
eq("<script>alert(1)</script>", "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
eq("<img src=x onerror=alert(1)>", "<p>&lt;img src=x onerror=alert(1)&gt;</p>")
eq('[x](https://a.b/"onmouseover="alert(1))', '<p><a href="https://a.b/&quot;onmouseover=&quot;alert(1">x</a>)</p>')
for _, attack in ipairs({
  "<script>alert(1)</script>", "**<b onclick=x>**", "`<script>`", "# <h1 onload=x>",
  "- <li><script>", "> <blockquote><iframe src=x>", "| <td onclick=x> | b |\n|---|---|\n| <script> | c |",
  "```<script>\n</code></pre><script>alert(1)</script>\n```", "```\"><script>\ncode\n```",
  "[x](https://a.b/`c`)", "[`a`](https://a.b/`onclick=x`)",
  "[<img src=x onerror=1>](https://ok.example)", "[x](javascript:alert(1))", "[x](JaVaScRiPt:alert(1))",
  "[x](data:text/html,<script>)", "[x](vbscript:x)", "[x]( https://a.b)", "[x](https://a.b/'><script>)",
  "[x](https://a.b/\"><script>alert(1)</script>)", "[x](\1 1\1https://a.b)", "\0011\1 \1 9\1 `a` \0011\1",
  "*<em onclick=x>*", "**a *b** c*", "*a **b* c**", "[a `b](https://x.y) c`", "&lt;script&gt; &#60;script&#62;",
  "1. <ol start=\"1\" onclick=x>", "99999999999999999999. x", ("*"):rep(300), ("["):rep(300) .. "](https://a.b)",
  ("`"):rep(301), ("> "):rep(200) .. "x", ("|"):rep(200) .. "\n" .. ("|-"):rep(100),
}) do safe(attack) end
assert(c(nil) == nil and c(42) == nil)

-- cheap fuzz: random soup of markup characters must stay inside the allowlist, fast
math.randomseed(20261001)
local alphabet = { "*", "`", "[", "]", "(", ")", "<", ">", "|", "-", "#", "\n", " ", "a", "\"", "'", "&",
  "https://x.y", "javascript:", "1.", ">", "```", "\1", "한" }
local started = os.clock()
for _ = 1, 3000 do
  local parts = {}
  for k = 1, math.random(1, 80) do parts[k] = alphabet[math.random(#alphabet)] end
  safe(table.concat(parts))
end
safe(("**a** `b` [c](https://d.e) *f* | g\n"):rep(100)) -- ~4 KB, one Matrix chunk
assert(os.clock() - started < 10, "converter too slow")

print(("md2html ok: %d cases"):format(count))

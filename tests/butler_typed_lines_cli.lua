local state = { typed_lines = false, shell_lines = false, status_commands = true, approve_text = false }
local writes, prompts = {}, {}
local prompt_error_to_throw
local config_path = os.tmpname()
local config = assert(io.open(config_path, "wb"))
config:write("https://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nfalse\n30000\nuntrusted_per_room_hour=12\ntyped_lines=false\nshell_lines=false\napprove_text=false\n")
config:close()

remuda = {
  butler = {
    matrix = {
      read_config = function(path)
        assert(path == config_path)
        return { typed_lines = state.typed_lines, shell_lines = state.shell_lines,
          status_commands = state.status_commands, approve_text = state.approve_text }
      end,
    },
  },
  fs = {
    lock = function() return true end,
    write_atomic = function(path, contents, options)
      assert(path == config_path and options.private == true, "switch updates use a private atomic write")
      writes[#writes + 1] = contents
      local file = assert(io.open(path, "wb"))
      file:write(contents)
      file:close()
      state.typed_lines = contents:find("typed_lines=true", 1, true) ~= nil
      state.shell_lines = contents:find("shell_lines=true", 1, true) ~= nil
      state.status_commands = contents:find("status_commands=false", 1, true) == nil
      state.approve_text = contents:find("approve_text=true", 1, true) ~= nil
      return true
    end,
  },
  _butler_matrix_config = { config_path = config_path },
  fail = function(message, code) return { error = message, code = code } end,
  pending = function()
    return {
      prompt_line = function(_, spec)
        local preface = spec.preface or ""
        local lines = {}
        for line in (preface .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
        if #lines > 32 then error("prompt_line preface has too many lines", 0) end
        for i, line in ipairs(lines) do
          if #line > 256 then error("prompt_line preface line " .. i .. " is too long", 0) end
        end
        if prompt_error_to_throw then error(prompt_error_to_throw, 0) end
        prompts[#prompts + 1] = spec
      end,
      resolve = function(_, code, stdout, stderr)
        return { code = code, stdout = stdout, stderr = stderr }
      end,
    }
  end,
}

dofile("packages/butler/matrix_cli.lua")
local sample = string.rep("preface-word ", 40):gsub(" $", "")
local wrapped_sample = remuda.butler.matrix.wrap_prompt_preface(sample)
assert(remuda.butler.matrix.wrap_prompt_preface(nil) == "", "a missing preface must not raise")
assert(wrapped_sample:gsub("\n", " ") == sample, "the shared preface wrapper must preserve every word")
for line in (wrapped_sample .. "\n"):gmatch("([^\n]*)\n") do
  assert(#line <= 200, "the shared preface wrapper must keep every line within 200 characters")
end
local multi_line = "Heading\n\n" .. string.rep("wrapped-word ", 30) .. "\nLast line"
local wrapped_multi_line = remuda.butler.matrix.wrap_prompt_preface(multi_line)
assert(wrapped_multi_line:match("^Heading\n\n"), "the shared preface wrapper must keep existing blank lines")
assert(wrapped_multi_line:match("\nLast line$"), "the shared preface wrapper must keep existing line breaks")
local indented = remuda.butler.matrix.wrap_prompt_preface("  " .. string.rep("word ", 80):gsub(" $", ""))
for line in (indented .. "\n"):gmatch("([^\n]*)\n") do
  assert(line:match("^  word") and #line <= 200, "a wrapped line keeps its indent on every line: " .. line)
end
assert(select(2, indented:gsub("\n", "")) >= 1, "the indented sample must wrap")
-- Malformed or multibyte words always make progress and lose nothing.
for name, word in pairs({ ["a run of continuation bytes"] = string.rep("\128", 500),
  ["3-byte characters across the boundary"] = string.rep("\226\130\172", 150),
  ["a valid multibyte character at the split"] = string.rep("x", 199) .. "\195\169" .. string.rep("y", 300) }) do
  local wrapped = remuda.butler.matrix.wrap_prompt_preface(word)
  assert(#wrapped > 0, name .. ": the wrapper must return text")
  for line in (wrapped .. "\n"):gmatch("([^\n]*)\n") do
    assert(#line <= 200, name .. ": a line is over the limit: " .. #line)
  end
  if not wrapped:find("...", 1, true) then
    assert(wrapped:gsub("\n", "") == word, name .. ": characters were lost")
  end
end
local long_word = string.rep("x", 450)
local wrapped_long_word = remuda.butler.matrix.wrap_prompt_preface(long_word)
assert(wrapped_long_word:gsub("\n", "") == long_word, "a long word must be hard-split without losing characters")
for line in (wrapped_long_word .. "\n"):gmatch("([^\n]*)\n") do
  assert(#line <= 200, "hard-split words must fit the line limit")
end
local too_many_lines = {}
for i = 1, 40 do too_many_lines[i] = "line " .. i end
local truncated_preface = remuda.butler.matrix.wrap_prompt_preface(table.concat(too_many_lines, "\n"))
local truncated_lines = {}
for line in (truncated_preface .. "\n"):gmatch("([^\n]*)\n") do truncated_lines[#truncated_lines + 1] = line end
assert(#truncated_lines == 32 and truncated_lines[32] == "..." and truncated_lines[31] == "line 31",
  "an oversized preface must end with an ellipsis within the core line limit")
local cli = assert(dofile("packages/butler/typed_lines_cli.lua")).cli
local function text(result)
  return type(result) == "table" and (result.error or result.stdout or "") or tostring(result)
end
local function expect_refused(args, agent, fragment)
  local before = #writes
  local result = cli(args, agent)
  assert(text(result):find(fragment, 1, true), "expected refusal containing " .. fragment .. ", got " .. text(result))
  assert(#writes == before, "a refused caller or invalid switch must not write the config")
end

expect_refused({ "typed-lines", "on" }, "agent-01", "operator-only")
expect_refused({ "shell-lines", "off" }, "agent-01", "operator-only")

local terminal_pending = remuda.pending
remuda.pending = nil
expect_refused({ "typed-lines", "on" }, nil, "needs a Remuda core with terminal prompts")
remuda.pending = terminal_pending

local before_writes = #writes
local pending = cli({ "typed-lines", "on" }, nil)
assert(#prompts == 1 and #writes == before_writes, "enabling typed lines must prompt before writing")
local function assert_preface_fits(preface)
  local lines = {}
  for line in (preface .. "\n"):gmatch("([^\n]*)\n") do
    assert(#line <= 200, "prompt preface lines must fit the shared wrapping limit")
    assert(#line <= 256, "prompt_line preface lines must fit the core limit")
    lines[#lines + 1] = line
  end
  assert(#lines <= 32, "prompt_line prefaces must fit the core line-count limit")
end
assert_preface_fits(prompts[1].preface)
assert(prompts[1].preface:gsub("\n", " ") == "Whoever controls the owner's Matrix account, or the homeserver that carries it, can type text into every agent session of this machine, and the session cannot tell that text from text typed at its keyboard. Such text counts as the owner's own instruction, including approvals.",
  "typed-lines must print the complete warning from the UX note")
assert(prompts[1].label:find("Type yes", 1, true), "typed-lines must ask for the word yes")
prompts[1].callback("yes")
assert(state.typed_lines == true and state.shell_lines == false and #writes == before_writes + 1,
  "yes should enable only typed-lines")
assert(pending ~= nil)

state.typed_lines, state.shell_lines = false, false
expect_refused({ "shell-lines", "on" }, nil, "typed-lines must be on")
state.typed_lines = true
local shell_pending = cli({ "shell-lines", "on" }, nil)
assert(#prompts == 2, "enabling shell-lines should prompt")
assert_preface_fits(prompts[2].preface)
assert(prompts[2].preface:gsub("\n", " ") == "Whoever controls that account or homeserver can run shell commands on this machine as this user, with no review by anyone. It is remote command execution, bounded only by rules 1 to 8. Recommended only with the Matrix account protected as well as the machine's own login (device verification, a homeserver the owner runs or trusts).",
  "shell-lines must print the complete warning from the UX note")
prompts[2].callback("yes")
assert(state.shell_lines == true and #writes == before_writes + 2, "yes should enable shell-lines")
assert(shell_pending ~= nil)

local prompt_count = #prompts
local write_count = #writes
cli({ "typed-lines", "off" }, nil)
assert(state.typed_lines == false and state.shell_lines == false,
  "turning typed-lines off must also turn shell-lines off")
assert(#prompts == prompt_count and #writes == write_count + 1,
  "turning switches off must write immediately without prompting")
local written_file = assert(io.open(config_path, "rb"))
local written_config = written_file:read("*a")
written_file:close()
local typed_count = 0
for _ in written_config:gmatch("typed_lines=") do typed_count = typed_count + 1 end
assert(typed_count == 1 and written_config:find("untrusted_per_room_hour=12", 1, true),
  "the private switch writer must deduplicate switch keys and preserve other config lines")
-- status-commands: default on, off is immediate, on asks for yes
expect_refused({ "status-commands", "off" }, "agent-01", "operator-only")
expect_refused({ "approve-text", "on" }, "agent-01", "operator-only")
expect_refused({ "status-commands", "maybe" }, nil, "Usage:")
prompt_count, write_count = #prompts, #writes
assert(text(cli({ "status-commands", "on" }, nil)):find("already on", 1, true), "default is on")
assert(#prompts == prompt_count and #writes == write_count, "already on changes nothing")
cli({ "status-commands", "off" }, nil)
assert(state.status_commands == false and #writes == write_count + 1 and #prompts == prompt_count,
  "off writes at once without a prompt")
assert(state.typed_lines == false, "status-commands off leaves typed-lines alone")
cli({ "status-commands", "on" }, nil)
assert(#prompts == prompt_count + 1 and state.status_commands == false, "on prompts before writing")
assert_preface_fits(prompts[#prompts].preface)
assert(prompts[#prompts].label:find("Type yes", 1, true) and prompts[#prompts].preface:find("status", 1, true))
prompts[#prompts].callback("no")
assert(state.status_commands == false, "anything but yes changes nothing")
cli({ "status-commands", "on" }, nil)
prompts[#prompts].callback("yes")
assert(state.status_commands == true, "yes turns it on")
local approve_pending = cli({ "approve-text", "on" }, nil)
assert(#prompts == prompt_count + 3 and state.approve_text == false,
  "approve-text on asks for owner confirmation before writing")
assert(prompts[#prompts].preface:find("approve registered text", 1, true),
  "approve-text warns that Matrix approval can type into sessions")
prompts[#prompts].callback("yes")
assert(state.approve_text == true and approve_pending ~= nil, "yes enables approve-text")
cli({ "approve-text", "off" }, nil)
assert(state.approve_text == false, "approve-text can be turned off immediately")
written_file = assert(io.open(config_path, "rb"))
written_config = written_file:read("*a")
written_file:close()
local status_count = 0
for _ in written_config:gmatch("status_commands=") do status_count = status_count + 1 end
assert(status_count == 1, "the switch key is written once")

state.typed_lines = false
local before_prompt_error_writes = #writes
local failed_resolution
local terminal_pending = remuda.pending
remuda.pending = function()
  local reply = terminal_pending()
  reply.resolve = function(_, code, stdout, stderr)
    failed_resolution = { code = code, stdout = stdout, stderr = stderr }
  end
  return reply
end
prompt_error_to_throw = "prompt_line preface line 1 is too long"
cli({ "typed-lines", "on" }, nil)
prompt_error_to_throw = nil
assert(failed_resolution and failed_resolution.code == 1
  and failed_resolution.stderr:find("The typed-line switch prompt failed: prompt_line preface line 1 is too long. Nothing was changed.", 1, true),
  "prompt exceptions should explain the failure and confirm no change: "
    .. tostring(failed_resolution and failed_resolution.stderr))
assert(#writes == before_prompt_error_writes and state.typed_lines == false,
  "a rejected prompt must not change the config")

local command_rows, bridge_handler = {}, nil
remuda.butler.schedule_cli = { cli = function() end }
remuda._butler_commands_config = {
  current_agent = function() return nil end,
  OPERATOR = "operator",
  contributions = function() return command_rows end,
  registry_list = function() return {} end,
  statusline = function() return "" end,
  resolve = function(name) return name end,
  mail = {},
}
remuda._butler_contribute = function(point, id, entry)
  if point == "butler.command" then command_rows[#command_rows + 1] = { id = id, entry = entry } end
end
remuda.extension_command = function(name, callback)
  assert(name == "butler")
  bridge_handler = callback
end
dofile("packages/butler/commands.lua")
local bridge_resolution, bridge_reply_object
remuda.pending = function()
  bridge_reply_object = {
    prompt_line = function() error("core prompt failure", 0) end,
    resolve = function(_, code, stdout, stderr)
      bridge_resolution = { code = code, stdout = stdout, stderr = stderr }
    end,
  }
  return bridge_reply_object
end
local bridge_result = bridge_handler({ "typed-lines", "on" })
assert(bridge_result == bridge_reply_object,
  "the real remuda butler command bridge must return the failed prompt reply, not fall through to usage")
assert(bridge_resolution and bridge_resolution.code == 1
  and bridge_resolution.stderr == "The typed-line switch prompt failed: core prompt failure. Nothing was changed.\n",
  "the real command bridge must resolve prompt_line exceptions with exit 1 and a clear message")
assert(#writes == before_prompt_error_writes and state.typed_lines == false,
  "a failed prompt through the command bridge must not change the config")
os.remove(config_path)
print("ok - typed-line switch CLI cases")

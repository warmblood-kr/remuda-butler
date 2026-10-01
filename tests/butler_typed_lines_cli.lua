local state = { typed_lines = false, shell_lines = false }
local writes, prompts = {}, {}
local operator = true
local config_path = os.tmpname()
local config = assert(io.open(config_path, "wb"))
config:write("https://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nfalse\n30000\nuntrusted_per_room_hour=12\ntyped_lines=false\nshell_lines=false\n")
config:close()

remuda = {
  butler = {
    matrix = {
      prompt_preface_supported = function() return true end,
      read_config = function(path)
        assert(path == config_path)
        return { typed_lines = state.typed_lines, shell_lines = state.shell_lines }
      end,
    },
    approval = { operator_caller = function() return operator end },
  },
  fs = {
    write_atomic = function(path, contents, options)
      assert(path == config_path and options.private == true, "switch updates use a private atomic write")
      writes[#writes + 1] = contents
      local file = assert(io.open(path, "wb"))
      file:write(contents)
      file:close()
      state.typed_lines = contents:find("typed_lines=true", 1, true) ~= nil
      state.shell_lines = contents:find("shell_lines=true", 1, true) ~= nil
      return true
    end,
  },
  _butler_matrix_config = { config_path = config_path },
  fail = function(message, code) return { error = message, code = code } end,
  pending = function()
    return {
      prompt_line = function(_, spec) prompts[#prompts + 1] = spec end,
      resolve = function(_, code, stdout, stderr)
        return { code = code, stdout = stdout, stderr = stderr }
      end,
    }
  end,
}

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

expect_refused({ "typed-lines", "off" }, "agent-01", "operator-only")
expect_refused({ "shell-lines", "off" }, "agent-01", "operator-only")

local before_writes = #writes
local pending = cli({ "typed-lines", "on" }, nil)
assert(#prompts == 1 and #writes == before_writes, "enabling typed lines must prompt before writing")
assert(prompts[1].preface == "Whoever controls the owner's Matrix account, or the homeserver that carries it, can type text into every agent session of this machine, and the session cannot tell that text from text typed at its keyboard. Such text counts as the owner's own instruction, including approvals.",
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
assert(prompts[2].preface == "Whoever controls that account or homeserver can run shell commands on this machine as this user, with no review by anyone. It is remote command execution, bounded only by rules 1 to 8. Recommended only with the Matrix account protected as well as the machine's own login (device verification, a homeserver the owner runs or trusts).",
  "shell-lines must print the complete warning from the UX note")
prompts[2].callback("yes")
assert(state.shell_lines == true and #writes == before_writes + 2, "yes should enable shell-lines")
assert(shell_pending ~= nil)

operator = false
expect_refused({ "typed-lines", "off" }, nil, "operator-only")
operator = true
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
os.remove(config_path)
print("ok - typed-line switch CLI cases")

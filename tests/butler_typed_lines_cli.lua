local state = { typed_lines = false, shell_lines = false }
local writes, prompts = {}, {}
local operator = true

remuda = {
  butler = {
    matrix = {
      prompt_preface_supported = function() return true end,
      read_config = function(path)
        assert(path == "/test/matrix-config")
        return { typed_lines = state.typed_lines, shell_lines = state.shell_lines }
      end,
      config_set_typed_line_switches = function(path, updates)
        assert(path == "/test/matrix-config")
        writes[#writes + 1] = updates
        for key, value in pairs(updates) do state[key] = value end
        return true
      end,
    },
    approval = { operator_caller = function() return operator end },
  },
  _butler_matrix_config = { config_path = "/test/matrix-config" },
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
assert(prompts[1].preface and prompts[1].preface:find(
  "whoever controls the owner's Matrix account, or the homeserver that carries it, can type text into every agent session of this machine",
  1, true), "typed-lines must print the complete warning from the UX note")
assert(prompts[1].label:find("Type yes", 1, true), "typed-lines must ask for the word yes")
prompts[1].callback("yes")
assert(state.typed_lines == true and state.shell_lines == false and #writes == before_writes + 1,
  "yes should enable only typed-lines")
assert(pending ~= nil)

expect_refused({ "shell-lines", "on" }, nil, "typed-lines must be on")
state.typed_lines = true
local shell_pending = cli({ "shell-lines", "on" }, nil)
assert(#prompts == 2, "enabling shell-lines should prompt")
assert(prompts[2].preface and prompts[2].preface:find(
  "can run shell commands on this machine as this user, with no review by anyone",
  1, true), "shell-lines must print the complete warning from the UX note")
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
print("ok - typed-line switch CLI cases")

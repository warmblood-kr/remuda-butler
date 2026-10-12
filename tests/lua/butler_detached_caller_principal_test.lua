-- A member's orphaned descendant retains launch metadata but loses ancestry.
-- The transitional outside policy must be explicit about the resulting authority.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sleep", "60"}; remuda._butler_skip_relay = true; remuda.exec("butler")')
T.wait_until(function() return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil')
  :match("^%s*true%s*$") end, 5, "Butler start")

T.test("detached_ancestry_keeps_outside_policy_and_does_not_use_inherited_identity", function()
  local scratch = assert(os.getenv("REMUDA_LUA_SCRATCH"))
  local script, go, out = scratch .. "/detach.pl", scratch .. "/detach.go", scratch .. "/detach.out"
  local perl = [[
use strict;
use POSIX qw(setsid);
my ($exe, $server, $go, $out) = @ARGV;
my $pid = fork(); defined($pid) or die "fork: $!";
exit 0 if $pid;
setsid() >= 0 or die "setsid: $!";
open STDIN, '<', '/dev/null' or die $!;
open STDOUT, '>', $out or die $!;
open STDERR, '>&', STDOUT or die $!;
my $deadline = time + 15;
while (getppid() != 1 || !-e $go) {
  die "detach timeout" if time > $deadline;
  select undef, undef, undef, 0.05;
}
die "no inherited identity" unless $ENV{REMUDA_BUTLER_AGENT_ID};
my $code = 'local c = remuda.caller(); local p = remuda._butler_caller_principal.resolve(c); return c.kind .. "|" .. p.tag';
system($exe, '-s', $server, '-e', $code) == 0 or die "probe failed";
exit 0;
]]
  T.eval(string.format([[
    local f = assert(io.open(%q, "w")); f:write(%q); f:close()
    remuda.butler.project_home(%q)
    remuda._butler_agent_builders.detached = function()
      return {"/bin/sh", "-c", 'perl "$1" "$2" "$3" "$4" "$5"; exec sleep 60',
        "detach", %q, %q, %q, %q, %q}
    end
    remuda._butler_launch("detached", "detach-member")
  ]], script, perl, scratch .. "/projects", script, assert(os.getenv("REMUDA_BIN")),
    assert(os.getenv("REMUDA_LUA_CHILD_SERVER")), go, out))
  T.wait_until(function() return T.eval('return remuda._butler_bus.agents["detach-member"] ~= nil') == "true" end,
    5, "detached member registration")
  local f = assert(io.open(go, "w")); f:close()
  local result
  T.wait_until(function()
    local f = io.open(out, "r")
    if f then result = f:read("a"); f:close() end
    return result and result:find("outside|operator", 1, true)
  end, 10, "orphan caller classification")
  T.eq(result:gsub("\n$", ""), "outside|operator")
  T.eq(T.eval([[return remuda._butler_bus.agents["detach-member"] ~= nil]]), "true")
end)

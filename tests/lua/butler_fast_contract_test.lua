T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')

T.test("mail_contract_with_pinned_core", function()
  local value = T.eval([=[
    assert(type(remuda.json) == "table", "core JSON API is missing")
    local B = { host = "local", id = "01REP1YBUT1ER0000000000000", alias = "butler", session = "butler" }
    local F = { host = "local", id = "01REP1YF1XER00000000000000", alias = "fixer", session = "fixer" }
    local W = { host = "local", id = "01REP1YW0RKER0000000000000", alias = "worker", session = "worker" }
    local O = { host = "local", id = "01OUTSIDER0000000000000000", alias = "outside", session = "outside" }
    remuda._butler_mail_config = {bus = {agents = {}, inboxes = {}, messages = {}, objects = {}, next = 0},
      json_quote = function(value) return remuda.json.encode(value) end}
    remuda.exec("butler/mail")
    local M = remuda._butler_mail
    local msg = assert(M.queue(B, F, "contract body"))
    assert(#msg.id == 26, "message ID is not a ULID")
    assert(M.inbox(F.id):find("contract body", 1, true), "message missing")
    assert(M.unread(F.id) == 0, "read state not committed")
    assert(M.reply(O, msg.id, "no") == nil, "unauthorized reply succeeded")
    local response = assert(M.reply(F, msg.id, "reply"))
    assert(response.to[1].id == B.id, "reply routed incorrectly")
    local forwarded = assert(M.forward(F, msg.id, W, "note"))
    assert(forwarded.id == msg.id, "forward did not preserve ID")
    assert(M.inbox(W.id):find("contract body", 1, true), "forward missing")
    return "ok"
  ]=])
  T.eq(value, "ok")
end)

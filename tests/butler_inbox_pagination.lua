-- Uses the disposable Remuda SQLite inbox, never a live mailbox.
local simple = assert(remuda._butler_simple_inbox)
local db, store = simple.db, simple.store
local recipient = '706167696e6174696f6e'
local ok, err = db:exec([[WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20003)
INSERT INTO simple_inbox(recipient,message_id,envelope,body,delivery,note,is_read)
SELECT ?,printf('id-%05d',x),'{}','body',printf('delivery-%05d',x),printf('note-%05d',x),x%2 FROM n]], {recipient})
assert(ok, tostring(err))
assert(db:exec("INSERT INTO read_receipt_intents (recipient, message_id, read_at, status) VALUES (?, ?, ?, ?)", {recipient, 'id-00001', '2026-01-01T00:00:00Z', 'pending'}))
local receipt_before = assert(db:query('SELECT * FROM read_receipt_intents WHERE recipient = ?', {recipient}))[1]
local before = assert(db:query('SELECT count(*) AS n, sum(is_read) AS nread FROM simple_inbox WHERE recipient = ?', {recipient}))[1]
local rows = assert(store.rows(db, recipient))
assert(#rows == 20003, #rows)
for i, row in ipairs(rows) do
  assert(row.message_id == string.format('id-%05d', i), i)
  assert(row.delivery == string.format('delivery-%05d', i), i)
  assert(row.note == string.format('note-%05d', i), i)
  assert(row.is_read == i % 2, i)
  assert(row.seq == nil, 'row shape changed')
end
local after = assert(db:query('SELECT count(*) AS n, sum(is_read) AS nread FROM simple_inbox WHERE recipient = ?', {recipient}))[1]
assert(before.n == after.n and before.nread == after.nread, 'read state changed')
local receipt_after = assert(db:query('SELECT * FROM read_receipt_intents WHERE recipient = ?', {recipient}))[1]
for key, value in pairs(receipt_before) do assert(receipt_after[key] == value, 'receipt changed: ' .. key) end
assert(#assert(store.rows(db, 'empty')) == 0)
local count = 0
local failing = {query = function(_, sql, params)
  count = count + 1
  if count == 2 then return nil, 'injected page failure' end
  return db:query(sql, params)
end}
local partial, reason = store.rows(failing, recipient)
assert(partial == nil and reason == 'injected page failure', 'partial page returned')
return 'pagination: 20003 ordered rows; mixed read flags and fields unchanged; later-page error propagated'

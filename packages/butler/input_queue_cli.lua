-- Operator controls only narrow or explicitly reconcile existing accepted input;
-- they never authorize new bytes or replay an uncertain request.
local butler=assert(remuda.butler)
local parse=assert(remuda.cli and remuda.cli.parse)
local M={}
butler.input_queue_cli=M
local SPEC={name='remuda butler input-queue',verbs={
 status={about='Show retained input receipts. Example: remuda butler input-queue status',
   args={{name='ID',required=false,help='Optional queue request ID'}},next='remuda butler input-queue status'},
 cancel={about='Cancel an unattempted input. Example: remuda butler input-queue cancel ID',
   args={{name='ID',help='Queue request ID'}},next='remuda butler input-queue status'},
 resolve={about='Record an explicit outcome without replay. Example: remuda butler input-queue resolve ID not_sent',
   args={{name='ID',help='Uncertain or quarantined queue request ID'},{name='OUTCOME',help='not_sent or delivered'}},
   next='remuda butler input-queue status'},
}}
local function fail(message)
  if remuda.fail then return remuda.fail(message,1)end
  error(message,0)
end
function M.cli(args,principal)
  local report=parse(SPEC,#args==0 and{'status'}or args)
  if report.kind=='help'then return report.text end
  if not report.ok then return fail(report.text)end
  if not principal or principal.tag~='operator'then return fail('Input queue controls are operator-only.')end
  local queue=butler.owner_input
  if not queue then return fail('Durable input queue unavailable.')end
  if report.verb=='status'then
    local rows,why=queue.status();if not rows then return fail('Input queue unavailable: '..tostring(why))end
    if report.values.ID then
      local matches={};for _,r in ipairs(rows)do if r.id==report.values.ID then matches[1]=r end end;rows=matches
    end
    return remuda.json.encode(rows)
  end
  local disposition=report.verb=='cancel'and'cancel'or report.values.OUTCOME
  if disposition~='cancel'and disposition~='not_sent'and disposition~='delivered'then
    return fail('Outcome must be not_sent or delivered; no replay is performed.')
  end
  local receipt,why=queue.resolve(report.values.ID,disposition,'operator (terminal)')
  if not receipt then return fail('Input queue resolution refused: '..tostring(why))end
  return remuda.json.encode(receipt)
end
return M

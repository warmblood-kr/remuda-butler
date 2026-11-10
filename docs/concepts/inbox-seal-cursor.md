# One seal cursor correction: root approval before product GO

Reference seam only: packages/butler/inbox_seal_contract.lua M.step(previous,
budget,config), not daemon/product loaded. Existing Source:seal(root,hex,budget)
wraps ONE driver; Store loads/saves its cursor, no separate capture algorithm.
Config `{root,generation,recipient,paths={inbox=absolute,read=absolute},fs}`;
fs.size/read_range dot conventions unchanged. Real config/cursor values trusted
only after Store validates actualroot owner+recipient+generation. Reference
assumes well-formed persisted internal fields; production catches IO throws and
validates all DB state. No product/schema written by contract designer.

Return `{cursor,partial,bytes_read}` or nil,{code,field}. budget omitted means
max_bytes65536, NEVER unbounded. Explicit max_bytes is integer0..1048576; higher refuses invalid_snapshot;
zero allows metadata checks only. This is ONE aggregate BOTH-log allowance.
Cursor version1 binds root+generation+recipient and TWO bounded log records:
`{present,captured_size,offset,done,end_offset,torn}`. Both presence/sizes captured
BEFORE reading either log, once per generation. offset starts captured_size and
moves monotonically DOWN; persisted/reopened calls never reset it to live EOF.
Appends after captured size are tracked tail, not seal scan; missing-at-capture
log becoming present is entirely tail. Present log disappearance/shrink below
captured size => stale_generation, no ready. Size/presence checks run on BOTH
logs every call, including already-done logs and remaining allowance zero.

For unfinished log read backward window min(64KiB,offset,remainingAggregate).
Require exact requested bytes; short/empty read => source_unreadable (never a
nonprogress loop). Scan bytes from #chunk down to1 for newline; linear O(bytes),
NO unanchored pattern. Found newline end=start+index, torn=end<captured_size.
No newline => next offset=start; reaching0 yields end0/torn1. Each actual read
subtracts actual bytes from SAME remaining budget. No fresh allowance for log2.
Metadata discovery of missing/empty log2 still finishes exact-fit case without
read. If nonempty log2 remains with zero allowance, return partial + its captured
cursor; next call resumes it. No file data skipped, read beyond capture or source
mutation. Seal finds boundaries; later exact prefix proof detects rewrites. Size alone
cannot detect same-size replacement; no inode/hostile-ABA claim. Root/generation/
recipient cursor identity drift is stale, not guessed compatible.

Store persists cursor after every successful partial using SAME actual inbox DB
transaction/revision/generation as migration dispatch state. Reopen loads it;
never rely on Lua memory. Existing0008 migration_seal_cursor stores offsets/done/
ends/torn but lacks captured_size/present/version: writer must explicitly augment
its bounded record mapping/version (or equivalently supported bounded cursor
column), not silently resume old offsets against current EOF. Old cursor format
cannot be guessed; explicit invalidate/reseal transition preserves original
source. DB COMMIT ambiguity reloads before advancing further. Same log range
may be reread after crash BEFORE checkpoint, never skipped based on guessed save.

Fair dispatch rotates recipient AFTER EACH bounded call with persisted nextkey;
long torn suffix cannot starve other mailbox. Within recipient inbox then read
share total bytebudget; inbox eventually reaches earlier newline/0 and read
then progresses. Store supplies budget each turn; optional direct call still
bounded by default. No claim of strict wall latency from filesystem metadata IO.

QA pairs: >3windows torn suffix with earlier newline, max_bytes7, reopen every
call => finite exact same sealed end without resetting. Append everycall does
not move capture or scan upward. Both logs nonempty sum reads<=max_bytes always;
exactfit inbox + absent/empty read finishes; exactfit + nonempty read partial.
Zero budget performs zero range reads but observes shrink of DONE log. Short
read errors; absent->created becomes tail; present->missing/shrink invalidates.
Byte-inspection spy bounds scan comparisons by total bytes read, no quadratic
.* pattern. ActualSQL reopen test persists fixed capture+offset for2recipients
and dispatcher fairness. No tail stacking while this focused correction fails.

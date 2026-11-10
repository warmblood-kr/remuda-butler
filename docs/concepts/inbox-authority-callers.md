# Stage C caller inventory

Read-only inventory of FILE-era source at base 5269382 plus Phase A foundation.
These are integration sites, not claims that Phase A introduced regressions.
The sole wire contract is inbox-authority-final-seams.md v1.4.

- main.lua 487–524 imports the 585 shadow before selecting authority; 543–547
  captures mail functions. Select/gate authority before source/import/mutation.
  main.lua 1194 and launch.lua 401 invoke legacy alias migration: journal BOTH
  recipient delivery and source read in FILE_TRACKED, or use SQL authority.
- mail.lua 189 reads read logs; 201–270 hydrates archive envelopes and caches
  messages/objects; 276–339 authorizes delivered membership and loads inbox
  caches. SQL_REQUIRED must not consult these as metadata authority. Immutable
  body/note objects remain allowed through selected SQL metadata.
- mail.lua 516–571 dedup guards unknown lookup, but a found hit still hydrates
  through cache/load_message. Use selected-store metadata after promotion; an
  unknown lookup must never allocate a new mail ID.
- mail.lua 573–617 queue, 699–727 forward_delivery and 806–857 inbox rendering
  directly write legacy delivery/read/resent state. Route every path to Store
  or tracked FILE hooks. Publish content is not membership; notify only after
  positive commit. Acknowledge only successfully rendered messages.
- mail.lua 621–731 resend/find_message/Matrix target/thread/reply/forward use
  membership and metadata. Unknown membership is neither absent nor authorized.
  main.lua 831/846 and matrix_cli.lua 1039–1051 depend on these seams.
- commands.lua 865 probes find_message before member checks; notice.lua
  2162–2167 authorizes inbox-message through delivered cache. SQL rows must work
  after restart with stale/missing archive metadata, and unauthorized cached
  objects must remain inaccessible.
- mail.lua 861/867 unread/is_unread, main.lua 854–873 clear notice bookkeeping.
  Clear on known false/known zero only. SQL errors retain pending/stuck/seen.
  commands.lua 430–436 already rejects nonnumeric unknown for close: preserve
  this invariant and existing operator-force semantics.
- compaction.lua 33–35 converts pcall-success nil into zero. Unknown must defer
  with lookup_failed, not allow compaction (consumers 141/145).
- sessions.lua 397–398 and status_command.lua 223/33–34 hide unknown as zero or
  omit it. Present explicit unavailable/unknown, not a false empty inbox.
- main.lua 1777 schedule wrapper and schedule.lua 336 use unread truthiness.
  Unknown last-message read state must defer another reminder and preserve its
  last_message/sent bookkeeping.
- notice.lua 625, 1837, 1937–39, 1955 and 1973–85 can discard pending, stuck,
  accepted receipts or sent/reminder history on nil. Admit on ==true; remove or
  prune only on ==false; unknown retains records and skips new sends.
- notice.lua 1891–1929 seed reads mailbox/resent caches; 2130 compares a count
  after pcall but may receive nil. Unknown startup state must not mark seeded
  empty or drop uncertain state. Counting unread must not load all SQL metadata.
- notice.lua 766–806 sender-alert dedup and 2010–2027 newest-unanswered/leader
  reply scan delivered caches and historical bodies. Use bounded selected-store
  queries; unknown cannot prove alert absence, answered state or read state.

QA pairs each SQL-error refusal with a positive SQL path. Exercise restart with
legacy logs/envelopes removed, stale unauthorized caches, partial rendering,
fanout read isolation, caller unknown retention and recovery without duplicates.
No additional direct mail-log/envelope consumer was found outside migration/
source modules; identity.lua 86 is an identity registry, not mail membership.

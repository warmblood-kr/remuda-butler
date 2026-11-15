-- Downgrade 0003 only when no unresolved relay work exists.
--
-- The 0003 tables can hold unresolved inbound/outbox/dedupe rows. Dropping
-- them, or renaming them into an archive while live tables are recreated
-- empty, would preserve bytes but not operational work. Refuse instead: the
-- CHECK insert below fails the whole down transaction and leaves version 3
-- and every row/index untouched. An operator must resolve or explicitly
-- export the work before retrying. Any future writer that adds a new
-- unresolved state must add it to this gate.
CREATE TABLE _relay_0003_down_gate (
  ok INTEGER NOT NULL CHECK (ok = 1)
);

INSERT INTO _relay_0003_down_gate (ok)
SELECT CASE WHEN (
  (SELECT COUNT(*) FROM relay_inbound
    WHERE state IN ('unhanded','handoff_pending')) +
  (SELECT COUNT(*) FROM relay_outbox
    WHERE state IN ('pending','in_flight','uncertain')) +
  (SELECT COUNT(*) FROM relay_dedupe WHERE state = 'open')
) > 0 THEN 0 ELSE 1 END;

DROP TABLE _relay_0003_down_gate;

-- Only completed history reaches this point. Archive it under `_v3_archive`
-- names instead of dropping it, and drop only the indexes. If an archive name
-- already exists, the rename fails closed rather than overwriting evidence.
--
-- This is deliberately not an automatic production downgrade. Stop old
-- writers, verify a SQLite-consistent backup and confirm that no unresolved
-- row needs to continue before running it.
DROP INDEX IF EXISTS relay_inbound_work;
DROP INDEX IF EXISTS relay_inbound_expiry;
DROP INDEX IF EXISTS relay_outbox_work;
DROP INDEX IF EXISTS relay_outbox_expiry;
DROP INDEX IF EXISTS relay_dedupe_expiry;

ALTER TABLE relay_inbound RENAME TO relay_inbound_v3_archive;
ALTER TABLE relay_outbox RENAME TO relay_outbox_v3_archive;
ALTER TABLE relay_dedupe RENAME TO relay_dedupe_v3_archive;
ALTER TABLE relay_cursor RENAME TO relay_cursor_v3_archive;
ALTER TABLE relay_meta RENAME TO relay_meta_v3_archive;

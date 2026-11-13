-- Matrix receipt delivery projection. `status` stays the local/durable
-- delivery state; these columns track the relay write so a restart or an
-- uncertain outcome is not retried blindly.
ALTER TABLE read_receipt_intents ADD COLUMN matrix_state TEXT;
ALTER TABLE read_receipt_intents ADD COLUMN matrix_txn_id TEXT;
ALTER TABLE read_receipt_intents ADD COLUMN matrix_event_id TEXT;
ALTER TABLE read_receipt_intents ADD COLUMN matrix_updated_at TEXT;
ALTER TABLE read_receipt_intents ADD COLUMN matrix_error TEXT;

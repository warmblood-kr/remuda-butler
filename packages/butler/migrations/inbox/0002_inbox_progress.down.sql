-- Stage 2 keeps the #585 tables; only the staging rows are dropped.
DROP INDEX IF EXISTS progress_deliveries_order;
DROP TABLE IF EXISTS progress_chunkproofs;
DROP TABLE IF EXISTS progress_fileproofs;
DROP TABLE IF EXISTS progress_dependencies;
DROP TABLE IF EXISTS progress_metadata;
DROP TABLE IF EXISTS progress_reads;
DROP TABLE IF EXISTS progress_deliveries;
DROP TABLE IF EXISTS progress_state;

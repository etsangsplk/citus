SET citus.next_shard_id TO 1220000;

-- Tests for prepared transaction recovery

-- Ensure pg_dist_transaction is empty for test
SELECT recover_prepared_transactions();

SELECT * FROM pg_dist_transaction;

-- Create some "fake" prepared transactions to recover
\c - - - :worker_1_port

BEGIN;
CREATE TABLE should_abort (value int);
PREPARE TRANSACTION 'citus_0_should_abort';

BEGIN;
CREATE TABLE should_commit (value int);
PREPARE TRANSACTION 'citus_0_should_commit';

BEGIN;
CREATE TABLE should_be_sorted_into_middle (value int);
PREPARE TRANSACTION 'citus_0_should_be_sorted_into_middle';

\c - - - :master_port
-- Add "fake" pg_dist_transaction records and run recovery
INSERT INTO pg_dist_transaction VALUES (1, 'citus_0_should_commit');
INSERT INTO pg_dist_transaction VALUES (1, 'citus_0_should_be_forgotten');

SELECT recover_prepared_transactions();
SELECT count(*) FROM pg_dist_transaction;

-- Confirm that transactions were correctly rolled forward
\c - - - :worker_1_port
SELECT count(*) FROM pg_tables WHERE tablename = 'should_abort';
SELECT count(*) FROM pg_tables WHERE tablename = 'should_commit';

\c - - - :master_port
SET citus.shard_replication_factor TO 2;
SET citus.shard_count TO 2;
SET citus.multi_shard_commit_protocol TO '2pc';

-- create_distributed_table should add 2 recovery records (1 connection per node)
CREATE TABLE test_recovery (x text);
SELECT create_distributed_table('test_recovery', 'x');
SELECT count(*) FROM pg_dist_transaction;

-- create_reference_table should add another 2 recovery records
CREATE TABLE test_recovery_ref (x text);
SELECT create_reference_table('test_recovery_ref');
SELECT count(*) FROM pg_dist_transaction;

SELECT recover_prepared_transactions();

-- plain INSERT does not use 2PC
INSERT INTO test_recovery VALUES ('hello');
SELECT count(*) FROM pg_dist_transaction;

-- Committed DDL commands should write 4 transaction recovery records
BEGIN;
ALTER TABLE test_recovery ADD COLUMN y text;
ROLLBACK;
SELECT count(*) FROM pg_dist_transaction;

ALTER TABLE test_recovery ADD COLUMN y text;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();
SELECT count(*) FROM pg_dist_transaction;

-- Committed master_modify_multiple_shards should write 4 transaction recovery records
BEGIN;
SELECT master_modify_multiple_shards($$UPDATE test_recovery SET y = 'world'$$); 
ROLLBACK;
SELECT count(*) FROM pg_dist_transaction;

SELECT master_modify_multiple_shards($$UPDATE test_recovery SET y = 'world'$$);

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();
SELECT count(*) FROM pg_dist_transaction;

-- Committed INSERT..SELECT should write 4 transaction recovery records
BEGIN;
INSERT INTO test_recovery SELECT x, 'earth' FROM test_recovery;
ROLLBACK;
SELECT count(*) FROM pg_dist_transaction;

INSERT INTO test_recovery SELECT x, 'earth' FROM test_recovery;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Committed INSERT..SELECT via coordinator should write 4 transaction recovery records
INSERT INTO test_recovery (x) SELECT 'hello-'||s FROM generate_series(1,100) s;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Committed COPY should write 4 transaction records
COPY test_recovery (x) FROM STDIN CSV;
hello-0
hello-1
\.

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

DROP TABLE test_recovery_ref;
DROP TABLE test_recovery;

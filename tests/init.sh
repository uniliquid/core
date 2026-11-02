# Test only: sourced by the PostgreSQL entrypoint. Creates the roles as the
# deployment does (lqfb owns the database, lqfb_membersync runs the sync)
# and the database liquid_feedback from core.sql with units 1-12 (synthetic
# names). member_sync.sql is applied by the tests (tests/lib.php).
psql -X -q -v ON_ERROR_STOP=1 -U postgres <<'SQL'
CREATE ROLE lqfb LOGIN;
CREATE ROLE lqfb_membersync LOGIN;
CREATE DATABASE liquid_feedback OWNER lqfb;
SQL
PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 -U lqfb -d liquid_feedback -f /src/core.sql
psql -X -q -v ON_ERROR_STOP=1 -U lqfb -d liquid_feedback <<'SQL'
INSERT INTO unit (id, name) SELECT n, 'Unit ' || n FROM generate_series(1, 12) AS n;
SELECT setval('unit_id_seq', 12);
SQL

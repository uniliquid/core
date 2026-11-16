<?php

// Tests of session.sql (README, "Session additions"), run by tests/run.sh.
// Each case works on its own copy of the database. Synthetic data only.

require __DIR__ . '/lib.php';

// Applies session.sql to $db as lqfb with the deployment's command line;
// [exit status, stdout, stderr].
function apply_session($db)
{
    return run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', __DIR__ . '/../session.sql', '-U', 'lqfb', '-d', $db],
        ['PGOPTIONS' => '-c client_min_messages=warning']);
}

// A new database with session.sql applied (on top of $template).
function session_database($template = 'liquid_feedback')
{
    $db = database($template);
    [$status, , $stderr] = apply_session($db);
    if ($status !== 0) {
        fwrite(STDERR, "cannot apply session.sql: $stderr");
        exit(1);
    }
    return $db;
}

function session_count($pdo, $where = 'TRUE')
{
    return (int) $pdo->query("SELECT count(*) FROM session WHERE $where")->fetchColumn();
}

// --- Apply -----------------------------------------------------------------

$db = database();
[$status, , $stderr] = apply_session($db);
check('apply: the deployment command line succeeds', $status === 0 && $stderr === '');
[$status, , $stderr] = apply_session($db);
check('apply: a second apply succeeds (idempotent)', $status === 0 && $stderr === '');
$owner = connect($db);
check('apply: one column logged_in_at (timestamptz, nullable)', $owner->query("SELECT count(*) = 1 AND bool_and(data_type = 'timestamp with time zone')
    AND bool_and(is_nullable = 'YES') FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'session' AND column_name = 'logged_in_at'")->fetchColumn());
check('apply: one partial index on member_id', $owner->query("SELECT count(*) = 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'session' AND indexname = 'session_member_id_idx'
    AND indexdef LIKE '%(member_id) WHERE (member_id IS NOT NULL)%'")->fetchColumn());
check('apply: one lock trigger on member', $owner->query("SELECT count(*) = 1 FROM pg_trigger
    WHERE tgrelid = 'public.member'::regclass AND tgname = 'session_delete_on_member_lock'")->fetchColumn());
check('apply: a new session row has logged_in_at NULL and the 24 h default expiry', (function ($pdo) {
    $pdo->exec("INSERT INTO session (ident) VALUES ('anon')");
    return $pdo->query("SELECT logged_in_at IS NULL AND expiry BETWEEN now() + '23 hours 59 minutes' AND now() + '24 hours'
        FROM session WHERE ident = 'anon'")->fetchColumn();
})($owner));
unset($owner);

// --- Lock trigger ------------------------------------------------------------

$db = session_database();
$owner = connect($db);
$a = active_member($owner, 'test-member-1');
$b = active_member($owner, 'test-member-2');
$owner->exec("INSERT INTO session (ident, member_id, logged_in_at) VALUES ('a1', $a, now()), ('a2', $a, NULL), ('b1', $b, now()), ('anon', NULL, NULL)");
$owner->exec("UPDATE member SET locked = TRUE WHERE id = $a");
check('lock: the locked member\'s sessions are gone', session_count($owner, "member_id = $a") === 0);
check('lock: other sessions remain', session_count($owner) === 2 && session_count($owner, "ident IN ('b1', 'anon')") === 2);
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('a3', $a)");
$owner->exec("UPDATE member SET name = 'Name changed' WHERE id = $a");
check('lock: another column of a locked member changed -> nothing deleted', session_count($owner, "member_id = $a") === 1);
$owner->exec("UPDATE member SET locked = TRUE WHERE id = $a");
check('lock: locked again (already locked) -> nothing deleted', session_count($owner, "member_id = $a") === 1);
$owner->exec("UPDATE member SET locked = FALSE WHERE id = $a");
check('lock: unlock -> nothing deleted', session_count($owner, "member_id = $a") === 1);
$owner->exec("UPDATE member SET name = 'Name changed 2' WHERE id = $b");
check('lock: another column of an unlocked member changed -> nothing deleted', session_count($owner, "member_id = $b") === 1);
$owner->beginTransaction();
$owner->exec("UPDATE member SET locked = TRUE WHERE id = $b");
$owner->rollBack();
check('lock: a rolled back lock keeps the sessions', session_count($owner, "member_id = $b") === 1);
unset($owner);

// --- Expired sessions (lf_update) --------------------------------------------

$db = session_database();
$owner = connect($db);
$a = active_member($owner, 'test-member-1');
$owner->exec("INSERT INTO session (ident, member_id, logged_in_at, expiry) VALUES
    ('old-anon', NULL, NULL, now() - '1 second'::interval),
    ('old-login', $a, now() - '40 days'::interval, now() - '1 second'::interval),
    ('old-legacy', $a, NULL, now() - '1 second'::interval),
    ('live-anon', NULL, NULL, now() + '1 hour'::interval),
    ('live-login', $a, now(), now() + '30 days'::interval)");
$owner->exec('DELETE FROM expired_session');
check('expired_session: expired rows deleted (with and without logged_in_at), live rows kept',
    column($owner, 'SELECT ident FROM session ORDER BY ident') === ['live-anon', 'live-login']);
unset($owner);

// --- delete_member(), delete_private_data() ----------------------------------

$db = session_database();
$owner = connect($db);
$a = active_member($owner, 'test-member-1');
$b = active_member($owner, 'test-member-2');
$owner->exec("INSERT INTO session (ident, member_id, logged_in_at) VALUES ('a1', $a, now()), ('b1', $b, now())");
$owner->exec("SELECT delete_member($a)");
check('delete_member(): runs, the member\'s sessions are gone, others kept',
    column($owner, 'SELECT ident FROM session') === ['b1'] && row($owner, 'SELECT locked FROM member WHERE id = ?', [$a])['locked'] === true);
$owner->exec('SELECT delete_private_data()');
check('delete_private_data(): runs, all sessions gone', session_count($owner) === 0);
unset($owner);

// --- Member sync with the trigger present -------------------------------------

$db = session_database(synced_database());
$owner = connect($db);
$id = active_member($owner, mv(1));
$other = active_member($owner, mv(2));
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $id), (1, $other)");
$owner->exec("INSERT INTO session (ident, member_id, logged_in_at) VALUES ('s1', $id, now()), ('s2', $id, NULL), ('s3', $other, now())");
$result = sync($db, [entry(1, false), entry(2)]);
check('member sync: a run that locks a member succeeds with the trigger present', $result === counts(['locked' => 1, 'privileges_revoked' => 1]));
check('member sync: the locked member\'s sessions are gone, the other\'s kept',
    column($owner, 'SELECT ident FROM session ORDER BY ident') === ['s3']);
check('member sync: second run, no changes', sync($db, [entry(1, false), entry(2)]) === counts());
unset($owner);

done();

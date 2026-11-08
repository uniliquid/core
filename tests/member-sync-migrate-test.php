<?php

// Tests of member-sync-migrate.php, run by tests/run.sh: the old sync's
// pseudonyms and the migration on a copy of the database with
// member_sync.sql applied. The fetch is member-sync.php's (its tests).
// Made-up keys and data only.

require __DIR__ . '/lib.php';
require __DIR__ . '/../member-sync-migrate.php';

const LEGACY_KEY = 'made-up key';

// --- The old pseudonyms -------------------------------------------------------------

// Made with phpseclib 2 (Rijndael, block and key length 256, CBC, key
// md5(key), IV md5(md5(key)), zero padding), which matches mcrypt's
// MCRYPT_RIJNDAEL_256.
foreach ([
    ['made-up key', '1', 'QKhv5KJNNyE9uRxU/TPVtH0wQEh03WAQoGS2Lsv66CY='],
    ['made-up key', '2147483647', 'Wz/FVSP8s9dG2a1J4BZcuS8Tnk6auTm86hdhbRvO34I='],
    ['another test key 123', '42', '+jmvJhesGnvYC+rXQcRNyfS8p7ZiydrAkDGDsGd0Kss='],
    ['made-up key', str_repeat('9', 33), 'xnF9IMXhPQggfBtMyp46bR11IHhRaoOhzKgzSLqQ6861jSbk/YlQ4sodwIXZxGz0QZEFiTJBoEyUS+ELUdO5Xw=='],
] as [$key, $id, $expected]) {
    check("legacy: pseudonym of $id", legacy_pseudonym($key, $id) === $expected);
    check("legacy: $id decrypted", legacy_id($key, $expected) === $id);
}
check('legacy: another key, another pseudonym', legacy_pseudonym('other', 1) !== legacy_pseudonym(LEGACY_KEY, 1));

// --- The migration ---------------------------------------------------------------------

$old = fn ($id) => legacy_pseudonym(LEGACY_KEY, $id);
$db = synced_database();
$owner = connect($db);
$ids = [
    'matched' => active_member($owner, $old(101)),
    'matched admin' => active_member($owner, $old(102), ['admin' => true, 'locked' => true]),
    'listed, Austritt' => member($owner, ['identification' => $old(103), 'admin_comment' => 'Austritt', 'locked' => true]),
    'not listed, Austritt' => member($owner, ['identification' => $old(900), 'admin_comment' => 'Austritt', 'locked' => true]),
    'Austritt, random number' => member($owner, ['identification' => '12345678', 'admin_comment' => 'Austritt', 'locked' => true]),
    'unmatched locked' => active_member($owner, $old(104), ['locked' => true]),
    'unmatched locked admin' => active_member($owner, null, ['admin' => true, 'locked' => true]),
    'unmatched unlocked' => active_member($owner, 'other'),
];
foreach ($ids as $id) {
    $owner->exec("INSERT INTO session (ident, member_id) VALUES ('s$id', $id)");
    $owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $id), (12, $id)");
}
// Listed: 101, 102, 103 and 105 (no row).
$members = member_sync_parse(json_encode([entry(101), entry(102, false), entry(103), entry(105)]));
$key = hex2bin(PSEUDONYM_KEY);
$before = state($owner);

// Runs the migration; the summary line, or the error message.
function migrate($pdo, $members, $expect, $dryRun = false, $legacyKey = LEGACY_KEY)
{
    try {
        return member_sync_migrate($pdo, $members, $legacyKey, hex2bin(PSEUDONYM_KEY), $expect, $dryRun);
    } catch (MemberSyncError $e) {
        return 'error: ' . $e->getMessage();
    }
}

$summary = "4 members: 2 rows migrated, 2 listed not migrated, 2 'Austritt' rows cleared, 4 sessions and 4 privileges of other locked rows deleted\n";
check('dry run: the counts, nothing written', migrate($owner, $members, 2, true) === "dry run: $summary" && state($owner) === $before);
check('another count: refused, nothing written', migrate($owner, $members, 3) === 'error: 2 rows match, expected 3' && state($owner) === $before);
check('another legacy key: nothing matches, nothing written', migrate($owner, $members, 2, false, 'other') === 'error: 0 rows match, expected 2'
    && state($owner) === $before);
$holder = connect($db, 'postgres');
$holder->query('SELECT pg_advisory_lock(' . MEMBER_SYNC_LOCK . ')');
check('sync running: refused, nothing written', migrate($owner, $members, 2) === 'error: the sync is running' && state($owner) === $before);
$holder->query('SELECT pg_advisory_unlock(' . MEMBER_SYNC_LOCK . ')');
unset($holder);

check('run: the counts', migrate($owner, $members, 2) === $summary);
$identification = fn ($name) => $owner->query("SELECT identification FROM member WHERE id = {$ids[$name]}")->fetchColumn();
check('run: matched rows (admins too) get the new pseudonym', $identification('matched') === mv(101) && $identification('matched admin') === mv(102));
check('run: Austritt rows with an old pseudonym cleared, listed or not', $identification('listed, Austritt') === null
    && $identification('not listed, Austritt') === null);
check('run: other identifications unchanged', $identification('Austritt, random number') === '12345678'
    && $identification('unmatched locked') === $old(104) && $identification('unmatched unlocked') === 'other');
$sessions = array_map('intval', column($owner, 'SELECT member_id FROM session ORDER BY member_id'));
check('run: sessions of unmatched locked non-admin rows (Austritt too) deleted', $sessions === [$ids['matched'], $ids['matched admin'],
    $ids['unmatched locked admin'], $ids['unmatched unlocked']]);
check('run: their privileges in managed units deleted, others kept', privileges($owner, $ids['unmatched locked']) === ['12:11']
    && privileges($owner, $ids['Austritt, random number']) === ['12:11']
    && privileges($owner, $ids['listed, Austritt']) === ['12:11']
    && privileges($owner, $ids['unmatched locked admin']) === ['1:11', '12:11']
    && privileges($owner, $ids['matched']) === ['1:11', '12:11']);
check('run: a second run matches nothing and is refused', migrate($owner, $members, 2) === 'error: 0 rows match, expected 2');
check('after: the sync reconciles the migrated rows', sync($db, [entry(101), entry(102, false), entry(103), entry(105)])
    === counts(['created' => 2, 'privileges_granted' => 2, 'privileges_revoked' => 1]));
check('after: the migrated rows kept, the matched admin still locked', $identification('matched') === mv(101)
    && units($owner, $ids['matched']) === [1, 12] && units($owner, $ids['matched admin']) === [12]
    && $owner->query("SELECT locked FROM member WHERE id = {$ids['matched admin']}")->fetchColumn() === true);

// --- Command line ------------------------------------------------------------------------

$tmp = sys_get_temp_dir() . '/member-sync-migrate-test-' . getmypid();
mkdir($tmp);
file_put_contents("$tmp/legacy", LEGACY_KEY . "\n");
file_put_contents("$tmp/empty", "\n");
file_put_contents("$tmp/secrets.php", '<?php return ' . var_export(['url' => 'https://127.0.0.1:9/', 'token' => str_repeat('0', 64),
    'cafile' => "$tmp/legacy", 'pseudonym_key' => 'short', 'dsn' => 'pgsql:host=' . SOCKET . ";dbname=$db"], true) . ';');
$usage = "member-sync-migrate: usage: member-sync-migrate.php --expect=<n> --legacy-key-file=<file> [--dry-run] [--secrets=<file>]; nothing written\n";
foreach ([
    'no arguments' => [[], $usage],
    'no --expect' => [["--legacy-key-file=$tmp/legacy"], $usage],
    'no legacy key file' => [['--expect=2'], $usage],
    '--expect not a number' => [['--expect=x', "--legacy-key-file=$tmp/legacy"], $usage],
    'unknown option' => [['--expect=2', "--legacy-key-file=$tmp/legacy", '--force'], $usage],
    'legacy key file missing' => [['--expect=2', "--legacy-key-file=$tmp/missing"], "member-sync-migrate: no legacy key; nothing written\n"],
    'legacy key empty' => [['--expect=2', "--legacy-key-file=$tmp/empty"], "member-sync-migrate: no legacy key; nothing written\n"],
    'no pseudonym key' => [['--expect=2', "--legacy-key-file=$tmp/legacy", "--secrets=$tmp/secrets.php"],
        "member-sync-migrate: the pseudonym key must be at least 64 lowercase hex digits (an even number); nothing written\n"],
    'fetch fails' => [['--expect=2', "--legacy-key-file=$tmp/legacy", "--secrets=$tmp/secrets.php"], null],
] as $name => [$args, $message]) {
    if ($message === null) {
        $secrets = include "$tmp/secrets.php";
        file_put_contents("$tmp/secrets.php", '<?php return ' . var_export(['pseudonym_key' => PSEUDONYM_KEY] + $secrets, true) . ';');
    }
    [$status, $stdout, $stderr] = run(array_merge([PHP_BINARY, __DIR__ . '/../member-sync-migrate.php'], $args), ['PGUSER' => 'lqfb']);
    check("command line: $name (exit 1, message)", $status === 1 && $stdout === ''
        && ($message === null ? str_starts_with($stderr, 'member-sync-migrate: fetch failed: ') : $stderr === $message));
}

done();

<?php

// Tests of member_sync_mail.lua (the mail worker), run by tests/run.sh: its
// flow with stand-ins for the frontend's WebMCP functions
// (tests/webmcp-stub.lua, Lua 5.1), and its SQL statements against a copy
// of the database with member_sync.sql applied. Synthetic data only.

require __DIR__ . '/lib.php';

// Runs the worker for a scenario of webmcp-stub.lua; [exit status, stdout lines, stderr].
function worker($scenario)
{
    [$status, $stdout, $stderr] = run(['lua5.1', __DIR__ . '/webmcp-stub.lua'],
        ['LF_CORE_DIR' => dirname(__DIR__), 'STUB_SCENARIO' => $scenario]);
    return [$status, array_values(array_filter(explode("\n", $stdout), 'strlen')), $stderr];
}

// --- Flow --------------------------------------------------------------------

[$status, $lines, $stderr] = worker('ok');
check('send OK: invite, locked and unlocked mails, texts from the core files', $lines === [
    'mail m1@example.org|Invitation|Invite code',
    'mail m2@example.org|[Liquid] Sperrung des Accounts|Hallo,',
    'mail m3@example.org|[Liquid] Freischaltung des Accounts|Hallo',
    '3 sent, 0 failed',
    'code 1 NEW',
    'exit 0',
]);
check('send OK: exit 0, queue empty, nothing on stderr', $status === 0 && $stderr === '');

[$status, $lines] = worker('fail');
check('send failing: rows stay queued, the saved invite code rolled back, exit 1', $status === 1 && $lines === [
    'mail fail1@example.org|Invitation|Invite code',
    'mail fail2@example.org|[Liquid] Freischaltung des Accounts|Hallo',
    'mail m3@example.org|[Liquid] Sperrung des Accounts|Hallo,',
    '1 sent, 2 failed',
    'queue 1 invite t1',
    'code 1 OLD',
    'queue 2 unlocked t2',
    'exit 1',
]);

[$status, $lines] = worker('stale');
check('stale rows: deleted unsent, the fitting one sent', $status === 0 && $lines === [
    'mail m3@example.org|[Liquid] Sperrung des Accounts|Hallo,',
    '1 sent, 0 failed',
    'exit 0',
]);

[$status, $lines] = worker('skipped');
check('skipped rows: replaced while waiting for the lock, not sent, not failed, the replacement kept', $status === 0 && $lines === [
    '0 sent, 0 failed',
    'queue 1 locked new',
    'queue 2 locked new',
    'exit 0',
]);

[$status, $lines, $stderr] = worker('dberror');
check('database error: exit 1 with a message', $status === 1 && $lines === ['0 sent, 0 failed', 'queue 1 invite t1', 'exit 1']
    && str_starts_with($stderr, 'member_sync_mail: '));

// --- SQL ---------------------------------------------------------------------

preg_match_all('/db:query[({] ?"([^"]+)"/', file_get_contents(__DIR__ . '/../member_sync_mail.lua'), $matches);
$statements = $matches[1];
$stale = array_values(array_filter($statements, fn ($sql) => str_starts_with($sql, 'DELETE FROM member_sync_mail USING')))[0] ?? null;
check('SQL: the worker has its statements', count($statements) === 9 && $stale !== null);

$db = synced_database();
$owner = connect($db);
$replacedId = member($owner, ['identification' => 'mv:1', 'notify_email' => 'm1@example.org']);
$staleId = member($owner, ['identification' => 'mv:2', 'notify_email' => 'm2@example.org']);
// Both "locked" rows are stale (the members are not locked).
$owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($replacedId, 'locked'), ($staleId, 'locked')");
// The sync replaces one row (an invite, which fits) while the stale delete waits for its lock.
$sync = connect($db);
$sync->beginTransaction();
$sync->exec("UPDATE member_sync_mail SET kind = 'invite', created = now() WHERE member_id = $replacedId");
$process = proc_open(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'lqfb', '-d', $db, '-c', $stale],
    [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, ['PATH' => getenv('PATH'), 'PGHOST' => SOCKET]);
for ($try = 0; $try < 50 && (int) $owner->query("SELECT count(*) FROM pg_stat_activity WHERE datname = '$db' AND wait_event_type = 'Lock'")->fetchColumn() === 0; $try++) {
    usleep(100000);
}
$waited = $try < 50;
$sync->commit();
stream_get_contents($pipes[1]);
$status = proc_close($process);
check('stale delete: waited for the lock of the replaced row', $waited && $status === 0);
check('stale delete: by the whole key, the replacement survives, the stale row goes',
    column($owner, 'SELECT member_id || kind FROM member_sync_mail ORDER BY member_id') === ["{$replacedId}invite"]);

// The per-row statements are valid for the schema; the re-check finds the row by its whole key only.
$created = $owner->query("SELECT created::text FROM member_sync_mail WHERE member_id = $replacedId")->fetchColumn();
$owner->beginTransaction();
$results = [];
foreach ($statements as $sql) {
    if ($sql === $stale || !str_contains($sql, '?')) {
        continue;
    }
    $params = array_slice([$replacedId, 'invite', $created], 0, substr_count($sql, '?'));
    $statement = $owner->prepare($sql);
    $statement->execute($params);
    $results[] = $statement->rowCount();
}
$owner->rollBack();
check('per-row statements: lock member, lock queue row, re-check (found), delete (one row)', $results === [1, 1, 1, 1]);
$statement = $owner->prepare(array_values(array_filter($statements, fn ($sql) => str_starts_with($sql, 'SELECT notify_email')))[0]);
$statement->execute([$replacedId, 'invite', '2000-01-01 00:00:00+00']);
check('per-row re-check: another time -> not found (skipped)', $statement->fetchAll() === []);

done();

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
check('SQL: the worker has its statements', count($statements) === 8);

// The per-row statements are valid for the schema; the re-check finds the
// row by its whole key only; a row that is not due is deleted by its whole key.
$db = synced_database();
$owner = connect($db);
$dueId = member($owner, ['identification' => mv(1), 'notify_email' => 'm1@example.org']);
$staleId = member($owner, ['identification' => mv(2), 'notify_email' => 'm2@example.org']);
// The "locked" row is not due (the member is not locked).
$owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($dueId, 'invite'), ($staleId, 'locked')");
$perRow = array_values(array_filter($statements, fn ($sql) => str_contains($sql, '?')));
$run = function ($id, $kind, $created) use ($owner, $perRow) {
    $results = [];
    foreach ($perRow as $sql) {
        $statement = $owner->prepare($sql);
        $statement->execute(array_slice([$id, $kind, $created], 0, substr_count($sql, '?')));
        $results[] = $statement->rowCount();
    }
    return $results;
};
$created = fn ($id) => $owner->query("SELECT created::text FROM member_sync_mail WHERE member_id = $id")->fetchColumn();
$owner->beginTransaction();
$results = $run($dueId, 'invite', $created($dueId));
$owner->rollBack();
check('per-row statements: lock member, lock queue row, re-check (found), delete (one row)', $results === [1, 1, 1, 1]);
$owner->beginTransaction();
$results = $run($staleId, 'locked', '2000-01-01 00:00:00+00');
$owner->commit();
check('per-row statements: another time (replaced) -> not found, nothing deleted', $results === [1, 1, 0, 0]
    && queued($owner, $staleId) === 'locked');
$owner->beginTransaction();
$results = $run($staleId, 'locked', $created($staleId));
$owner->commit();
check('per-row statements: not due -> not found, deleted', $results === [1, 1, 0, 1] && queued($owner, $staleId) === null);

// Two overlapping workers on the same row: the second waits at the member
// lock (no deadlock with the first one's invite code UPDATE, as
// send_invitation() saves it, while the second holds a lock on the member).
$memberLock = array_values(array_filter($statements, fn ($sql) => str_starts_with($sql, 'SELECT NULL FROM member WHERE')))[0];
$queueLock = array_values(array_filter($statements, fn ($sql) => str_starts_with($sql, 'SELECT NULL FROM member_sync_mail WHERE')))[0];
$db = synced_database();
$owner = connect($db);
$id = member($owner, ['identification' => mv(1), 'notify_email' => 'm1@example.org']);
$owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($id, 'invite')");
$first = connect($db);
$first->beginTransaction();
foreach ([$memberLock, $queueLock] as $sql) {
    $first->prepare($sql)->execute([$id]);
}
$second = proc_open(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'lqfb', '-d', $db, '-c', 'BEGIN', '-c', str_replace('?', (string) $id, $memberLock),
    '-c', str_replace('?', (string) $id, $queueLock), '-c', 'COMMIT'], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null,
    ['PATH' => getenv('PATH'), 'PGHOST' => SOCKET]);
for ($try = 0; $try < 50 && (int) $owner->query("SELECT count(*) FROM pg_stat_activity WHERE datname = '$db' AND wait_event_type = 'Lock'")->fetchColumn() === 0; $try++) {
    usleep(100000);
}
try {
    $first->exec("UPDATE member SET invite_code = 'NEW' WHERE id = $id");
    $first->commit();
    $firstDone = true;
} catch (PDOException $e) {
    $firstDone = false;
}
stream_get_contents($pipes[1]);
$secondStatus = proc_close($second);
check('overlapping workers: the second waits at the member lock', $try < 50);
check('overlapping workers: no deadlock, both complete', $firstDone && $secondStatus === 0);

done();

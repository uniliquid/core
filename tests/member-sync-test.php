<?php

// Tests of member-sync.php, run by tests/run.sh. member-sync.php runs as a
// separate process against the HTTPS test server (tests/https-server.php)
// with self-signed certificates made here, and a copy of the database with
// member_sync.sql applied. Synthetic data only.

require __DIR__ . '/lib.php';
require __DIR__ . '/../member-sync.php';

const TOKEN = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const PORT = 8443;
const OTHER_NAME_PORT = 8444;

$tmp = sys_get_temp_dir() . '/member-sync-test-' . getmypid();
mkdir($tmp);

// A self-signed certificate (with its key) for the subject alternative name
// $san; returns [PEM file with certificate and key, certificate file].
function certificate($name, $san)
{
    global $tmp;
    $cnf = "$tmp/$name.cnf";
    file_put_contents($cnf, "[req]\ndistinguished_name = dn\n[dn]\n[ext]\nsubjectAltName = $san\nbasicConstraints = critical, CA:TRUE\n");
    $options = ['config' => $cnf, 'digest_alg' => 'sha256'];
    $key = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1'] + $options);
    $csr = openssl_csr_new(['commonName' => $name], $key, $options);
    $cert = openssl_csr_sign($csr, null, $key, 30, ['x509_extensions' => 'ext'] + $options, random_int(1, PHP_INT_MAX));
    openssl_x509_export($cert, $certPem);
    openssl_pkey_export($key, $keyPem, null, $options);
    file_put_contents("$tmp/$name.crt", $certPem);
    file_put_contents("$tmp/$name.pem", $certPem . $keyPem);
    return ["$tmp/$name.pem", "$tmp/$name.crt"];
}

[$serverPem, $serverCrt] = certificate('server', 'IP:127.0.0.1');
[, $otherCrt] = certificate('other', 'IP:127.0.0.1');
[$otherNamePem, $otherNameCrt] = certificate('othername', 'DNS:other.invalid');
$document = "$tmp/document.json";
file_put_contents($document, '[]');

$servers = [];
foreach ([PORT => $serverPem, OTHER_NAME_PORT => $otherNamePem] as $port => $pem) {
    $servers[] = proc_open(
        [PHP_BINARY, __DIR__ . '/https-server.php', (string) $port, $pem, TOKEN, $document],
        [0 => ['pipe', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']],
        $pipes,
    );
}
for ($try = 0; $try < 50 && @fsockopen('127.0.0.1', PORT) === false; $try++) {
    usleep(100000);
}

$db = synced_database();
$secrets = [
    'url' => 'https://127.0.0.1:' . PORT . '/liquid-members.php',
    'token' => TOKEN,
    'cafile' => $serverCrt,
    'pseudonym_key' => PSEUDONYM_KEY,
    'dsn' => 'pgsql:host=' . SOCKET . ";dbname=$db",
    'user' => 'lqfb_membersync',
    'removals' => 'on',
];

// A secrets file with $config (an array or PHP source); returns its path.
function secrets_file($config)
{
    global $tmp;
    static $count = 0;
    $file = "$tmp/secrets-" . $count++ . '.php';
    file_put_contents($file, is_string($config) ? $config : '<?php return ' . var_export($config, true) . ';');
    return $file;
}

$outputs = '';

// Starts member-sync.php with $args; returns the process. $members is what
// the server serves; $override is merged into the secrets file passed with
// --secrets, unless $args or $env already choose one.
function start($members, $override = [], $args = [], $env = [])
{
    global $secrets, $document;
    file_put_contents($document, is_string($members) ? $members : json_encode($members));
    if (!array_filter($args, fn ($arg) => str_starts_with($arg, '--secrets')) && !isset($env['MEMBER_SYNC_SECRETS'])) {
        $args[] = '--secrets=' . secrets_file($override + $secrets);
    }
    $process = proc_open(array_merge([PHP_BINARY, __DIR__ . '/../member-sync.php'], $args),
        [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env + ['PATH' => getenv('PATH')]);
    return [$process, $pipes];
}

// Waits for a process from start(); [exit status, stdout, stderr].
function finish($started)
{
    global $outputs;
    [$process, $pipes] = $started;
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    $status = proc_close($process);
    $outputs .= $stdout . $stderr;
    return [$status, $stdout, $stderr];
}

function member_sync($members, $override = [], $args = [], $env = [])
{
    return finish(start($members, $override, $args, $env));
}

$owner = connect($db);
$lockedId = active_member($owner, mv(2), ['locked' => true, 'notify_email' => 'member2@example.org']);
$leaverId = active_member($owner, mv(3));
$members = [entry(1, true, 38, ['AT130']), entry(2), entry(4, false), entry(5, true, null, [], null)];
$initial = state($owner);
// The list as member-sync.php passes it to public.member_sync().
$pseudonymised = fn ($members) => member_sync_pseudonymise(member_sync_parse(json_encode($members)), hex2bin(PSEUDONYM_KEY));

// --- Fetch and parse ----------------------------------------------------------

check('parse: a list of objects', member_sync_parse(json_encode($members)) == json_decode(json_encode($members)));
foreach ([
    'empty list' => '[]',
    'empty list with spaces' => " [ ]\n",
    'not JSON' => '<html>',
    'an object' => '{"id": 1}',
    'null' => 'null',
    'an entry not an object' => '[1]',
    'a list in a list' => '[[]]',
    'too deep' => '[{"id": 1, "lo": null, "eligible": true, "email": null, "regions": [["AT130"]]}]',
    'trailing garbage' => '[{"id": 1}] x',
    'id missing' => '[{"lo": null}]',
    'id null' => '[{"id": null}]',
    'id 0' => '[{"id": 0}]',
    'id negative' => '[{"id": -1}]',
    'id a string' => '[{"id": "1"}]',
    'id a float' => '[{"id": 1.5}]',
    'id 1.0' => '[{"id": 1.0}]',
    'id too large' => '[{"id": 2147483648}]',
    'id far too large' => '[{"id": 99999999999999999999}]',
    'an identification already' => '[{"id": 1, "identification": "mv:1"}]',
    'one bad entry after a good one' => '[{"id": 1}, {"id": 0}]',
] as $name => $body) {
    check("parse: refused, $name", member_sync_parse($body) === null);
}
check('parse: id 2147483647 accepted', member_sync_parse('[{"id": 2147483647}]') !== null);
$list = json_decode($pseudonymised([entry(1, true, 38, ['AT130']), entry(12345, false)]), true);
check('pseudonymise: id replaced by mv:<HMAC-SHA256 of the decimal id>, the rest kept', $list === [
    ['lo' => 38, 'eligible' => true, 'email' => 'member1@example.org', 'regions' => ['AT130'],
        'identification' => 'mv:' . hash_hmac('sha256', '1', hex2bin(PSEUDONYM_KEY))],
    ['lo' => null, 'eligible' => false, 'email' => 'member12345@example.org', 'regions' => [],
        'identification' => 'mv:36e295174c2947fbba5ff2d280b635a4b2eaa3106e07c7f1f3d2b72cba861447'],
]);

// Refusals before any write: non-zero exit, a message, data unchanged.
$refusals = [
    'no secrets file given' => member_sync($members, [], ['--secrets=']),
    'secrets file missing' => member_sync($members, [], ["--secrets=$tmp/missing.php"]),
    'secrets file not an array' => member_sync($members, [], ['--secrets=' . secrets_file('<?php return 1;')]),
    'secrets file with a syntax error' => member_sync($members, [], ['--secrets=' . secrets_file('<?php return [;')]),
    'unknown option' => member_sync($members, [], ['--dryrun']),
    'empty token' => member_sync($members, ['token' => '']),
    'token not a string' => member_sync($members, ['token' => 1]),
    'token not hex' => member_sync($members, ['token' => strtoupper(TOKEN)]),
    'token too short' => member_sync($members, ['token' => substr(TOKEN, 1)]),
    'token with a line break' => member_sync($members, ['token' => TOKEN . "\n"]),
    'URL with a line break' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . "/liquid-members.php\r\nX-Injected: 1"]),
    'URL with a space' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/liquid-members.php x']),
    'URL not https' => member_sync($members, ['url' => 'http://127.0.0.1:' . PORT . '/liquid-members.php']),
    'URL missing' => member_sync($members, ['url' => '']),
    'URL with user info' => member_sync($members, ['url' => 'https://user@127.0.0.1:' . PORT . '/liquid-members.php']),
    'cafile missing' => member_sync($members, ['cafile' => "$tmp/missing.crt"]),
    'cafile empty' => member_sync($members, ['cafile' => '']),
    'pseudonym key missing' => member_sync($members, ['pseudonym_key' => null]),
    'pseudonym key too short' => member_sync($members, ['pseudonym_key' => substr(PSEUDONYM_KEY, 2)]),
    'pseudonym key odd length' => member_sync($members, ['pseudonym_key' => PSEUDONYM_KEY . '0']),
    'pseudonym key upper case' => member_sync($members, ['pseudonym_key' => strtoupper(PSEUDONYM_KEY)]),
    'removals neither off nor on' => member_sync($members, ['removals' => true]),
    'dsn not a string (an uncaught error)' => member_sync($members, ['dsn' => ['x']]),
    'wrong database user' => member_sync($members, ['user' => 'nobody']),
    'wrong token' => member_sync($members, ['token' => strrev(TOKEN)]),
    'HTTP 500' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/error']),
    'HTTP 404' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/missing']),
    'redirect not followed' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/redirect']),
    'certificate not the cafile' => member_sync($members, ['cafile' => $otherCrt]),
    'certificate for another name' => member_sync($members, ['url' => 'https://127.0.0.1:' . OTHER_NAME_PORT . '/liquid-members.php', 'cafile' => $otherNameCrt]),
    'nothing listening' => member_sync($members, ['url' => 'https://127.0.0.1:9/liquid-members.php']),
    'status 2000' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/status2000']),
    'body shorter than Content-Length (closed early)' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/short']),
    'body longer than Content-Length' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/long']),
    'Content-Length malformed' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/badlength']),
    'body over 1 MiB' => member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/big']),
    'empty list (zero rows)' => member_sync([]),
    'not JSON' => member_sync('<html>'),
];
foreach ($refusals as $name => [$status, $stdout, $stderr]) {
    check("refused: $name (exit 1, message, nothing written)", $status === 1 && $stdout === ''
        && preg_match('/^member-sync: .+; nothing written\n$/', $stderr) === 1 && state($owner) === $initial);
}
check('refused: messages', $refusals['wrong token'][2] === "member-sync: fetch failed: HTTP/1.0 403 Forbidden; nothing written\n"
    && $refusals['empty list (zero rows)'][2] === "member-sync: invalid document; nothing written\n"
    && $refusals['unknown option'][2] === "member-sync: usage: member-sync.php [--dry-run] [--verbose] [--secrets=<file>]; nothing written\n"
    && $refusals['wrong database user'][2] === "member-sync: database: 08006; nothing written\n"
    && $refusals['token not hex'][2] === "member-sync: the token must be 64 lowercase hex digits; nothing written\n"
    && $refusals['token with a line break'][2] === "member-sync: the token must be 64 lowercase hex digits; nothing written\n"
    && $refusals['URL with a space'][2] === "member-sync: the URL has control characters or spaces; nothing written\n"
    && $refusals['pseudonym key too short'][2] === "member-sync: the pseudonym key must be at least 64 lowercase hex digits (an even number); nothing written\n"
    && $refusals['removals neither off nor on'][2] === "member-sync: removals must be 'off' or 'on'; nothing written\n"
    && $refusals['dsn not a string (an uncaught error)'][2] === "member-sync: unexpected error; nothing written\n");
// Only member_sync()'s own texts (and the lock timeout's) are shown.
$other = new PDOException('other');
$other->errorInfo = ['22023', 7, "ERROR:  invalid value \"member1@example.org\"\nDETAIL: x"];
$own = new PDOException('own');
$own->errorInfo = ['55P03', 7, "ERROR:  member_sync: another run holds the lock\nCONTEXT: x"];
// The severity prefix in the server's message language.
$german = new PDOException('de');
$german->errorInfo = ['22023', 7, "FEHLER:  member_sync: entry 2: bad id\nKONTEXT: x"];
$cyrillic = new PDOException('ru');
$cyrillic->errorInfo = ['22023', 7, "ОШИБКА:  member_sync: entry 3: bad id"];
check('error text: the severity prefix is stripped in any language', member_sync_database_error($german) === 'database: 22023 (member_sync: entry 2: bad id)'
    && member_sync_database_error($cyrillic) === 'database: 22023 (member_sync: entry 3: bad id)');
check('error text: another 22023 message is not shown, member_sync\'s is', member_sync_database_error($other) === 'database: 22023'
    && member_sync_database_error($own) === 'database: 55P03 (member_sync: another run holds the lock)');

// Rejected by the SQL validation: rolled back.
[$status, $stdout, $stderr] = member_sync([entry(1, 'yes')]);
check('SQL validation: exit 1, rolled back, SQLSTATE and the position and field', $status === 1 && $stdout === ''
    && $stderr === "member-sync: database: 22023 (member_sync: entry 1: eligible not a boolean); rolled back, nothing written\n"
    && state($owner) === $initial);
[$status, , $stderr] = member_sync([entry(1, true, 46)]);
check('SQL validation: an LO not in the map named as such', $status === 1
    && $stderr === "member-sync: database: 22023 (member_sync: entry 1: lo not null and not in the map); rolled back, nothing written\n");

// A row lock held elsewhere (e.g. by the mail worker) ends the run after the
// lock timeout (60 s; shorter here): 55P03 with its text, nothing written.
$holder = connect($db);
$holder->beginTransaction();
$holder->query("SELECT * FROM member WHERE id = $lockedId FOR UPDATE");
$writer = connect($db, 'lqfb_membersync');
try {
    member_sync_apply($writer, $pseudonymised($members), false, true, false, '1s');
    $error = null;
} catch (PDOException $e) {
    $error = member_sync_database_error($e);
}
$holder->rollBack();
unset($holder);
check('lock timeout: 55P03 with its text, nothing written', $error === 'database: 55P03 (canceling statement due to lock timeout)'
    && state($owner) === $initial);
check('lock timeout: for the transaction only (SET LOCAL), 60 s by default', $writer->query('SHOW lock_timeout')->fetchColumn() === '0'
    && !$writer->inTransaction() && (new ReflectionFunction('member_sync_apply'))->getParameters()[5]->getDefaultValue() === '60s');
unset($writer);

// The timeout (20 s; shorter here) applies to the fetch.
try {
    member_sync_fetch(['url' => 'https://127.0.0.1:' . PORT . '/slow'] + $secrets, 1);
    check('timeout: the fetch fails', false);
} catch (MemberSyncError $e) {
    check('timeout: the fetch fails', $e->getMessage() === 'fetch failed: timeout');
}
// The timeout is overall: a peer that sends the headers a line or the body a
// byte at a time (each read well within the timeout) is cut off at the end.
foreach (['/trickle' => 'body', '/tricklehead' => 'headers'] as $path => $part) {
    sleep(7); // until the test server is done with the previous request
    $start = microtime(true);
    try {
        member_sync_fetch(['url' => 'https://127.0.0.1:' . PORT . $path] + $secrets, 2);
        $failed = false;
    } catch (MemberSyncError $e) {
        $failed = true;
    }
    check("timeout: trickled $part, the fetch fails at the deadline", $failed && microtime(true) - $start < 4);
}
sleep(7);

// --- Runs ------------------------------------------------------------------------

[$status, $stdout, $stderr] = member_sync($members, [], ['--dry-run']);
check('dry run: exit 0, nothing written', $status === 0 && $stderr === '' && state($owner) === $initial);
check('dry run: the counts only, prefixed', $stdout === "dry run: 4 members: 1 created, 1 unlocked, 0 locked, 1 deleted, 0 anonymised, "
    . "4 privileges granted, 0 privileges revoked, 0 emails updated, 1 without email\n");

[$status, $stdout, $stderr] = member_sync($members);
check('run: exit 0, summary line only', $status === 0 && $stderr === '' && $stdout === "4 members: 1 created, 1 unlocked, 0 locked, "
    . "1 deleted, 0 anonymised, 4 privileges granted, 0 privileges revoked, 0 emails updated, 1 without email\n");
check('run: written', id_of($owner, mv(1)) !== null && row($owner, "SELECT locked FROM member WHERE id = $lockedId")['locked'] === false
    && row($owner, "SELECT id FROM member WHERE id = $leaverId") === false);
$synced = state($owner);
[$status, $stdout] = member_sync($members);
check('second run: no changes', $status === 0 && str_contains($stdout, ' 0 created, 0 unlocked, 0 locked, 0 deleted, 0 anonymised, 0 privileges granted, 0 privileges revoked, 0 emails updated') && state($owner) === $synced);

// The lock timeout is for the transaction only, also after a commit.
$writer = connect($db, 'lqfb_membersync');
ob_start();
member_sync_apply($writer, $pseudonymised($members), false, true, false, '1s');
ob_end_clean();
check('lock timeout: not left in the session after a commit', $writer->query('SHOW lock_timeout')->fetchColumn() === '0');
unset($writer);
[$status] = member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/noreason']);
check('status line "HTTP/1.0 200": accepted', $status === 0);
[$status] = member_sync($members, [], [], ['MEMBER_SYNC_SECRETS' => secrets_file($secrets)]);
check('secrets file from MEMBER_SYNC_SECRETS', $status === 0);
[$status] = member_sync($members, [], ['--secrets=' . secrets_file($secrets)], ['MEMBER_SYNC_SECRETS' => "$tmp/missing.php"]);
check('--secrets wins over MEMBER_SYNC_SECRETS', $status === 0);
[$status] = member_sync($members, ['url' => 'https://127.0.0.1:' . PORT . '/slow', 'timeout' => 1]);
check('timeout key in the secrets file: ignored', $status === 0);

// --- Serialised runs (session advisory lock from before the fetch) ----------------

$owner->exec("UPDATE member SET locked = TRUE WHERE id = $lockedId");
$before = state($owner);
$holder = connect($db, 'postgres');
$holder->query('SELECT pg_advisory_lock(' . MEMBER_SYNC_LOCK . ')');
[$status, $stdout, $stderr] = member_sync($members);
check('lock held by another session: exit 1, nothing written', $status === 1 && $stdout === ''
    && $stderr === "member-sync: another run is in progress; nothing written\n" && state($owner) === $before);
$holder->query('SELECT pg_advisory_unlock(' . MEMBER_SYNC_LOCK . ')');
unset($holder);
// A first run with a slow fetch holds the lock; a second run started later
// (whose fetch would finish first) fails without fetching.
$first = start($members, ['url' => 'https://127.0.0.1:' . PORT . '/slow']);
usleep(1500000);
$second = finish(start($members));
$first = finish($first);
check('concurrent runs: the later one fails at once, nothing written by it', $second[0] === 1
    && $second[2] === "member-sync: another run is in progress; nothing written\n");
check('concurrent runs: the first one completes', $first[0] === 0 && row($owner, "SELECT locked FROM member WHERE id = $lockedId")['locked'] === false);

// SQL error: rolled back (the function revoked for the test).
$admin = connect($db, 'postgres');
$admin->exec('REVOKE EXECUTE ON FUNCTION public.member_sync(jsonb, boolean) FROM lqfb_membersync');
$owner->exec("UPDATE member SET locked = TRUE WHERE id = $lockedId");
$before = state($owner);
[$status, $stdout, $stderr] = member_sync($members);
check('SQL error: exit 1, rolled back, SQLSTATE only', $status === 1 && $stdout === ''
    && $stderr === "member-sync: database: 42501; rolled back, nothing written\n" && state($owner) === $before);
$admin->exec('GRANT EXECUTE ON FUNCTION public.member_sync(jsonb, boolean) TO lqfb_membersync');
unset($admin);

// --- Removals off ('off', or no setting): the additions only --------------------

$leaverId = active_member($owner, mv(99));
$before = state($owner);
[$status, $stdout, $stderr] = member_sync($members, ['removals' => 'off'], ['--dry-run']);
check('removals off, dry run: exit 0, nothing written, the would-counts', $status === 0 && $stderr === '' && state($owner) === $before
    && $stdout === "dry run: 4 members: 0 created, 1 unlocked, would lock 0, would delete 1, would anonymise 0, "
    . "0 privileges granted, would revoke 0 privileges, 0 emails updated, 1 without email\n");
$noSetting = $secrets;
unset($noSetting['removals']);
[$status, $stdout, $stderr] = member_sync($members, [], ['--secrets=' . secrets_file($noSetting)]);
check('removals not set = off: exit 0, the would-counts', $status === 0 && $stderr === ''
    && $stdout === "4 members: 0 created, 1 unlocked, would lock 0, would delete 1, would anonymise 0, "
    . "0 privileges granted, would revoke 0 privileges, 0 emails updated, 1 without email\n");
check('removals off: the unlock done, the leaver kept', row($owner, "SELECT locked FROM member WHERE id = $lockedId")['locked'] === false
    && row($owner, "SELECT id FROM member WHERE id = $leaverId") !== false);
// --verbose: one line per change before the summary, the Liquid member id only.
$leaver2Id = active_member($owner, mv(98));
$owner->exec("UPDATE member SET locked = TRUE WHERE id = $lockedId");
[$status, $stdout, $stderr] = member_sync($members, ['removals' => 'off'], ['--dry-run', '--verbose']);
check('verbose, removals off, dry run: the change lines, then the summary, nothing written', $status === 0 && $stderr === ''
    && $stdout === "member $lockedId: unlocked\nmember $lockedId: mail queued unlocked\nmember $leaverId: would delete\nmember $leaver2Id: would delete\n"
    . "dry run: 4 members: 0 created, 1 unlocked, would lock 0, would delete 2, would anonymise 0, "
    . "0 privileges granted, would revoke 0 privileges, 0 emails updated, 1 without email\n");
[$status, $stdout] = member_sync($members, [], ['--verbose', '--dry-run']);
check('verbose, removals on, dry run: the change lines', $status === 0
    && str_starts_with($stdout, "member $lockedId: unlocked\nmember $lockedId: mail queued unlocked\nmember $leaverId: deleted\nmember $leaver2Id: deleted\ndry run: "));
check('verbose: the member id and the action only', preg_match_all('/^member [0-9]+: [a-z +-]*[0-9]*$/m', $stdout) === 4);
[$status, $stdout] = member_sync($members);
check('removals on: the leavers deleted', $status === 0 && str_contains($stdout, ' 2 deleted, ')
    && row($owner, "SELECT id FROM member WHERE id = $leaverId") === false);

check('no token, key, emails or ids in any output', !str_contains($outputs, TOKEN) && !str_contains($outputs, PSEUDONYM_KEY) && !str_contains($outputs, '@')
    && !preg_match('/mv:|\bid\b/', $outputs));

foreach ($servers as $server) {
    proc_terminate($server);
}
done();

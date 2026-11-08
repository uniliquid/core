<?php

// Member list from Admidio (CLI, PHP 8.5 with pdo_pgsql, run every 10
// minutes by a systemd timer as the user and database role lqfb_membersync):
//   php member-sync.php [--dry-run] [--verbose] [--secrets=<file>]
// Fetches the Admidio add-ons' member list for Liquid (JSON [{"id": int,
// "lo": int|null, "eligible": bool, "email": string|null, "regions":
// [string, ...]}, ...]), replaces each id by its pseudonym ("identification":
// 'mv:' and the lowercase hex HMAC-SHA256 of the id with the key of the
// secrets file; the Liquid database never sees Admidio user ids) and applies
// it with public.member_sync() (member_sync.sql), which validates the whole
// list and writes it in one transaction (README, "Member sync"). A session advisory lock serialises
// the runs from before the fetch: a run that finds it taken fails. Prints a
// summary (counts only: the journal gets no personal data); exit status 0
// on success, 1 (and a message on stderr) otherwise; nothing is written
// then. --dry-run (run by hand) does the same, prints the summary prefixed
// "dry run: " and rolls back. --verbose (by hand) also prints, before the
// summary, one line per change with the Liquid member id only ("member
// <id>: created", ...).
//
// The secrets file (outside the document root; --secrets or the environment
// variable MEMBER_SYNC_SECRETS) returns an array:
// ['url' => 'https://<Admidio internal address>:<port>/liquid-members.php',
//  'token' => '<hex>', 'cafile' => '<Admidio certificate>',
//  'pseudonym_key' => '<hex, at least 32 random bytes>',
//  'dsn' => 'pgsql:dbname=<database>', 'user' => 'lqfb_membersync',
//  'removals' => 'off' or 'on'].
// No password: peer authentication. Removals (locking, revoking privileges,
// deleting or anonymising departed members) only with 'removals' => 'on';
// 'off' or missing: the additions only, and the summary says what the
// removals would have been ("would lock <n>", ...).

const MEMBER_SYNC_MAX_BODY = 1048576;
const MEMBER_SYNC_TIMEOUT = 20;
// The advisory lock key, also taken by public.member_sync() (member_sync.sql).
const MEMBER_SYNC_LOCK = 8251004315201937961;

class MemberSyncError extends Exception
{
}

// The secrets from $file; throws unless the URL is https without control
// characters or spaces, the token is 64 lowercase hex digits (as the
// add-ons' tokens), the cafile exists, the pseudonym key is at least 64
// lowercase hex digits (32 bytes), whole bytes, and removals (if set) is
// 'off' or 'on'.
function member_sync_secrets($file)
{
    if (!is_string($file) || $file === '' || !is_file($file)) {
        throw new MemberSyncError('no secrets file (--secrets or MEMBER_SYNC_SECRETS)');
    }
    try {
        $secrets = include $file;
    } catch (Throwable $e) {
        throw new MemberSyncError('cannot read the secrets file');
    }
    if (!is_array($secrets)) {
        throw new MemberSyncError('the secrets file does not return an array');
    }
    if (!is_string($secrets['url'] ?? null) || !str_starts_with($secrets['url'], 'https://')) {
        throw new MemberSyncError('the URL must start with https://');
    }
    if (preg_match('/[\x00-\x20\x7f]/', $secrets['url'])) {
        throw new MemberSyncError('the URL has control characters or spaces');
    }
    if (!is_string($secrets['token'] ?? null) || !preg_match('/^[0-9a-f]{64}$/D', $secrets['token'])) {
        throw new MemberSyncError('the token must be 64 lowercase hex digits');
    }
    if (!is_string($secrets['cafile'] ?? null) || !is_file($secrets['cafile'])) {
        throw new MemberSyncError('no cafile');
    }
    if (!is_string($secrets['pseudonym_key'] ?? null) || !preg_match('/^(?:[0-9a-f]{2}){32,}$/D', $secrets['pseudonym_key'])) {
        throw new MemberSyncError('the pseudonym key must be at least 64 lowercase hex digits (an even number)');
    }
    if (!in_array($secrets['removals'] ?? 'off', ['off', 'on'], true)) {
        throw new MemberSyncError("removals must be 'off' or 'on'");
    }
    return $secrets;
}

// The body of the member list (a copy of pgacc's getusers_fetch()): https
// only, the certificate verified against the cafile alone (with a cafile PHP
// does not load the system's CAs), including the host name or address of the
// URL; no redirects (a 3xx is an error); a timeout for connection, headers
// and body together ($timeout seconds; 20 except in the tests; PHP's own
// stream timeout applies to each read only); at most 1 MiB; HTTP 200
// required; and a Content-Length header, if present, must be digits only and
// equal to the body length (a body cut short by an early close is refused).
// Throws otherwise; the token is never part of a message.
function member_sync_fetch($secrets, $timeout = MEMBER_SYNC_TIMEOUT)
{
    $deadline = microtime(true) + $timeout;
    $url = parse_url($secrets['url']);
    // No user info (a password always comes with a user, if only an empty one).
    if (!is_array($url) || ($url['scheme'] ?? '') !== 'https' || !isset($url['host']) || isset($url['user'])) {
        throw new MemberSyncError('fetch failed: not an https URL');
    }
    $port = $url['port'] ?? 443;
    $context = stream_context_create([
        'ssl' => [
            'verify_peer' => true,
            'verify_peer_name' => true,
            'peer_name' => trim($url['host'], '[]'),
            'allow_self_signed' => false,
            'cafile' => $secrets['cafile'],
        ],
    ]);
    error_clear_last();
    $stream = @stream_socket_client("ssl://{$url['host']}:$port", $errno, $errstr, $timeout, STREAM_CLIENT_CONNECT, $context);
    if ($stream === false) {
        $error = error_get_last();
        throw new MemberSyncError('fetch failed: ' . ($errstr !== '' ? $errstr : ($error === null ? 'unknown error' : $error['message'])));
    }
    // HTTP/1.0: no chunked body; the connection closes after the response.
    $request = 'GET ' . ($url['path'] ?? '/') . (isset($url['query']) ? '?' . $url['query'] : '') . " HTTP/1.0\r\n"
        . 'Host: ' . $url['host'] . (isset($url['port']) ? ':' . $port : '') . "\r\n"
        . 'Authorization: Bearer ' . $secrets['token'] . "\r\nAccept: application/json\r\nConnection: close\r\n\r\n";
    $response = '';
    $timedOut = false;
    $limit = 65536 + MEMBER_SYNC_MAX_BODY + 1;
    $written = @fwrite($stream, $request) === strlen($request);
    while ($written && !feof($stream) && strlen($response) < $limit) {
        // Microseconds to the deadline, at least 1: a timeout of 0 would
        // mean none for a TLS stream; past the deadline the read times out.
        $left = max(1, (int) (($deadline - microtime(true)) * 1000000));
        stream_set_timeout($stream, intdiv($left, 1000000), $left % 1000000);
        $chunk = @fread($stream, min(65536, $limit - strlen($response)));
        if ($chunk === false || stream_get_meta_data($stream)['timed_out']) {
            $timedOut = true;
            break;
        }
        $response .= $chunk;
    }
    $complete = feof($stream);
    fclose($stream);
    if (!$written || $timedOut) {
        throw new MemberSyncError('fetch failed: ' . ($written ? 'timeout' : 'cannot send the request'));
    }
    $end = strpos($response, "\r\n\r\n");
    $status = $end === false ? '' : strstr($response, "\r\n", true);
    if (!preg_match('#^HTTP/\S+ 200( |$)#', $status)) {
        throw new MemberSyncError('fetch failed: ' . ($status !== '' ? $status : 'no status'));
    }
    $body = substr($response, $end + 4);
    if (!$complete || strlen($body) > MEMBER_SYNC_MAX_BODY) {
        throw new MemberSyncError('fetch failed: incomplete or too large body');
    }
    // Every Content-Length header (if any) must be digits only and equal to
    // the body length; a malformed value fails closed.
    preg_match_all('/^content-length:[ \t]*([^\r\n]*?)[ \t]*\r?$/im', substr($response, 0, $end), $lengths);
    foreach ($lengths[1] as $length) {
        if (!preg_match('/^[0-9]{1,18}$/D', $length) || (int) $length !== strlen($body)) {
            throw new MemberSyncError('fetch failed: body length does not match Content-Length');
        }
    }
    return $body;
}

// The member list of $body (a list of objects), or null unless it is a
// non-empty JSON list of objects, each with an "id" integer from 1 to
// 2147483647 and no "identification". A light check only: public.member_sync() validates the other
// fields (README, "Member sync").
function member_sync_parse($body)
{
    try {
        $members = json_decode($body, false, 4, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
    } catch (JsonException $e) {
        return null;
    }
    if (!is_array($members) || $members === []) {
        return null;
    }
    foreach ($members as $member) {
        if (!$member instanceof stdClass || !is_int($member->id ?? null) || $member->id < 1 || $member->id > 2147483647
            || property_exists($member, 'identification')) {
            return null;
        }
    }
    return $members;
}

// The pseudonym of the Admidio user id $id: 'mv:' and the lowercase hex
// HMAC-SHA256 of its decimal digits with $key (raw bytes).
function member_sync_pseudonym($key, $id)
{
    return 'mv:' . hash_hmac('sha256', (string) $id, $key);
}

// $members (of member_sync_parse()) as JSON for public.member_sync(), each
// "id" replaced by "identification", its pseudonym.
function member_sync_pseudonymise($members, $key)
{
    $entries = [];
    foreach ($members as $member) {
        $entry = get_object_vars($member);
        $entry['identification'] = member_sync_pseudonym($key, $entry['id']);
        unset($entry['id']);
        $entries[] = $entry;
    }
    return json_encode($entries, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}

// Applies $members (JSON) with public.member_sync() in one transaction
// (rolled back for a dry run; with $removals false the additions only, the
// removals counted as "would ...") and prints the summary after it (with
// $verbose, the change lines before it); throws (after
// the rollback, printing nothing) on any database error. A row lock not
// granted within $lockTimeout (e.g. held by a hung mail worker) is such an
// error.
function member_sync_apply($pdo, $members, $dryRun, $removals, $verbose, $lockTimeout = '60s')
{
    $pdo->beginTransaction();
    try {
        $pdo->exec("SET LOCAL lock_timeout = '$lockTimeout'");
        $statement = $pdo->prepare('SELECT * FROM public.member_sync(?, ?)');
        $statement->execute([$members, $removals ? 't' : 'f']);
        $counts = $statement->fetch(PDO::FETCH_ASSOC);
        if ($dryRun) {
            $pdo->rollBack();
        } else {
            $pdo->commit();
        }
    } catch (Throwable $e) {
        $pdo->rollBack();
        throw $e;
    }
    if ($verbose && $counts['changes'] !== '') {
        echo $counts['changes'] . "\n";
    }
    if ($removals) {
        $removed = "{$counts['locked']} locked, {$counts['deleted']} deleted, {$counts['anonymised']} anonymised";
        $revoked = "{$counts['privileges_revoked']} privileges revoked";
    } else {
        $removed = "would lock {$counts['locked']}, would delete {$counts['deleted']}, would anonymise {$counts['anonymised']}";
        $revoked = "would revoke {$counts['privileges_revoked']} privileges";
    }
    echo ($dryRun ? 'dry run: ' : '') . count(json_decode($members)) . ' members: '
        . "{$counts['created']} created, {$counts['unlocked']} unlocked, $removed, "
        . "{$counts['privileges_granted']} privileges granted, $revoked, "
        . "{$counts['email_updated']} emails updated, {$counts['no_email']} without email\n";
}

// The SQLSTATE of $e (for a failed connection, PDO's code is the driver's
// own; the message names the server, so it is not shown).
function member_sync_sqlstate($e)
{
    return $e->errorInfo[0] ?? $e->getCode();
}

// "database: <SQLSTATE>", for a rejected list (22023) or a lock (55P03)
// with the first line of the message, if it is member_sync()'s own (entry
// position and field, no data) or the lock timeout's (in English only).
function member_sync_database_error($e)
{
    $state = member_sync_sqlstate($e);
    // The severity prefix ("ERROR:  ") is in the server's message language.
    $message = preg_replace('/^[^\s:]+:\s+/u', '', (string) strtok((string) ($e->errorInfo[2] ?? ''), "\n"));
    if (in_array($state, ['22023', '55P03'], true)
        && preg_match('/^(member_sync: [ -~]*|canceling statement due to lock timeout)$/D', $message)) {
        return "database: $state ($message)";
    }
    return "database: $state";
}

// The run for the command line $argv and the environment $env; returns the
// exit status.
function member_sync_main($argv, $env)
{
    $dryRun = false;
    $verbose = false;
    $file = $env['MEMBER_SYNC_SECRETS'] ?? null;
    try {
        foreach (array_slice($argv, 1) as $arg) {
            if ($arg === '--dry-run') {
                $dryRun = true;
            } elseif ($arg === '--verbose') {
                $verbose = true;
            } elseif (str_starts_with($arg, '--secrets=')) {
                $file = substr($arg, strlen('--secrets='));
            } else {
                throw new MemberSyncError('usage: member-sync.php [--dry-run] [--verbose] [--secrets=<file>]');
            }
        }
        $secrets = member_sync_secrets($file);
        try {
            $pdo = new PDO($secrets['dsn'] ?? '', $secrets['user'] ?? null, null, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
            // Held until the process ends; public.member_sync() takes the
            // same key for its transaction.
            $locked = $pdo->query('SELECT pg_try_advisory_lock(' . MEMBER_SYNC_LOCK . ')')->fetchColumn();
        } catch (PDOException $e) {
            throw new MemberSyncError('database: ' . member_sync_sqlstate($e));
        }
        if ($locked !== true) {
            throw new MemberSyncError('another run is in progress');
        }
        $members = member_sync_parse(member_sync_fetch($secrets));
        if ($members === null) {
            throw new MemberSyncError('invalid document');
        }
        try {
            member_sync_apply($pdo, member_sync_pseudonymise($members, hex2bin($secrets['pseudonym_key'])), $dryRun,
                ($secrets['removals'] ?? 'off') === 'on', $verbose);
        } catch (PDOException $e) {
            throw new MemberSyncError(member_sync_database_error($e) . '; rolled back, nothing written');
        }
    } catch (MemberSyncError $e) {
        $message = $e->getMessage();
        fwrite(STDERR, 'member-sync: ' . $message . (str_ends_with($message, 'nothing written') ? '' : '; nothing written') . "\n");
        return 1;
    } catch (Throwable $e) {
        // Anything else (a bug, a bad secrets value): no details, which
        // could hold data.
        fwrite(STDERR, "member-sync: unexpected error; nothing written\n");
        return 1;
    }
    return 0;
}

if (PHP_SAPI === 'cli' && realpath($_SERVER['argv'][0] ?? '') === __FILE__) {
    exit(member_sync_main($_SERVER['argv'], getenv()));
}

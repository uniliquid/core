<?php

// Test only: helpers for tests/*-test.php. The database server (init.sh)
// has the roles lqfb (owner) and lqfb_membersync and the database
// liquid_feedback (core.sql and units 1-12, without member_sync.sql); each
// test works on copies of it. Synthetic data only.

const SOCKET = '/var/run/postgresql';
// The maps of the deployment (README, "Member sync").
const LO_MAP = '{"37": 2, "38": 6, "39": 4, "40": 10, "41": 5, "42": 7, "43": 3, "44": 8, "45": 9}';
const REGION_MAP = '{"AT130": 2, "AT221": 11}';
const MANAGED_UNITS = '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]';
// A made-up pseudonym key (secrets file, hex).
const PSEUDONYM_KEY = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

$failures = 0;

function check($name, $condition)
{
    global $failures;
    echo ($condition ? 'ok   ' : 'FAIL ') . $name . "\n";
    if (!$condition) {
        $failures++;
    }
}

// The exit status of the test file.
function done()
{
    global $failures;
    echo $failures === 0 ? "all passed\n" : "$failures failed\n";
    exit($failures === 0 ? 0 : 1);
}

function connect($db, $user = 'lqfb')
{
    return new PDO('pgsql:host=' . SOCKET . ";dbname=$db", $user, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_EMULATE_PREPARES => false,
    ]);
}

// Runs $command (an array, no shell); [exit status, stdout, stderr].
function run($command, $env = [])
{
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null,
        $env + ['PATH' => getenv('PATH'), 'PGHOST' => SOCKET]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    return [proc_close($process), $stdout, $stderr];
}

// Applies member_sync.sql to $db as lqfb with the deployment's command line
// (README, "Member sync"); [exit status, stdout, stderr]. A null map leaves
// its variable unset.
function apply_member_sync($db, $lo = LO_MAP, $regions = REGION_MAP, $managed = MANAGED_UNITS)
{
    $command = ['psql', '-X', '-v', 'ON_ERROR_STOP=1'];
    foreach (['lo_map' => $lo, 'region_map' => $regions, 'managed_units' => $managed] as $name => $value) {
        if ($value !== null) {
            array_push($command, '-v', "$name=$value");
        }
    }
    array_push($command, '-f', __DIR__ . '/../member_sync.sql', '-U', 'lqfb', '-d', $db);
    return run($command, ['PGOPTIONS' => '-c client_min_messages=warning']);
}

// A new database copied from $template (owner lqfb); returns its name.
function database($template = 'liquid_feedback')
{
    static $prefix = null, $count = 0;
    $prefix ??= 't' . bin2hex(random_bytes(4)) . '_';
    $name = $prefix . $count++;
    connect('postgres', 'postgres')->exec("CREATE DATABASE \"$name\" TEMPLATE \"$template\" OWNER lqfb");
    return $name;
}

// A new database with member_sync.sql applied (to a template made once).
function synced_database()
{
    static $template = null;
    if ($template === null) {
        $template = database();
        [$status, , $stderr] = apply_member_sync($template);
        if ($status !== 0) {
            fwrite(STDERR, "cannot apply member_sync.sql: $stderr");
            exit(1);
        }
    }
    return database($template);
}

// The pseudonym of the Admidio user id $id with PSEUDONYM_KEY, as
// member-sync.php computes it.
function mv($id)
{
    return 'mv:' . hash_hmac('sha256', (string) $id, hex2bin(PSEUDONYM_KEY));
}

// A member list entry as the Admidio side sends it.
function entry($id, $eligible = true, $lo = null, $regions = [], $email = 'default')
{
    return ['id' => $id, 'lo' => $lo, 'eligible' => $eligible,
        'email' => $email === 'default' ? "member$id@example.org" : $email, 'regions' => $regions];
}

// Runs public.member_sync($members) as lqfb_membersync in its own
// transaction (after the statement $setup, if any); the counts, or the
// SQLSTATE of the error. $members is encoded as JSON unless it is a string,
// with each "id" replaced by "identification" => mv(id) as member-sync.php
// does (unless the entry has an identification).
function sync($db, $members, $setup = null)
{
    if (!is_string($members)) {
        $members = array_map(function ($entry) {
            if (is_array($entry) && array_key_exists('id', $entry)) {
                $entry += ['identification' => mv($entry['id'])];
                unset($entry['id']);
            }
            return $entry;
        }, $members);
    }
    $pdo = connect($db, 'lqfb_membersync');
    if ($setup !== null) {
        $pdo->exec($setup);
    }
    try {
        $statement = $pdo->prepare('SELECT * FROM public.member_sync(?)');
        $statement->execute([is_string($members) ? $members : json_encode($members)]);
        return array_map('intval', $statement->fetch(PDO::FETCH_ASSOC));
    } catch (PDOException $e) {
        return $e->getCode();
    }
}

// The counts with $changes set and the others 0.
function counts($changes = [])
{
    return array_merge(['created' => 0, 'unlocked' => 0, 'locked' => 0, 'deleted' => 0, 'anonymised' => 0,
        'privileges_granted' => 0, 'privileges_revoked' => 0, 'email_updated' => 0, 'no_email' => 0], $changes);
}

// A digest of the tables the sync may write.
function state($pdo)
{
    $parts = [];
    foreach (['member', 'privilege', 'session', 'member_sync_mail', 'member_history'] as $table) {
        $parts[] = $pdo->query("SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), '')) FROM $table t")->fetchColumn();
    }
    return implode(',', $parts);
}

// Inserts a member row with $fields; returns its id.
function member($pdo, $fields)
{
    $statement = $pdo->prepare('INSERT INTO member (' . implode(', ', array_keys($fields)) . ') VALUES ('
        . implode(', ', array_fill(0, count($fields), '?')) . ') RETURNING id');
    $statement->execute(array_map(fn ($value) => is_bool($value) ? ($value ? 't' : 'f') : $value, array_values($fields)));
    return (int) $statement->fetchColumn();
}

// An activated, active member row with identification $identification.
function active_member($pdo, $identification, $fields = [])
{
    static $count = 0;
    $count++;
    return member($pdo, $fields + ['identification' => $identification, 'name' => "Name $count", 'login' => "login$count",
        'activated' => '2020-01-01', 'last_activity' => date('Y-m-d'), 'active' => true,
        'notify_email' => 'old' . $count . '@example.org']);
}

function row($pdo, $query, $params = [])
{
    $statement = $pdo->prepare($query);
    $statement->execute($params);
    return $statement->fetch(PDO::FETCH_ASSOC);
}

function column($pdo, $query, $params = [])
{
    $statement = $pdo->prepare($query);
    $statement->execute($params);
    return $statement->fetchAll(PDO::FETCH_COLUMN);
}

// The member's privileges as "unit:voting_right,initiative_right" strings.
function privileges($pdo, $memberId)
{
    return column($pdo, "SELECT unit_id || ':' || voting_right::int || initiative_right::int FROM privilege
        WHERE member_id = ? ORDER BY unit_id", [$memberId]);
}

// The units with both rights for the member.
function units($pdo, $memberId)
{
    return array_map('intval', column($pdo, 'SELECT unit_id FROM privilege WHERE member_id = ? AND voting_right
        AND initiative_right ORDER BY unit_id', [$memberId]));
}

// The queued mail kind of the member, or null.
function queued($pdo, $memberId)
{
    $kind = column($pdo, 'SELECT kind FROM member_sync_mail WHERE member_id = ?', [$memberId]);
    return $kind[0] ?? null;
}

function id_of($pdo, $identification)
{
    $id = column($pdo, 'SELECT id FROM member WHERE identification = ?', [$identification]);
    return isset($id[0]) ? (int) $id[0] : null;
}

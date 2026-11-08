<?php

// Tests of member_sync.sql (the apply, public.member_sync(), the mail queue
// views), run by tests/run.sh. Each case works on its own copy of the database. Synthetic
// data only.

require __DIR__ . '/lib.php';

// --- Apply -----------------------------------------------------------------

[$status, , $stderr] = apply_member_sync($db = database());
check('apply: the deployment command line succeeds', $status === 0 && $stderr === '');
$owner = connect($db);
check('apply: function, queue table and views exist', $owner->query("SELECT to_regprocedure('public.member_sync(jsonb)') IS NOT NULL
    AND to_regclass('public.member_sync_mail') IS NOT NULL AND to_regclass('public.member_sync_mail_due') IS NOT NULL
    AND to_regclass('public.member_sync_mail_stale') IS NOT NULL")->fetchColumn());
unset($owner);
[$status] = apply_member_sync($db);
check('apply: a second apply succeeds (idempotent)', $status === 0);

// The maps are baked in at apply time: a new apply with other maps changes them.
$db = synced_database();
check('apply: AT221 maps to unit 11', sync($db, [entry(1, true, null, ['AT221'])]) !== '' && units(connect($db), id_of(connect($db), mv(1))) === [1, 11]);
[$status] = apply_member_sync($db, LO_MAP, '{"AT130": 2, "AT221": 12}', '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]');
check('apply: changed maps applied', $status === 0);
check('apply: changed maps in effect (AT221 now unit 12, unit 11 removed)', sync($db, [entry(1, true, null, ['AT221'])])
    === counts(['privileges_granted' => 1, 'privileges_revoked' => 1]) && units(connect($db), id_of(connect($db), mv(1))) === [1, 12]);
[$status] = apply_member_sync($db, LO_MAP, '{"AT130": 2}', '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]');
check('apply: a region dropped from the map', $status === 0);
check('apply: a region dropped from the map is refused in the list', sync($db, [entry(1, true, null, ['AT221'])]) === '22023');
check('apply: unit of a dropped region cleaned up (still managed)', sync($db, [entry(1)]) === counts(['privileges_revoked' => 1])
    && units(connect($db), id_of(connect($db), mv(1))) === [1]);
[$status] = apply_member_sync($db);
connect($db)->exec("INSERT INTO privilege (unit_id, member_id) SELECT 12, id FROM member WHERE identification = '" . mv(1) . "'");
check('apply: a unit no longer managed is left alone', $status === 0 && sync($db, [entry(1)]) === counts()
    && units(connect($db), id_of(connect($db), mv(1))) === [1, 12]);

// Refused applies: psql stops, nothing changes (one transaction).
$db = synced_database();
$owner = connect($db);
$definition = $owner->query("SELECT pg_get_functiondef('public.member_sync_units()'::regprocedure)")->fetchColumn();
unset($owner);
$refused = [
    'lo_map unset' => [null, REGION_MAP, MANAGED_UNITS],
    'region_map unset' => [LO_MAP, null, MANAGED_UNITS],
    'managed_units unset' => [LO_MAP, REGION_MAP, null],
    'lo_map not JSON' => ['{37: 2}', REGION_MAP, MANAGED_UNITS],
    'lo_map not an object' => ['[2]', REGION_MAP, MANAGED_UNITS],
    'lo_map key not a role id' => ['{"x": 2}', REGION_MAP, MANAGED_UNITS],
    'lo_map key with a leading zero' => ['{"037": 2}', REGION_MAP, MANAGED_UNITS],
    'lo_map value not a number' => ['{"37": "2"}', REGION_MAP, MANAGED_UNITS],
    'lo_map value not an integer' => ['{"37": 2.5}', REGION_MAP, MANAGED_UNITS],
    'lo_map unit not managed' => ['{"37": 12}', REGION_MAP, MANAGED_UNITS],
    'lo_map unit 2.0' => ['{"37": 2.0}', REGION_MAP, MANAGED_UNITS],
    'region_map not an object' => [LO_MAP, '["AT130"]', MANAGED_UNITS],
    'region_map key not a NUTS-3 code' => [LO_MAP, '{"at130": 2}', MANAGED_UNITS],
    'region_map value not a number' => [LO_MAP, '{"AT130": null}', MANAGED_UNITS],
    'region_map unit not managed' => [LO_MAP, '{"AT130": 12}', MANAGED_UNITS],
    'region_map unit 2.0' => [LO_MAP, '{"AT130": 2.0}', MANAGED_UNITS],
    'managed_units not an array' => [LO_MAP, REGION_MAP, '{"1": 1}'],
    'managed_units empty' => ['{}', '{}', '[]'],
    'managed_units without unit 1' => ['{}', '{}', '[2]'],
    'managed_units not integers' => [LO_MAP, REGION_MAP, '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, "11"]'],
    'managed_units with a duplicate' => [LO_MAP, REGION_MAP, '[1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]'],
    'managed unit does not exist' => [LO_MAP, REGION_MAP, '[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13]'],
];
// A map value that would end a dollar-quoted body reaches the validation as data.
[$status, , $stderr] = apply_member_sync($db, '{"37": 2, "$b$; CREATE TABLE public.injected (); --": 2}');
$owner = connect($db);
check("apply refused: hostile lo_map key (validated as data, nothing injected)", $status !== 0 && str_contains($stderr, 'lo_map must map')
    && $owner->query("SELECT to_regclass('public.injected') IS NULL")->fetchColumn());
unset($owner);
$hostile = <<<'JSON'
{"AT130": 2, "x\\' $f$ $b$": 2}
JSON;
[$status, , $stderr] = apply_member_sync($db, LO_MAP, $hostile);
check("apply refused: hostile region_map key with quotes and backslash (validated as data)", $status !== 0 && str_contains($stderr, 'region_map must map'));
foreach ($refused as $name => [$lo, $regions, $managed]) {
    [$status] = apply_member_sync($db, $lo, $regions, $managed);
    $owner = connect($db);
    $same = $owner->query("SELECT pg_get_functiondef('public.member_sync_units()'::regprocedure)")->fetchColumn() === $definition;
    unset($owner);
    check("apply refused: $name (psql fails, the maps unchanged)", $status !== 0 && $same);
}

// The schema check: the applying role owns public, PUBLIC cannot create in it.
$db = database();
$admin = connect($db, 'postgres');
$admin->exec('GRANT CREATE ON SCHEMA public TO PUBLIC');
[$status, , $stderr] = apply_member_sync($db);
check('apply refused: PUBLIC may create in schema public', $status !== 0 && str_contains($stderr, 'CREATE')
    && $admin->query("SELECT to_regprocedure('public.member_sync(jsonb)') IS NULL")->fetchColumn());
$admin->exec('REVOKE CREATE ON SCHEMA public FROM PUBLIC');
$admin->exec('GRANT CREATE ON SCHEMA public TO lqfb_membersync');
[$status, , $stderr] = apply_member_sync($db);
check('apply refused: another role may create in schema public', $status !== 0 && str_contains($stderr, 'CREATE')
    && $admin->query("SELECT to_regprocedure('public.member_sync(jsonb)') IS NULL")->fetchColumn());
$admin->exec('REVOKE CREATE ON SCHEMA public FROM lqfb_membersync');
$admin->exec('ALTER SCHEMA public OWNER TO postgres');
[$status, , $stderr] = apply_member_sync($db);
check('apply refused: schema public owned by another role', $status !== 0 && str_contains($stderr, 'owned')
    && $admin->query("SELECT to_regprocedure('public.member_sync(jsonb)') IS NULL")->fetchColumn());
unset($admin);

// Privileges: lqfb_membersync may only execute public.member_sync().
$db = synced_database();
$owner = connect($db);
active_member($owner, mv(1));
$admin = connect($db, 'postgres');
$admin->exec('CREATE ROLE other_' . getmypid() . ' LOGIN');
$grants = $admin->query("SELECT
    has_function_privilege('lqfb_membersync', 'public.member_sync(jsonb)', 'EXECUTE'),
    has_function_privilege('lqfb_membersync', 'public.member_sync_units()', 'EXECUTE'),
    has_function_privilege('other_" . getmypid() . "', 'public.member_sync(jsonb)', 'EXECUTE'),
    (SELECT count(*) FROM information_schema.role_table_grants WHERE grantee IN ('lqfb_membersync', 'PUBLIC')
        AND table_schema = 'public'),
    (SELECT count(*) FROM information_schema.role_routine_grants WHERE grantee IN ('lqfb_membersync', 'PUBLIC')
        AND routine_schema = 'public' AND routine_name LIKE 'member_sync%')")->fetch(PDO::FETCH_NUM);
check('grants: lqfb_membersync may execute member_sync only', $grants[0] === true && $grants[1] === false
    && $grants[3] === 0 && $grants[4] === 1);
check('grants: other roles may not execute member_sync', $grants[2] === false);
$writer = connect($db, 'lqfb_membersync');
foreach ([
    'update member' => "UPDATE member SET locked = false",
    'delete from privilege' => 'DELETE FROM privilege',
    'insert into the queue' => "INSERT INTO member_sync_mail (member_id, kind) VALUES (1, 'invite')",
    'read the queue' => 'SELECT * FROM member_sync_mail_due',
    'read member' => 'SELECT notify_email FROM member',
    'call member_sync_units' => 'SELECT public.member_sync_units()',
    'call delete_member' => 'SELECT public.delete_member(1)',
] as $name => $query) {
    try {
        $writer->exec($query);
        $denied = false;
    } catch (PDOException $e) {
        $denied = $e->getCode() === '42501';
    }
    check("lqfb_membersync cannot $name", $denied);
}
unset($writer, $owner);
$admin->exec('DROP ROLE other_' . getmypid());
unset($admin);

// --- Input rejection: SQLSTATE 22023, nothing written ------------------------

$db = synced_database();
$owner = connect($db);
active_member($owner, mv(1), ['locked' => true]);
active_member($owner, mv(2));
$before = state($owner);
$long = str_repeat('a', 64) . '@' . str_repeat('b', 63) . '.' . str_repeat('c', 63) . '.' . str_repeat('d', 57) . '.org';
$rejected = [
    'null' => 'null',
    'an object' => '{"id": 1}',
    'empty list' => [],
    'an entry not an object' => [entry(1), 2],
    'a key missing' => [array_diff_key(entry(1), ['regions' => 0])],
    'an extra key' => [entry(1) + ['name' => 'x']],
    'an Admidio id instead of the identification' => ['[{"id": 1, "lo": null, "eligible": true, "email": null, "regions": []}]'],
    'identification a number' => [['identification' => 1] + entry(1)],
    'identification null' => [['identification' => null] + entry(1)],
    'identification mv:<id>' => [['identification' => 'mv:1'] + entry(1)],
    'identification upper case hex' => [['identification' => strtoupper(mv(1))] + entry(1)],
    'identification too short' => [['identification' => substr(mv(1), 0, -1)] + entry(1)],
    'identification with a line break' => [['identification' => mv(1) . "\n"] + entry(1)],
    'duplicate identification' => [entry(1), entry(1, false)],
    'eligible a string' => [['eligible' => 'true'] + entry(1)],
    'eligible null' => [['eligible' => null] + entry(1)],
    'eligible 1' => [['eligible' => 1] + entry(1)],
    'lo a string' => [entry(1, true, '38')],
    'lo not in the map' => [entry(1, true, 46)],
    'lo 38.0' => ['[{"identification": "' . mv(1) . '", "lo": 38.0, "eligible": true, "email": null, "regions": []}]'],
    'regions null' => [['regions' => null] + entry(1)],
    'regions a string' => [['regions' => 'AT130'] + entry(1)],
    'regions an object' => [['regions' => ['a' => 'AT130']] + entry(1)],
    'region not in the map' => [entry(1, true, null, ['AT999'])],
    'region not a string' => [entry(1, true, null, [130])],
    'duplicate region' => [entry(1, true, null, ['AT130', 'AT130'])],
    'email empty' => [entry(1, true, null, [], '')],
    'email without @' => [entry(1, true, null, [], 'member.example.org')],
    'email without a dot in the domain' => [entry(1, true, null, [], 'member@localhost')],
    'email with a space' => [entry(1, true, null, [], 'a b@example.org')],
    'email with a line break' => [entry(1, true, null, [], "a@example.org\nBcc: b@example.org")],
    'email with two @' => [entry(1, true, null, [], 'a@b@example.org')],
    'email with a trailing dot' => [entry(1, true, null, [], 'a.@example.org')],
    'email domain with a leading hyphen' => [entry(1, true, null, [], 'a@-example.org')],
    'email longer than 254' => [entry(1, true, null, [], $long . 'x')],
    'email a number' => [entry(1, true, null, [], 1)],
    // One bad entry rejects the whole list.
    'a bad entry after good ones' => [entry(2), entry(3), entry(4, 'yes')],
];
foreach ($rejected as $name => $members) {
    check("rejected: $name (22023, nothing written)", sync($db, is_array($members) && isset($members[0]) && is_string($members[0])
        ? $members[0] : $members) === '22023' && state($owner) === $before);
}
check('accepted: email of 254 characters', strlen($long) === 254 && is_array(sync($db, [entry(1, true, null, [], $long)])));
check("accepted: email with atext characters and dots", is_array(sync(synced_database(),
    [entry(1, true, null, [], "a.b+c_d!#\$%&'*/=?^`{|}~-1@sub-1.example.org")])));
check('accepted: lo null and regions empty', is_array(sync(synced_database(), [entry(1, true, null, [], null)])));

// --- Transitions ---------------------------------------------------------------

// Create.
$db = synced_database();
$owner = connect($db);
$result = sync($db, [entry(1, true, 38, ['AT130']), entry(2, true, null, [], null), entry(3, false)]);
check('create: counts (created, privileges, no email)', $result === counts(['created' => 1, 'privileges_granted' => 3, 'no_email' => 1]));
$new = row($owner, "SELECT * FROM member WHERE identification = ?", [mv(1)]);
check('create: row with mv:<pseudonym> and the email, unlocked, not active', $new !== false && $new['notify_email'] === 'member1@example.org'
    && $new['locked'] === false && $new['active'] === false && $new['activated'] === null && $new['invite_code'] === null);
check('create: units 1, LO and region', units($owner, $new['id']) === [1, 2, 6]);
check('create: invite queued', queued($owner, $new['id']) === 'invite');
check('create: no row without an email or when not eligible', id_of($owner, mv(2)) === null && id_of($owner, mv(3)) === null);
check('create: invite due', column($owner, 'SELECT kind FROM member_sync_mail_due WHERE member_id = ?', [$new['id']]) === ['invite']);
check('second identical run: no changes (no_email is a count, not a change)', sync($db, [entry(1, true, 38, ['AT130']),
    entry(2, true, null, [], null), entry(3, false)]) === counts(['no_email' => 1]));

// Units.
$db = synced_database();
$owner = connect($db);
sync($db, [entry(1, true, 37, ['AT130']), entry(2, true, 39, ['AT130']), entry(3, true, 38, ['AT221']),
    entry(4, true, 38, ['AT130', 'AT221'])]);
check('units: LO Wien + AT130 -> unit 2 once', units($owner, id_of($owner, mv(1))) === [1, 2]);
check('units: LO NOe + AT130 -> 4 and 2', units($owner, id_of($owner, mv(2))) === [1, 2, 4]);
check('units: AT221 -> 11', units($owner, id_of($owner, mv(3))) === [1, 6, 11]);
check('units: two regions -> both', units($owner, id_of($owner, mv(4))) === [1, 2, 6, 11]);
$result = sync($db, [entry(1, true, 37, []), entry(2, true, 41, ['AT130']), entry(3, true, null, ['AT221']), entry(4, true, 38, ['AT130'])]);
check('units: LO moved, region dropped, LO dropped (counts)', $result === counts(['privileges_granted' => 1, 'privileges_revoked' => 3]));
check('units: Wien without AT130 keeps unit 2 (LO)', units($owner, id_of($owner, mv(1))) === [1, 2]);
check('units: LO move 4 -> 5, region kept', units($owner, id_of($owner, mv(2))) === [1, 2, 5]);
check('units: LO null -> LO unit removed', units($owner, id_of($owner, mv(3))) === [1, 11]);
check('units: region dropped -> removed', units($owner, id_of($owner, mv(4))) === [1, 2, 6]);

// Unlock.
$db = synced_database();
$owner = connect($db);
$activeId = active_member($owner, mv(1), ['locked' => true, 'invite_code' => 'CODE1']);
$inactiveId = active_member($owner, mv(2), ['locked' => true, 'active' => false, 'notify_email' => 'member2@example.org']);
$neverId = member($owner, ['identification' => mv(3), 'locked' => true, 'notify_email' => 'member3@example.org']);
$codeId = member($owner, ['identification' => mv(4), 'locked' => true, 'notify_email' => 'member4@example.org', 'invite_code' => 'CODE4']);
$owner->exec("UPDATE member SET notify_email = 'member1@example.org' WHERE id = $activeId");
$result = sync($db, [entry(1), entry(2), entry(3), entry(4)]);
check('unlock: counts', $result === counts(['unlocked' => 4, 'privileges_granted' => 4]));
check('unlock: all unlocked', $owner->query('SELECT bool_and(NOT locked) FROM member')->fetchColumn() === true);
check('unlock: activated + active -> "unlocked" mail, invite_code unchanged', queued($owner, $activeId) === 'unlocked'
    && row($owner, 'SELECT invite_code FROM member WHERE id = ?', [$activeId])['invite_code'] === 'CODE1');
check('unlock: activated, not active -> no mail', queued($owner, $inactiveId) === null);
check('unlock: never activated, no invite code -> invite', queued($owner, $neverId) === 'invite');
check('unlock: never activated, with an invite code -> no mail', queued($owner, $codeId) === null);

// Lock.
$db = synced_database();
$owner = connect($db);
$id = active_member($owner, mv(1), ['notify_email' => 'member1@example.org']);
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $id), (6, $id)");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('s1', $id), ('s2', $id)");
$owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($id, 'unlocked')");
$result = sync($db, [entry(1, false, 38)]);
check('lock: counts', $result === counts(['locked' => 1, 'privileges_revoked' => 2]));
$locked = row($owner, 'SELECT * FROM member WHERE id = ?', [$id]);
check('lock: locked, sessions and privileges gone', $locked['locked'] === true && privileges($owner, $id) === []
    && (int) $owner->query("SELECT count(*) FROM session WHERE member_id = $id")->fetchColumn() === 0);
check('lock: profile and email kept', $locked['name'] !== null && $locked['notify_email'] === 'member1@example.org' && $locked['active'] === true);
check('lock: "locked" mail replaces the pending "unlocked" one (one row)', column($owner, 'SELECT kind FROM member_sync_mail') === ['locked']);
check('lock: "locked" mail due', column($owner, 'SELECT kind FROM member_sync_mail_due') === ['locked']);
check('lock: second run, no changes', sync($db, [entry(1, false, 38)]) === counts());

// Reconcile: an already-locked row with leftover sessions and rights.
$db = synced_database();
$owner = connect($db);
$id = active_member($owner, mv(1), ['locked' => true]);
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $id)");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('s1', $id)");
check('reconcile: already locked, leftovers removed (no lock counted)', sync($db, [entry(1, false)]) === counts(['privileges_revoked' => 1]));
check('reconcile: sessions and privileges gone, no mail', privileges($owner, $id) === [] && queued($owner, $id) === null
    && (int) $owner->query('SELECT count(*) FROM session')->fetchColumn() === 0);

// Mass lock of a well-formed list goes through (no threshold).
$db = synced_database();
$owner = connect($db);
$list = [];
for ($i = 1; $i <= 30; $i++) {
    active_member($owner, mv($i), ['notify_email' => "member$i@example.org"]);
    $list[] = entry($i, false);
}
check('mass lock: all 30 locked', sync($db, $list)['locked'] === 30);

// Email (R2).
$db = synced_database();
$owner = connect($db);
$inactiveId = active_member($owner, mv(1), ['active' => false, 'invite_code' => 'CODE1', 'notify_email_unconfirmed' => 'pending@example.org',
    'notify_email_secret' => 'SECRET1', 'notify_email_secret_expiry' => '2030-01-01',
    'password_reset_secret' => 'RESET1', 'password_reset_secret_expiry' => '2030-01-01']);
$activeId = active_member($owner, mv(2), ['notify_email_unconfirmed' => 'pending2@example.org', 'notify_email_secret' => 'SECRET2']);
$neverId = member($owner, ['identification' => mv(3), 'notify_email' => 'old3@example.org', 'invite_code' => 'CODE3',
    'password_reset_secret' => 'RESET3']);
$sameId = member($owner, ['identification' => mv(4), 'notify_email' => 'member4@example.org', 'notify_email_secret' => 'SECRET4']);
$ineligibleId = member($owner, ['identification' => mv(5), 'notify_email' => 'old5@example.org']);
$nullId = member($owner, ['identification' => mv(6), 'notify_email' => 'old6@example.org']);
$owner->exec('INSERT INTO privilege (unit_id, member_id) SELECT 1, id FROM member');
$result = sync($db, [entry(1), entry(2), entry(3), entry(4), entry(5, false), entry(6, true, null, [], null)]);
check('email: counts', $result === counts(['email_updated' => 2, 'locked' => 1, 'privileges_revoked' => 1]));
$inactive = row($owner, 'SELECT * FROM member WHERE id = ?', [$inactiveId]);
check('email: inactive activated -> overwritten, pending email and secrets cleared', $inactive['notify_email'] === 'member1@example.org'
    && $inactive['notify_email_unconfirmed'] === null && $inactive['notify_email_secret'] === null
    && $inactive['notify_email_secret_expiry'] === null && $inactive['password_reset_secret'] === null
    && $inactive['password_reset_secret_expiry'] === null);
check('email: inactive activated -> no invite, invite code unchanged', queued($owner, $inactiveId) === null && $inactive['invite_code'] === 'CODE1');
$active = row($owner, 'SELECT * FROM member WHERE id = ?', [$activeId]);
check('email: active -> unchanged', $active['notify_email'] !== 'member2@example.org' && $active['notify_email_unconfirmed'] === 'pending2@example.org'
    && $active['notify_email_secret'] === 'SECRET2');
$never = row($owner, 'SELECT * FROM member WHERE id = ?', [$neverId]);
check('email: never activated -> overwritten + invite, the old invite code revoked', $never['notify_email'] === 'member3@example.org'
    && $never['password_reset_secret'] === null && $never['invite_code'] === null && queued($owner, $neverId) === 'invite');
check('email: same address -> unchanged (secret kept)', row($owner, 'SELECT notify_email_secret FROM member WHERE id = ?', [$sameId])['notify_email_secret'] === 'SECRET4'
    && queued($owner, $sameId) === null);
check('email: not eligible -> unchanged', row($owner, 'SELECT notify_email FROM member WHERE id = ?', [$ineligibleId])['notify_email'] === 'old5@example.org');
check('email: null in the list -> unchanged', row($owner, 'SELECT notify_email FROM member WHERE id = ?', [$nullId])['notify_email'] === 'old6@example.org');

// One member without an email does not stop the others (the producer sends null for an invalid one).
$db = synced_database();
$owner = connect($db);
check('batch: an entry with email null, the others applied', sync($db, [entry(1), entry(2, true, null, [], null), entry(3)])
    === counts(['created' => 2, 'privileges_granted' => 2, 'no_email' => 1]));

// --- Leavers -------------------------------------------------------------------

// An issue in admission with one initiative and draft by $authorId; [issue, initiative, draft].
function issue_fixture($pdo, $authorId, $state = 'admission')
{
    $pdo->beginTransaction();
    $policy = $pdo->query("INSERT INTO policy (index, name, admission_time, discussion_time, verification_time, voting_time,
        issue_quorum_num, issue_quorum_den, initiative_quorum_num, initiative_quorum_den)
        VALUES (1, 'Policy ' || nextval('policy_id_seq'), '1 day', '1 day', '1 day', '1 day', 1, 100, 1, 100) RETURNING id")->fetchColumn();
    $area = $pdo->query("INSERT INTO area (unit_id, name) VALUES (1, 'Area') RETURNING id")->fetchColumn();
    $voting = $state === 'voting'
        ? ", 'voting', now() - interval '3 days', now() - interval '2 days', now() - interval '1 day', now() - interval '1 day', 'full_freeze'"
        : '';
    $issue = $pdo->query("INSERT INTO issue (area_id, policy_id, admission_time, discussion_time, verification_time, voting_time, created"
        . ($voting ? ', state, accepted, half_frozen, fully_frozen, snapshot, latest_snapshot_event' : '')
        . ") VALUES ($area, $policy, '1 day', '1 day', '1 day', '1 day', now() - interval '4 days'$voting) RETURNING id")->fetchColumn();
    $initiative = $pdo->query("INSERT INTO initiative (issue_id, name) VALUES ($issue, 'Initiative') RETURNING id")->fetchColumn();
    $draft = $pdo->query("INSERT INTO draft (initiative_id, author_id, content) VALUES ($initiative, $authorId, 'Text') RETURNING id")->fetchColumn();
    $pdo->exec("INSERT INTO initiator (initiative_id, member_id, accepted) VALUES ($initiative, $authorId, TRUE)");
    $pdo->commit();
    return [(int) $issue, (int) $initiative, (int) $draft];
}

$db = synced_database();
$owner = connect($db);
$authorId = active_member($owner, null);
[$issue, $initiative, $draft] = issue_fixture($owner, $authorId);
$plainId = active_member($owner, mv(1));
$neverId = member($owner, ['identification' => mv(2), 'notify_email' => 'member2@example.org']);
$coId = active_member($owner, mv(3), ['realname' => 'Real Name', 'statement' => 'Statement', 'invite_code' => 'CODE3',
    'admin_comment' => 'note']);
$trusteeId = active_member($owner, mv(4));
$supporterId = active_member($owner, mv(5));
$voterId = active_member($owner, mv(6));
$authorOnlyId = active_member($owner, mv(7));
$interestId = active_member($owner, mv(9));
$commenterId = active_member($owner, mv(10));
$owner->exec("INSERT INTO initiator (initiative_id, member_id) VALUES ($initiative, $coId)");
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $coId), (12, $coId)");
$owner->exec("INSERT INTO privilege (unit_id, member_id, polling_right) VALUES (2, $coId, TRUE)");
$owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($coId, 'locked')");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('s3', $coId)");
$owner->exec("INSERT INTO delegation (truster_id, trustee_id, scope, unit_id) VALUES ($authorId, $trusteeId, 'unit', 1)");
$owner->exec("INSERT INTO delegation (truster_id, trustee_id, scope, unit_id) VALUES ($trusteeId, $authorId, 'unit', 12)");
$owner->exec("INSERT INTO interest (issue_id, member_id) VALUES ($issue, $supporterId)");
$owner->exec("INSERT INTO supporter (issue_id, initiative_id, member_id, draft_id) VALUES ($issue, $initiative, $supporterId, $draft)");
$owner->exec("INSERT INTO direct_voter (issue_id, member_id) VALUES ($issue, $voterId)");
$owner->exec("INSERT INTO interest (issue_id, member_id) VALUES ($issue, $interestId)");
$owner->exec("INSERT INTO issue_comment (issue_id, member_id, content) VALUES ($issue, $commenterId, 'Comment')");
// A reference the pre-check does not list (a draft, ON DELETE RESTRICT): the
// DELETE fails, the member is anonymised.
$owner->exec("INSERT INTO draft (initiative_id, author_id, content) VALUES ($initiative, $authorOnlyId, 'Text 2')");
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $plainId)");
$stayId = active_member($owner, mv(8));
$result = sync($db, [entry(8)]);
check('leavers: counts', $result === counts(['deleted' => 2, 'anonymised' => 7, 'privileges_granted' => 1]));
check('leavers: unreferenced rows deleted', row($owner, 'SELECT count(*) AS n FROM member WHERE id IN (?, ?)', [$plainId, $neverId])['n'] === 0);
$anonymised = $owner->query("SELECT id, identification, admin_comment, locked, active, invite_code, realname, statement, login, notify_email
    FROM member WHERE id IN ($coId, $trusteeId, $supporterId, $voterId, $authorOnlyId, $interestId, $commenterId) ORDER BY id")->fetchAll(PDO::FETCH_ASSOC);
check('leavers: referenced rows anonymised (identification and invite code NULL, Austritt, locked, profile cleared)', count($anonymised) === 7
    && !array_filter($anonymised, fn ($m) => $m['identification'] !== null || $m['admin_comment'] !== 'Austritt' || $m['locked'] !== true
        || $m['active'] !== false || $m['invite_code'] !== null || $m['realname'] !== null || $m['statement'] !== null
        || $m['login'] !== null || $m['notify_email'] !== null));
check('leavers: anonymised rows have no privileges (also unmanaged and polling), queue row or session',
    (int) $owner->query("SELECT (SELECT count(*) FROM privilege WHERE member_id IN ($coId, $trusteeId, $supporterId, $voterId, $authorOnlyId, $interestId, $commenterId))
        + (SELECT count(*) FROM member_sync_mail) + (SELECT count(*) FROM session)")->fetchColumn() === 0);
check('leavers: co-initiator rows intact', (int) $owner->query("SELECT count(*) FROM initiator WHERE initiative_id = $initiative")->fetchColumn() === 2);
check('leavers: incoming delegation intact, outgoing removed', (int) $owner->query("SELECT count(*) FROM delegation WHERE trustee_id = $trusteeId")->fetchColumn() === 1
    && (int) $owner->query("SELECT count(*) FROM delegation WHERE truster_id = $trusteeId")->fetchColumn() === 0);
check('leavers: support and interest intact', (int) $owner->query("SELECT count(*) FROM supporter WHERE member_id = $supporterId")->fetchColumn() === 1
    && (int) $owner->query("SELECT count(*) FROM interest WHERE member_id = $interestId")->fetchColumn() === 1);
check('leavers: issue comment intact', (int) $owner->query("SELECT count(*) FROM issue_comment WHERE member_id = $commenterId")->fetchColumn() === 1);
check('leavers: name kept (as before)', $owner->query("SELECT name FROM member WHERE id = $coId")->fetchColumn() !== null);
check('leavers: the listed member stays', id_of($owner, mv(8)) === $stayId);
check('leavers: second run, no changes (anonymised rows are no longer owned)', sync($db, [entry(8)]) === counts());

// A deferred constraint trigger that fails after the DELETE (test only, on a
// table the DELETE cascades to and the anonymisation leaves alone) fails
// inside the sub-block (SET CONSTRAINTS ALL IMMEDIATE), not at COMMIT.
$db = synced_database();
$owner = connect($db);
$leaverId = active_member($owner, mv(1));
active_member($owner, mv(2));
$owner->exec("INSERT INTO member_history (member_id, active, name) VALUES ($leaverId, TRUE, 'Old name')");
$owner->exec("CREATE FUNCTION test_fail() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RAISE EXCEPTION 'deferred failure'; END \$\$");
$owner->exec('CREATE CONSTRAINT TRIGGER test_fail AFTER DELETE ON member_history DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION test_fail()');
check('deferred failure: anonymised, the run commits', sync($db, [entry(2)]) === counts(['anonymised' => 1, 'privileges_granted' => 1]));
check('deferred failure: the row stays, anonymised', $owner->query("SELECT admin_comment FROM member WHERE id = $leaverId")->fetchColumn() === 'Austritt');

// A lock timeout in the DELETE (a row it cascades to, and the anonymisation
// does not touch, locked by another session) fails the run instead of
// anonymising the member.
$db = synced_database();
$owner = connect($db);
$leaverId = active_member($owner, mv(1));
active_member($owner, mv(2));
$owner->exec("INSERT INTO member_history (member_id, active, name) VALUES ($leaverId, TRUE, 'Old name')");
$before = state($owner);
$holder = connect($db);
$holder->beginTransaction();
$holder->query("SELECT * FROM member_history WHERE member_id = $leaverId FOR UPDATE");
check('lock error in the DELETE: the run fails (55P03), nothing written', sync($db, [entry(2)], "SET lock_timeout = '1s'") === '55P03'
    && state($owner) === $before);
$holder->rollBack();
unset($holder);

// --- Admins --------------------------------------------------------------------

$db = synced_database();
$owner = connect($db);
$eligibleId = active_member($owner, mv(1), ['admin' => true]);
$ineligibleId = active_member($owner, mv(2), ['admin' => true]);
$leftId = active_member($owner, mv(3), ['admin' => true]);
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $ineligibleId), (1, $leftId), (12, $leftId)");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('a2', $ineligibleId), ('a3', $leftId)");
$result = sync($db, [entry(1, true, 38), entry(2, false)]);
check('admins: counts', $result === counts(['locked' => 2, 'privileges_granted' => 2, 'privileges_revoked' => 2]));
check('admins: eligible admin synced', units($owner, $eligibleId) === [1, 6]);
$admins = $owner->query("SELECT id, admin, locked, identification, admin_comment FROM member WHERE admin ORDER BY id")->fetchAll(PDO::FETCH_ASSOC);
check('admins: ineligible and departed admins locked, kept, admin flag unchanged', count($admins) === 3
    && $admins[1]['locked'] === true && $admins[2]['locked'] === true && $admins[2]['identification'] === mv(3)
    && $admins[2]['admin_comment'] === null && $admins[0]['locked'] === false);
check('admins: sessions deleted, managed privileges revoked, unmanaged kept', (int) $owner->query('SELECT count(*) FROM session')->fetchColumn() === 0
    && privileges($owner, $ineligibleId) === [] && privileges($owner, $leftId) === ['12:11']);
check('admins: "locked" mails', queued($owner, $ineligibleId) === 'locked' && queued($owner, $leftId) === 'locked');
check('admins: second run, no changes', sync($db, [entry(1, true, 38), entry(2, false)]) === counts());

// --- Privilege flags -------------------------------------------------------------

$db = synced_database();
$owner = connect($db);
$id = active_member($owner, mv(1));
$owner->exec("INSERT INTO privilege (unit_id, member_id, voting_right, initiative_right) VALUES (1, $id, FALSE, TRUE)");
$owner->exec("INSERT INTO privilege (unit_id, member_id, voting_right, initiative_right) VALUES (6, $id, TRUE, FALSE)");
$owner->exec("INSERT INTO privilege (unit_id, member_id, unit_manager) VALUES (3, $id, TRUE)");
$owner->exec("INSERT INTO privilege (unit_id, member_id, polling_right) VALUES (4, $id, TRUE)");
foreach (['admin_manager', 'area_manager', 'member_manager'] as $unit => $flag) {
    $owner->exec("INSERT INTO privilege (unit_id, member_id, $flag) VALUES (" . (7 + $unit) . ", $id, TRUE)");
}
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (5, $id), (12, $id)");
$result = sync($db, [entry(1, true, 38)]);
check('flags: counts', $result === counts(['privileges_granted' => 2, 'privileges_revoked' => 6]));
check('flags: voting_right/initiative_right false on a wanted unit -> true', units($owner, $id) === [1, 6, 12]);
check('flags: manager and polling rows kept with the owned flags cleared, a plain row deleted, unmanaged unit kept',
    privileges($owner, $id) === ['1:11', '3:00', '4:00', '6:11', '7:00', '8:00', '9:00', '12:11']);
$flags = row($owner, "SELECT unit_manager, polling_right FROM privilege p WHERE member_id = $id AND unit_id = 3");
check('flags: manager flags themselves unchanged', $flags['unit_manager'] === true
    && row($owner, "SELECT polling_right FROM privilege WHERE member_id = $id AND unit_id = 4")['polling_right'] === true);
check('flags: second run, no changes', sync($db, [entry(1, true, 38)]) === counts());
check('flags: lock keeps the manager rows, clears the flags', sync($db, [entry(1, false, 38)]) === counts(['locked' => 1, 'privileges_revoked' => 2])
    && privileges($owner, $id) === ['3:00', '4:00', '7:00', '8:00', '9:00', '12:11']);

// --- Never touched ---------------------------------------------------------------

$db = synced_database();
$owner = connect($db);
$foreign = [];
foreach ([null, '12345678', 'aGVsbG8gd29ybGQ=', 'mv:1', 'mv:' . str_repeat('g', 64), substr(mv(3), 0, -1), mv(3) . '0', mv(3) . ' ',
    'x' . mv(3), strtoupper(mv(3))] as $identification) {
    $foreign[] = active_member($owner, $identification, ['locked' => true, 'admin_comment' => 'Austritt']);
}
$owner->exec('INSERT INTO privilege (unit_id, member_id) SELECT 1, id FROM member');
$owner->exec("INSERT INTO session (ident, member_id) SELECT 'f' || id, id FROM member");
$digest = fn () => $owner->query('SELECT md5(string_agg(t::text, \'|\' ORDER BY t::text)) FROM member t WHERE id IN ('
    . implode(',', $foreign) . ')')->fetchColumn();
$before = $digest();
check('not owned: the run creates the row of id 1 only', sync($db, [entry(1), entry(2, false)]) === counts(['created' => 1, 'privileges_granted' => 1]));
check('not owned: rows without ^mv:[0-9a-f]{64}$ untouched (not deleted, unlocked or cleaned)', $digest() === $before
    && (int) $owner->query('SELECT count(*) FROM privilege WHERE member_id IN (' . implode(',', $foreign) . ')')->fetchColumn() === 10
    && (int) $owner->query('SELECT count(*) FROM session')->fetchColumn() === 10);
$db2 = synced_database();
$o2 = connect($db2);
$ids = [];
foreach (['mv:1', 'x' . mv(1), strtoupper(mv(1)), mv(1) . '0', 'mv:'] as $identification) {
    $ids[] = active_member($o2, $identification);
}
$before = $o2->query('SELECT md5(string_agg(t::text, \'|\' ORDER BY t::text)) FROM member t')->fetchColumn();
sync($db2, [entry(5)]);
check('not owned: unlisted foreign rows are not leavers', $o2->query('SELECT md5(string_agg(t::text, \'|\' ORDER BY t::text)) FROM member t WHERE id IN ('
    . implode(',', $ids) . ')')->fetchColumn() === $before);

// --- Mail queue ------------------------------------------------------------------

$db = synced_database();
$owner = connect($db);
$id = active_member($owner, mv(1), ['notify_email' => 'member1@example.org']);
sync($db, [entry(1, false)]);
// The "locked" mail is not sent (the worker failed); the member pays again.
sync($db, [entry(1)]);
check('queue: lock then unlock while unsent -> one row, "unlocked"', column($owner, 'SELECT member_id || kind FROM member_sync_mail') === ["{$id}unlocked"]);

$db = synced_database();
$owner = connect($db);
sync($db, [entry(1)]);
$id = id_of($owner, mv(1));
sync($db, [entry(1, false)]);
check('queue: a lock supersedes the unsent invite', queued($owner, $id) === 'locked');
sync($db, [entry(1)]);
check('queue: the unlock queues the invite again', queued($owner, $id) === 'invite');
// send_invitation() saves the code before it sends: a crash in between leaves the row due.
$owner->exec("UPDATE member SET invite_code = 'SAVED' WHERE id = $id");
check('queue: a saved code without a delivered mail stays due', column($owner, 'SELECT kind FROM member_sync_mail_due') === ['invite']);

// Due only while the state fits the kind; everything else is stale.
$db = synced_database();
$owner = connect($db);
$cases = [
    'invite, never activated, unlocked' => [['notify_email' => 'a@example.org'], 'invite', true],
    'invite, activated' => [['notify_email' => 'a@example.org', 'activated' => '2020-01-01', 'name' => 'N1'], 'invite', false],
    'invite, locked' => [['notify_email' => 'a@example.org', 'locked' => true], 'invite', false],
    'locked, locked' => [['notify_email' => 'a@example.org', 'locked' => true], 'locked', true],
    'locked, unlocked again' => [['notify_email' => 'a@example.org'], 'locked', false],
    'unlocked, unlocked' => [['notify_email' => 'a@example.org'], 'unlocked', true],
    'unlocked, locked again' => [['notify_email' => 'a@example.org', 'locked' => true], 'unlocked', false],
    'no email' => [[], 'unlocked', false],
    'not owned' => [['notify_email' => 'a@example.org', 'identification' => 'other'], 'unlocked', false],
];
$expected = [];
$n = 0;
foreach ($cases as $name => [$fields, $kind, $due]) {
    $n++;
    $memberId = member($owner, $fields + ['identification' => mv($n)]);
    $owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($memberId, '$kind')");
    $expected[$name] = [$memberId, $due];
}
$dueIds = array_map('intval', column($owner, 'SELECT member_id FROM member_sync_mail_due'));
$staleIds = array_map('intval', column($owner, 'SELECT member_id FROM member_sync_mail_stale'));
foreach ($expected as $name => [$memberId, $due]) {
    check("queue view: $name -> " . ($due ? 'due' : 'stale'), in_array($memberId, $due ? $dueIds : $staleIds, true)
        && !in_array($memberId, $due ? $staleIds : $dueIds, true));
}
check('queue view: due rows have the address and kind', array_keys(row($owner, 'SELECT * FROM member_sync_mail_due LIMIT 1'))
    === ['member_id', 'kind', 'created', 'notify_email']);

// --- Fail-fast ---------------------------------------------------------------------

$db = synced_database();
$owner = connect($db);
active_member($owner, mv(1));
$before = state($owner);
$holder = connect($db, 'postgres');
$key = (int) $owner->query("SELECT substring(prosrc FROM 'pg_try_advisory_xact_lock\\(([0-9]+)\\)') FROM pg_proc WHERE proname = 'member_sync'")->fetchColumn();
$holder->query("SELECT pg_advisory_lock($key)");
check('lock busy: 55P03, nothing written', $key > 0 && sync($db, [entry(2)]) === '55P03' && state($owner) === $before);
$holder->query("SELECT pg_advisory_unlock($key)");
check('lock free again: the run goes through', is_array(sync($db, [entry(1), entry(2)])));
unset($holder);

// --- Another key -------------------------------------------------------------------

$db = synced_database();
$owner = connect($db);
active_member($owner, mv(1));
active_member($owner, mv(2));
$before = state($owner);
$otherKey = fn ($id) => ['identification' => 'mv:' . hash_hmac('sha256', (string) $id, 'another key')] + entry($id);
check('another key: a list that matches no owned row is rejected (22023, nothing written)',
    sync($db, [$otherKey(1), $otherKey(2)]) === '22023' && state($owner) === $before);
check('another key: one match is enough', is_array(sync($db, [$otherKey(1), entry(2)])));

// --- Voting: what the lock means for ballots (core.sql, close_voting) -----------

foreach ([false => 'ballot dropped at close without the privilege', true => 'ballot counts when restored before the close'] as $restored => $name) {
    $db = synced_database();
    $owner = connect($db);
    $authorId = active_member($owner, null);
    $owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $authorId)");
    sync($db, [entry(1)]);
    $voterId = id_of($owner, mv(1));
    $owner->exec("UPDATE member SET activated = now(), last_activity = now(), active = TRUE, name = 'Voter' WHERE id = $voterId");
    [$issue, $initiative] = issue_fixture($owner, $authorId, 'voting');
    $owner->exec("INSERT INTO direct_voter (issue_id, member_id) VALUES ($issue, $voterId)");
    $owner->exec("INSERT INTO vote (issue_id, initiative_id, member_id, grade) VALUES ($issue, $initiative, $voterId, 1)");
    sync($db, [entry(1, false)]);
    if ($restored) {
        sync($db, [entry(1)]);
    }
    $owner->exec('BEGIN ISOLATION LEVEL REPEATABLE READ');
    $owner->exec("SELECT close_voting($issue)");
    $owner->exec('COMMIT');
    $voters = (int) $owner->query("SELECT count(*) FROM direct_voter WHERE issue_id = $issue AND member_id = $voterId")->fetchColumn();
    check("voting: $name", $voters === ($restored ? 1 : 0));
}

done();

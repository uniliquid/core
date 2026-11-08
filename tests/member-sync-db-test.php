<?php

// Tests of member_sync.sql (the apply, public.member_sync(), the mail queue
// views), run by tests/run.sh. Each case works on its own copy of the database. Synthetic
// data only.

require __DIR__ . '/lib.php';

// --- Apply -----------------------------------------------------------------

[$status, , $stderr] = apply_member_sync($db = database());
check('apply: the deployment command line succeeds', $status === 0 && $stderr === '');
$owner = connect($db);
check('apply: function, queue table and view exist', $owner->query("SELECT to_regprocedure('public.member_sync(jsonb)') IS NOT NULL
    AND to_regprocedure('public.member_sync(jsonb, boolean)') IS NULL
    AND to_regclass('public.member_sync_mail') IS NOT NULL AND to_regclass('public.member_sync_mail_due') IS NOT NULL")->fetchColumn());
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
// (the cleared row of unit 12 given its rights again by hand)
connect($db)->exec("UPDATE privilege SET voting_right = TRUE, initiative_right = TRUE WHERE unit_id = 12
    AND member_id = (SELECT id FROM member WHERE identification = '" . mv(1) . "')");
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
$changes = $GLOBALS['changes'];
check('create: counts (created, privileges, no email)', $result === counts(['created' => 1, 'privileges_granted' => 3, 'no_email' => 1]));
$new = row($owner, "SELECT * FROM member WHERE identification = ?", [mv(1)]);
check('create: change lines', $changes === ["member {$new['id']}: created", "member {$new['id']}: mail queued invite",
    "member {$new['id']}: privileges +3"]);
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
$activeId = active_member($owner, mv(1), ['locked' => true, 'invite_code' => 'CODE1',
    'password_reset_secret' => 'RESET1', 'password_reset_secret_expiry' => '2000-01-01']);
$inactiveId = active_member($owner, mv(2), ['locked' => true, 'active' => false, 'notify_email' => 'member2@example.org',
    'password_reset_secret' => 'RESET2', 'password_reset_secret_expiry' => '2100-01-01']);
$neverId = member($owner, ['identification' => mv(3), 'locked' => true, 'notify_email' => 'member3@example.org',
    'password_reset_secret' => 'RESET3']);
$codeId = member($owner, ['identification' => mv(4), 'locked' => true, 'notify_email' => 'member4@example.org', 'invite_code' => 'CODE4']);
$owner->exec("UPDATE member SET notify_email = 'member1@example.org' WHERE id = $activeId");
$result = sync($db, [entry(1), entry(2), entry(3), entry(4)]);
check('unlock: counts', $result === counts(['unlocked' => 4, 'privileges_granted' => 4]));
check('unlock: change lines', $GLOBALS['changes'] === ["member $activeId: unlocked", "member $inactiveId: unlocked",
    "member $neverId: unlocked", "member $codeId: unlocked", "member $activeId: mail queued unlocked", "member $inactiveId: mail queued unlocked",
    "member $neverId: mail queued invite",
    "member $activeId: privileges +1", "member $inactiveId: privileges +1", "member $neverId: privileges +1", "member $codeId: privileges +1"]);
check('unlock: all unlocked', $owner->query('SELECT bool_and(NOT locked) FROM member')->fetchColumn() === true);
check('unlock: activated + active -> "unlocked" mail, invite_code unchanged', queued($owner, $activeId) === 'unlocked'
    && row($owner, 'SELECT invite_code FROM member WHERE id = ?', [$activeId])['invite_code'] === 'CODE1');
check('unlock: activated, not active -> "unlocked" mail', queued($owner, $inactiveId) === 'unlocked');
check('unlock: never activated, no invite code -> invite', queued($owner, $neverId) === 'invite');
check('unlock: never activated, with an invite code -> no mail', queued($owner, $codeId) === null);
$reset = fn ($id) => array_values(row($owner, 'SELECT password_reset_secret, password_reset_secret_expiry FROM member WHERE id = ?', [$id]));
check('unlock: expired password reset cleared', $reset($activeId) === [null, null]);
check('unlock: password reset without expiry cleared', $reset($neverId) === [null, null]);
check('unlock: unexpired password reset kept', $reset($inactiveId) === ['RESET2', '2100-01-01 00:00:00+00']);

// Expired password resets: cleared on every run for owned rows.
$db = synced_database();
$owner = connect($db);
$expiredId = active_member($owner, mv(1), ['password_reset_secret' => 'RESET1', 'password_reset_secret_expiry' => '2000-01-01']);
$validId = active_member($owner, mv(2), ['password_reset_secret' => 'RESET2', 'password_reset_secret_expiry' => '2100-01-01']);
$otherId = active_member($owner, 'other', ['password_reset_secret' => 'RESET3', 'password_reset_secret_expiry' => '2000-01-01']);
sync($db, [entry(1), entry(2)]);
$reset = fn ($id) => array_values(row($owner, 'SELECT password_reset_secret, password_reset_secret_expiry FROM member WHERE id = ?', [$id]));
check('reset: expired cleared (not locked)', $reset($expiredId) === [null, null]);
check('reset: unexpired kept', $reset($validId) === ['RESET2', '2100-01-01 00:00:00+00']);
check('reset: not owned untouched', $reset($otherId) === ['RESET3', '2000-01-01 00:00:00+00']);

// Lock.
$db = synced_database();
$owner = connect($db);
$id = active_member($owner, mv(1), ['notify_email' => 'member1@example.org']);
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $id), (6, $id)");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('s1', $id), ('s2', $id)");
$owner->exec("INSERT INTO member_sync_mail (member_id, kind) VALUES ($id, 'unlocked')");
$result = sync($db, [entry(1, false, 38), entry(2)]);
check('lock: counts', $result === counts(['created' => 1, 'locked' => 1, 'privileges_granted' => 1, 'privileges_revoked' => 2]));
$newId = id_of($owner, mv(2));
check('lock: change lines', $GLOBALS['changes'] === ["member $newId: created", "member $newId: mail queued invite", "member $newId: privileges +1",
    "member $id: locked", "member $id: mail queued locked", "member $id: privileges -2"]);
$locked = row($owner, 'SELECT * FROM member WHERE id = ?', [$id]);
check('lock: locked, sessions gone, privilege rows kept with the flags cleared', $locked['locked'] === true
    && privileges($owner, $id) === ['1:00', '6:00']
    && (int) $owner->query("SELECT count(*) FROM session WHERE member_id = $id")->fetchColumn() === 0);
check('lock: profile and email kept', $locked['name'] !== null && $locked['notify_email'] === 'member1@example.org');
check('lock: deactivated (LQFB counts active members)', $locked['active'] === false);
check('lock: "locked" mail replaces the pending "unlocked" one (one row)', queued($owner, $id) === 'locked');
check('lock: "locked" mail due', column($owner, 'SELECT kind FROM member_sync_mail_due WHERE member_id = ?', [$id]) === ['locked']);
check('lock: second run, no changes', sync($db, [entry(1, false, 38), entry(2)]) === counts());

// Reconcile: an already-locked row with leftover sessions and rights.
$db = synced_database();
$owner = connect($db);
$id = active_member($owner, mv(1), ['locked' => true]);
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $id)");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('s1', $id)");
check('reconcile: already locked, leftovers removed (no lock counted)', sync($db, [entry(1, false)]) === counts(['privileges_revoked' => 1]));
check('reconcile: sessions gone, flags cleared, no mail', privileges($owner, $id) === ['1:00'] && queued($owner, $id) === null
    && (int) $owner->query('SELECT count(*) FROM session')->fetchColumn() === 0);
check('reconcile: already locked and active -> deactivated', row($owner, 'SELECT active FROM member WHERE id = ?', [$id])['active'] === false);
// Unlocked again: the cleared rows get their flags back (the grant upserts).
// (inactive since the lock, so the address is taken from the list too)
check('re-grant after unlock: counts', sync($db, [entry(1)]) === counts(['unlocked' => 1, 'privileges_granted' => 1, 'email_updated' => 1]));
check('re-grant after unlock: the same row with both flags', privileges($owner, $id) === ['1:11']);

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
check('email: change lines', $GLOBALS['changes'] === ["member $inactiveId: email updated", "member $neverId: email updated",
    "member $neverId: mail queued invite", "member $ineligibleId: locked", "member $ineligibleId: mail queued locked",
    "member $ineligibleId: privileges -1"]);
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

// Departed (not listed): locked like a listed non-eligible member, never
// deleted or anonymised, whatever references the row.
$db = synced_database();
$owner = connect($db);
$authorId = active_member($owner, null);
[$issue, $initiative, $draft] = issue_fixture($owner, $authorId);
$plainId = active_member($owner, mv(1), ['notify_email' => 'member1@example.org']);
$neverId = member($owner, ['identification' => mv(2), 'notify_email' => 'member2@example.org']);
$coId = active_member($owner, mv(3), ['realname' => 'Real Name']);
$trusteeId = active_member($owner, mv(4));
$owner->exec("INSERT INTO initiator (initiative_id, member_id) VALUES ($initiative, $coId)");
$owner->exec("INSERT INTO privilege (unit_id, member_id) VALUES (1, $coId), (12, $coId)");
$owner->exec("INSERT INTO privilege (unit_id, member_id, polling_right) VALUES (2, $coId, TRUE)");
$owner->exec("INSERT INTO session (ident, member_id) VALUES ('s3', $coId)");
$owner->exec("INSERT INTO delegation (truster_id, trustee_id, scope, unit_id) VALUES ($authorId, $trusteeId, 'unit', 1)");
$owner->exec("INSERT INTO delegation (truster_id, trustee_id, scope, unit_id) VALUES ($trusteeId, $authorId, 'unit', 12)");
$stayId = active_member($owner, mv(8));
$departed = [$plainId, $neverId, $coId, $trusteeId];
check('departed: counts', sync($db, [entry(8)]) === counts(['locked' => 4, 'privileges_granted' => 1, 'privileges_revoked' => 2]));
$rows = $owner->query('SELECT identification, locked, active, notify_email, realname, admin_comment FROM member WHERE id IN ('
    . implode(', ', $departed) . ') ORDER BY id')->fetchAll(PDO::FETCH_ASSOC);
check('departed: rows kept, locked, inactive, identification, email and profile unchanged', count($rows) === 4
    && !array_filter($rows, fn ($m) => !str_starts_with($m['identification'], 'mv:') || $m['locked'] !== true || $m['active'] !== false
        || $m['admin_comment'] !== null)
    && $rows[0]['notify_email'] === 'member1@example.org' && $rows[2]['realname'] === 'Real Name');
check('departed: managed flags cleared, rows kept (polling right too), unmanaged unit kept',
    privileges($owner, $coId) === ['1:00', '2:00', '12:11']);
check('departed: sessions ended', (int) $owner->query('SELECT count(*) FROM session')->fetchColumn() === 0);
check('departed: delegations and initiators intact', (int) $owner->query('SELECT count(*) FROM delegation')->fetchColumn() === 2
    && (int) $owner->query("SELECT count(*) FROM initiator WHERE initiative_id = $initiative")->fetchColumn() === 2);
check('departed: "locked" mails', array_map(fn ($id) => queued($owner, $id), $departed) === ['locked', 'locked', 'locked', 'locked']);
check('departed: second run, no changes', sync($db, [entry(8)]) === counts());

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
check('admins: sessions deleted, managed flags cleared, unmanaged kept', (int) $owner->query('SELECT count(*) FROM session')->fetchColumn() === 0
    && privileges($owner, $ineligibleId) === ['1:00'] && privileges($owner, $leftId) === ['1:00', '12:11']);
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
check('flags: change lines (one line)', $GLOBALS['changes'] === ["member $id: privileges +2", "member $id: privileges -6"]);
check('flags: voting_right/initiative_right false on a wanted unit -> true', units($owner, $id) === [1, 6, 12]);
check('flags: unwanted rows kept with the owned flags cleared (none deleted), unmanaged unit kept',
    privileges($owner, $id) === ['1:11', '3:00', '4:00', '5:00', '6:11', '7:00', '8:00', '9:00', '12:11']);
$flags = row($owner, "SELECT unit_manager, polling_right FROM privilege p WHERE member_id = $id AND unit_id = 3");
check('flags: manager flags themselves unchanged', $flags['unit_manager'] === true
    && row($owner, "SELECT polling_right FROM privilege WHERE member_id = $id AND unit_id = 4")['polling_right'] === true);
check('flags: second run, no changes', sync($db, [entry(1, true, 38)]) === counts() && $GLOBALS['changes'] === []);
check('flags: lock keeps the rows, clears the flags', sync($db, [entry(1, false, 38)]) === counts(['locked' => 1, 'privileges_revoked' => 2])
    && privileges($owner, $id) === ['1:00', '3:00', '4:00', '5:00', '6:00', '7:00', '8:00', '9:00', '12:11']);

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

// Due only while the state fits the kind (the worker deletes the others).
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
foreach ($expected as $name => [$memberId, $due]) {
    check("queue view: $name -> " . ($due ? 'due' : 'not due'), in_array($memberId, $dueIds, true) === $due);
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

// --- Not migrated --------------------------------------------------------------

// Old pseudonyms (base64, 44 characters) and no owned row: refused.
$oldPseudonym = fn ($id) => base64_encode(hash('sha256', "old $id", true));
$db = synced_database();
$owner = connect($db);
active_member($owner, $oldPseudonym(1));
$before = state($owner);
check('not migrated: old pseudonyms and no owned row are refused (22023, nothing written)',
    sync($db, [entry(1), entry(2)]) === '22023' && state($owner) === $before);
$owner->exec("UPDATE member SET admin_comment = 'Austritt'");
check('not migrated: old pseudonyms only on Austritt rows are accepted', is_array(sync($db, [entry(1)])));
$db = synced_database();
check('not migrated: a fresh database (no rows) is accepted', sync($db, [entry(1), entry(2)]) === counts(['created' => 2, 'privileges_granted' => 2]));
$owner = connect($db);
active_member($owner, $oldPseudonym(1));
check('not migrated: old pseudonyms next to owned rows are accepted', is_array(sync($db, [entry(1)])));

// --- Voting: what the lock means for ballots (core.sql, close_voting) -----------

// The lock also deactivates; close_voting counts active members only, so a
// restored ballot counts only after a login (login.lua sets active again).
foreach ([
    'ballot dropped at close without the privilege' => [false, false, 0],
    'ballot dropped when restored without a login' => [true, false, 0],
    'ballot counts when restored and logged in before the close' => [true, true, 1],
] as $name => [$restored, $login, $expected]) {
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
    if ($login) {
        $owner->exec("UPDATE member SET active = TRUE, last_activity = now() WHERE id = $voterId");
    }
    $owner->exec('BEGIN ISOLATION LEVEL REPEATABLE READ');
    $owner->exec("SELECT close_voting($issue)");
    $owner->exec('COMMIT');
    $voters = (int) $owner->query("SELECT count(*) FROM direct_voter WHERE issue_id = $issue AND member_id = $voterId")->fetchColumn();
    check("voting: $name", $voters === $expected);
}

done();

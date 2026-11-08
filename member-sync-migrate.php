<?php

// One-time migration to the member sync (README, "Member sync", migration),
// run by hand once, as the owner of the LiquidFeedback tables (peer
// authentication; the secrets file's user is not used), with both timers
// stopped and member_sync.sql applied:
//   php member-sync-migrate.php --expect=<n> --legacy-key-file=<file>
//     [--dry-run] [--secrets=<file>]
// Fetches the member list as member-sync.php does (same secrets file) and
// computes, for each listed Admidio user id, the pseudonym of the old sync
// (admidio-old adm_api/adm1.php: base64 of Rijndael-256-CBC of the id, key
// the ASCII md5 of the old key, IV the ASCII md5 of that, zero padding;
// checked by decrypting) and the new one ('mv:' and the HMAC, as
// member-sync.php). Then, in one transaction:
// - rows with an old pseudonym of the list, except those with admin_comment
//   'Austritt', get the new one; their number must be <n>, otherwise
//   nothing is written;
// - 'Austritt' rows that still hold an old pseudonym (44 base64 characters)
//   get identification NULL;
// - locked non-admin rows the sync does not own (all others, after the
//   step above) lose their sessions and their privileges in the managed
//   units.
// Prints the counts only (prefixed "dry run: " for --dry-run, which rolls
// back); exit status 0 on success, 1 (and a message on stderr) otherwise,
// nothing written then. The legacy key file holds the old key (one line).

require_once __DIR__ . '/member-sync.php';

// The S-box of Rijndael (index 0-255) and its inverse.
function legacy_boxes()
{
    static $boxes = null;
    if ($boxes === null) {
        $box = [0 => 0x63];
        $p = $q = 1;
        do {
            // $p times 3, $q divided by 3 in GF(2^8): $q is the inverse of $p.
            $p = ($p ^ ($p << 1) ^ ($p & 0x80 ? 0x11b : 0)) & 0xff;
            $q ^= $q << 1;
            $q ^= $q << 2;
            $q ^= $q << 4;
            $q &= 0xff;
            if ($q & 0x80) {
                $q ^= 0x09;
            }
            $box[$p] = ($q ^ ($q << 1 | $q >> 7) ^ ($q << 2 | $q >> 6) ^ ($q << 3 | $q >> 5) ^ ($q << 4 | $q >> 4) ^ 0x63) & 0xff;
        } while ($p !== 1);
        ksort($box);
        $boxes = [$box, array_flip($box)];
    }
    return $boxes;
}

// $a times $b in GF(2^8).
function legacy_mul($a, $b)
{
    $product = 0;
    for (; $b > 0; $b >>= 1) {
        if ($b & 1) {
            $product ^= $a;
        }
        $a = ($a << 1 ^ ($a & 0x80 ? 0x11b : 0)) & 0xff;
    }
    return $product;
}

// The 15 round keys (32 bytes each) of the 32-byte $key, block size 256.
function legacy_round_keys($key)
{
    [$box] = legacy_boxes();
    $w = array_values(unpack('C*', $key));
    $rcon = 1;
    for ($i = 8; $i < 120; $i++) {
        $t = array_slice($w, 4 * ($i - 1), 4);
        if ($i % 8 === 0) {
            $t = [$box[$t[1]] ^ $rcon, $box[$t[2]], $box[$t[3]], $box[$t[0]]];
            $rcon = legacy_mul($rcon, 2);
        } elseif ($i % 8 === 4) {
            $t = array_map(fn ($b) => $box[$b], $t);
        }
        for ($j = 0; $j < 4; $j++) {
            $w[] = $w[4 * ($i - 8) + $j] ^ $t[$j];
        }
    }
    return array_chunk($w, 32);
}

// One 32-byte block (bytes, column by column) encrypted, or decrypted if
// $decrypt, with Rijndael, block and key size 256 (14 rounds; rows shifted
// by 0, 1, 3, 4).
function legacy_block($state, $roundKeys, $decrypt)
{
    [$box, $inverse] = legacy_boxes();
    $shifts = [0, 1, 3, 4];
    $addKey = fn ($state, $round) => array_map(fn ($a, $b) => $a ^ $b, $state, $roundKeys[$round]);
    $shift = function ($state) use ($shifts, $decrypt) {
        $shifted = [];
        for ($c = 0; $c < 8; $c++) {
            for ($r = 0; $r < 4; $r++) {
                $from = 4 * (($c + ($decrypt ? 8 - $shifts[$r] : $shifts[$r])) % 8) + $r;
                $shifted[4 * $c + $r] = $state[$from];
            }
        }
        ksort($shifted);
        return $shifted;
    };
    $mix = function ($state) use ($decrypt) {
        $m = $decrypt ? [14, 11, 13, 9] : [2, 3, 1, 1];
        $mixed = [];
        for ($c = 0; $c < 32; $c += 4) {
            for ($r = 0; $r < 4; $r++) {
                $mixed[$c + $r] = legacy_mul($state[$c + $r], $m[0]) ^ legacy_mul($state[$c + ($r + 1) % 4], $m[1])
                    ^ legacy_mul($state[$c + ($r + 2) % 4], $m[2]) ^ legacy_mul($state[$c + ($r + 3) % 4], $m[3]);
            }
        }
        return $mixed;
    };
    if (!$decrypt) {
        $state = $addKey($state, 0);
        for ($round = 1; $round <= 14; $round++) {
            $state = $shift(array_map(fn ($b) => $box[$b], $state));
            if ($round < 14) {
                $state = $mix($state);
            }
            $state = $addKey($state, $round);
        }
        return $state;
    }
    $state = $addKey($state, 14);
    for ($round = 13; $round >= 0; $round--) {
        $state = $addKey(array_map(fn ($b) => $inverse[$b], $shift($state)), $round);
        if ($round > 0) {
            $state = $mix($state);
        }
    }
    return $state;
}

// mcrypt_encrypt(MCRYPT_RIJNDAEL_256, md5($key), $data, MCRYPT_MODE_CBC,
// md5(md5($key))) (zero padding), or mcrypt_decrypt() if $decrypt.
function legacy_cbc($key, $data, $decrypt)
{
    $roundKeys = legacy_round_keys(md5($key));
    $previous = array_values(unpack('C*', md5(md5($key))));
    if (strlen($data) % 32 !== 0) {
        $data .= str_repeat("\0", 32 - strlen($data) % 32);
    }
    $out = '';
    foreach (str_split($data, 32) as $block) {
        $bytes = array_values(unpack('C*', $block));
        if ($decrypt) {
            $plain = array_map(fn ($a, $b) => $a ^ $b, legacy_block($bytes, $roundKeys, true), $previous);
            $previous = $bytes;
            $out .= pack('C*', ...$plain);
        } else {
            $previous = legacy_block(array_map(fn ($a, $b) => $a ^ $b, $bytes, $previous), $roundKeys, false);
            $out .= pack('C*', ...$previous);
        }
    }
    return $out;
}

// The old sync's pseudonym of the Admidio user id $id (adm1.php:23).
function legacy_pseudonym($key, $id)
{
    return base64_encode(legacy_cbc($key, (string) $id, false));
}

// The id in the old pseudonym $pseudonym (as admidio-old adm_api/usr.php).
function legacy_id($key, $pseudonym)
{
    return rtrim(legacy_cbc($key, (string) base64_decode($pseudonym, true), true), "\0");
}

// The migration of $members (of member_sync_parse()) in one transaction
// (rolled back for a dry run); returns the summary line. Throws
// MemberSyncError (or PDOException) and rolls back if the number of matched
// rows is not $expect.
function member_sync_migrate($pdo, $members, $legacyKey, $pseudonymKey, $expect, $dryRun)
{
    $pairs = [];
    foreach ($members as $member) {
        $old = legacy_pseudonym($legacyKey, $member->id);
        if (legacy_id($legacyKey, $old) !== (string) $member->id) {
            throw new MemberSyncError('the old pseudonym does not decrypt to its id');
        }
        $pairs[$old] = member_sync_pseudonym($pseudonymKey, $member->id);
    }
    $pdo->beginTransaction();
    try {
        if ($pdo->query('SELECT pg_try_advisory_xact_lock(' . MEMBER_SYNC_LOCK . ')')->fetchColumn() !== true) {
            throw new MemberSyncError('the sync is running');
        }
        $statement = $pdo->prepare("UPDATE public.member SET identification = pair.value
            FROM jsonb_each_text(?::jsonb) AS pair
            WHERE member.identification = pair.key AND member.admin_comment IS DISTINCT FROM 'Austritt'");
        $statement->execute([json_encode($pairs, JSON_THROW_ON_ERROR)]);
        $matched = $statement->rowCount();
        if ($matched !== $expect) {
            throw new MemberSyncError("$matched rows match, expected $expect");
        }
        $cleared = $pdo->exec("UPDATE public.member SET identification = NULL
            WHERE admin_comment = 'Austritt' AND identification ~ '^[A-Za-z0-9+/]{43}=$'");
        $unowned = 'member.locked AND NOT member.admin AND public.member_sync_owned(member.identification) IS NOT TRUE';
        $sessions = $pdo->exec("DELETE FROM public.session USING public.member
            WHERE session.member_id = member.id AND $unowned");
        $privileges = $pdo->exec("DELETE FROM public.privilege USING public.member
            WHERE privilege.member_id = member.id AND $unowned
            AND privilege.unit_id IN (SELECT jsonb_array_elements_text(public.member_sync_units()->'managed')::int4)");
        if ($dryRun) {
            $pdo->rollBack();
        } else {
            $pdo->commit();
        }
    } catch (Throwable $e) {
        $pdo->rollBack();
        throw $e;
    }
    return ($dryRun ? 'dry run: ' : '') . count($members) . " members: $matched rows migrated, "
        . (count($members) - $matched) . " without a row, $cleared 'Austritt' rows cleared, "
        . "$sessions sessions and $privileges privileges of other locked rows deleted\n";
}

// The run for the command line $argv and the environment $env; returns the
// exit status.
function member_sync_migrate_main($argv, $env)
{
    $dryRun = false;
    $file = $env['MEMBER_SYNC_SECRETS'] ?? null;
    $expect = null;
    $legacyKeyFile = null;
    try {
        foreach (array_slice($argv, 1) as $arg) {
            if ($arg === '--dry-run') {
                $dryRun = true;
            } elseif (str_starts_with($arg, '--secrets=')) {
                $file = substr($arg, strlen('--secrets='));
            } elseif (preg_match('/^--expect=([0-9]{1,9})$/D', $arg, $match)) {
                $expect = (int) $match[1];
            } elseif (str_starts_with($arg, '--legacy-key-file=')) {
                $legacyKeyFile = substr($arg, strlen('--legacy-key-file='));
            } else {
                $expect = null;
                break;
            }
        }
        if ($expect === null || $legacyKeyFile === null) {
            throw new MemberSyncError('usage: member-sync-migrate.php --expect=<n> --legacy-key-file=<file> [--dry-run] [--secrets=<file>]');
        }
        $legacyKey = is_file($legacyKeyFile) ? rtrim((string) file_get_contents($legacyKeyFile), "\r\n") : '';
        if ($legacyKey === '') {
            throw new MemberSyncError('no legacy key');
        }
        $secrets = member_sync_secrets($file);
        try {
            // The OS user's role (peer authentication): the owner of the tables.
            $pdo = new PDO($secrets['dsn'] ?? '', null, null, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
        } catch (PDOException $e) {
            throw new MemberSyncError('database: ' . member_sync_sqlstate($e));
        }
        $members = member_sync_parse(member_sync_fetch($secrets));
        if ($members === null) {
            throw new MemberSyncError('invalid document');
        }
        try {
            echo member_sync_migrate($pdo, $members, $legacyKey, hex2bin($secrets['pseudonym_key']), $expect, $dryRun);
        } catch (PDOException $e) {
            throw new MemberSyncError('database: ' . member_sync_sqlstate($e));
        }
    } catch (MemberSyncError $e) {
        fwrite(STDERR, 'member-sync-migrate: ' . $e->getMessage() . "; nothing written\n");
        return 1;
    }
    return 0;
}

if (PHP_SAPI === 'cli' && realpath($_SERVER['argv'][0] ?? '') === __FILE__) {
    exit(member_sync_migrate_main($_SERVER['argv'], getenv()));
}

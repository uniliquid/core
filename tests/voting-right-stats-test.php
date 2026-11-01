<?php

// Tests of lf_voting_right_stats, run by tests/run.sh: the script runs
// against a copy of the database (LF_DATABASE) and a statistics directory
// made here (LF_STATISTICS_DIR). Synthetic data only.

require __DIR__ . '/lib.php';

$dir = sys_get_temp_dir() . '/voting-right-stats-' . getmypid();
mkdir($dir);
// The existing pages: one older line each.
for ($unit = 1; $unit <= 20; $unit++) {
    file_put_contents("$dir/$unit.html", "older line\n");
}
$db = database();
$owner = connect($db);

// Runs the script; [exit status, stdout, stderr].
function stats()
{
    global $db, $dir;
    return run(['sh', __DIR__ . '/../lf_voting_right_stats'], ['LF_DATABASE' => $db, 'LF_STATISTICS_DIR' => $dir, 'PGUSER' => 'lqfb']);
}

function lines($unit)
{
    global $dir;
    return file("$dir/$unit.html", FILE_IGNORE_NEW_LINES);
}

// The line the script writes, without its time stamp.
function stats_line($n, $active, $quorum)
{
    return "<b>$n</b> stimmberechtigt, <b>$active</b> aktiv (Stimmabgabe-Quorum, aufgerundet: x^0.6=<b>$quorum</b> Stimmen)<br />";
}

// The database cannot be read: exit 1, nothing written (no line from an empty count).
$state = fn () => implode('', array_map(fn ($unit) => file_get_contents("$dir/$unit.html"), range(1, 20)));
$files = $state();
[$status, $stdout, $stderr] = run(['sh', __DIR__ . '/../lf_voting_right_stats'],
    ['LF_DATABASE' => 'missing_database', 'LF_STATISTICS_DIR' => $dir, 'PGUSER' => 'lqfb']);
check('database not readable: exit status not 0, nothing written or printed', $status !== 0 && $stdout === '' && $stderr !== ''
    && $state() === $files);

// A count that is not a number (here from a stand-in psql): exit 1, nothing written.
mkdir("$dir-bin");
file_put_contents("$dir-bin/psql", "#!/bin/sh\necho 'not a number'\n");
chmod("$dir-bin/psql", 0755);
[$status, $stdout, $stderr] = run(['sh', __DIR__ . '/../lf_voting_right_stats'],
    ['LF_DATABASE' => $db, 'LF_STATISTICS_DIR' => $dir, 'PATH' => "$dir-bin:" . getenv('PATH')]);
check('count not a number: exit 1, "error3!" on stderr, nothing written', $status === 1 && $stdout === ''
    && $stderr === "error3! unit 1: no count\n" && $state() === $files);

// Unit 1 without voters: error3, nothing written.
[$status, $stdout] = stats();
check('no voters in unit 1: "error3! 0", exit 0, nothing written', $status === 0 && $stdout === "error3! 0\n" && lines(1) === ['older line']);

// Unit 1: 10 voters (7 active), 1 locked, 1 without the voting right; unit 2: 1 voter.
for ($i = 1; $i <= 12; $i++) {
    $id = $i <= 7 ? active_member($owner, "mv:$i") : member($owner, ['identification' => "mv:$i", 'locked' => $i === 11]);
    $owner->exec("INSERT INTO privilege (unit_id, member_id, voting_right) VALUES (1, $id, " . ($i === 12 ? 'FALSE' : 'TRUE') . ')');
}
$owner->exec("INSERT INTO privilege (unit_id, member_id) SELECT 2, id FROM member WHERE identification = 'mv:1'");
[$status, $stdout, $stderr] = stats();
$date = '/^[A-Z][a-z]{2}, \d{1,2}\. \d{1,2}\. \d{4}, \d{2}:\d{2}:\d{2} CEST: /';
$first = lines(1)[0];
check('count from Liquid: voting right and not locked; quorum ceil(10^0.6) = 4', $status === 0
    && preg_match($date, $first) === 1 && preg_replace($date, '', $first) === stats_line(10, 7, 4) && lines(1)[1] === 'older line');
check('unit 2: 1 voter, quorum 1', preg_replace($date, '', lines(2)[0]) === stats_line(1, 1, 1));
check('units without voters: 0, quorum 0', preg_replace($date, '', lines(3)[0]) === stats_line(0, 0, 0) && count(lines(20)) === 2);
check('stdout: the new lines', count(explode("\n", trim($stdout))) === 20 && str_ends_with(explode("\n", $stdout)[0], stats_line(10, 7, 4)));

// Unchanged: no new line.
[$status, $stdout] = stats();
check('unchanged: no new line, nothing printed', $status === 0 && $stdout === '' && count(lines(1)) === 2 && count(lines(3)) === 2);

// A change in one unit: a new line there only.
$owner->exec("UPDATE member SET locked = TRUE WHERE identification = 'mv:10'");
[$status, $stdout] = stats();
check('changed: a new line in unit 1 only (9 voters, quorum ceil(9^0.6) = 4)', $status === 0 && count(lines(1)) === 3
    && preg_replace($date, '', lines(1)[0]) === stats_line(9, 7, 4) && count(lines(2)) === 2 && count(explode("\n", trim($stdout))) === 1);

done();

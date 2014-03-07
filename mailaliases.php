<?
require("constants.php");
echo 'postmaster: lqfbsupport@piratenpartei.at
webmaster: lqfbsupport@piratenpartei.at
root: lqfbsupport@piratenpartei.at
support: lqfbsupport@piratenpartei.at
lqfbsupport: lqfbsupport@piratenpartei.at
';
$dbconn = pg_connect("dbname=liquid_feedback") or die('Verbindungsaufbau fehlgeschlagen: ' . pg_last_error());
$query = "SELECT name,notify_email FROM member WHERE name NOTNULL AND notify_email NOTNULL AND name != '' AND notify_email != ''";
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
while ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
  if (preg_match('/^[^0-9][a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)*$/', $line['name']) && preg_match('/^[^0-9][a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)*[@][a-zA-Z0-9_-]+([.][a-zA-Z0-9_-]+)*[.][a-zA-Z]{2,4}$/', $line['notify_email']) && !preg_match('/^.*@liquid.piratenpartei.at$/', $line['notify_email']))
  {
    echo $line['name'] . ": " . $line['notify_email'] . "\n";
  }
}
pg_free_result($result);
pg_close($dbconn);
?>


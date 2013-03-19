<?
require("constants.php");

$dbconn = pg_connect("dbname=liquid_feedback")
  or die('Verbindungsaufbau fehlgeschlagen: ' . pg_last_error());

$query = "SELECT id,notify_email FROM member WHERE activated NOTNULL AND NOT locked AND last_activity NOTNULL AND last_activity < (NOW() - '6 months'::interval)::DATE AND active;";
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
while ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
  $lqfb_id = intval($line["id"]);

  $query2 = "SELECT id,notify_email FROM member WHERE id IN (SELECT trustee_id FROM delegation WHERE truster_id = $lqfb_id) AND NOT locked AND active;";
  $result2 = pg_query($query2) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  while ($line2 = pg_fetch_array($result2, null, PGSQL_ASSOC)) {
    $lqfb_id2 = $line2["id"];

    echo "send trustee delegation warning to $lqfb_id2\n";
    $notify_email2 = $line2["notify_email"];
    exec("./sendinfo_delegation_other.sh $notify_email2 $lqfb_id");
  }
  pg_free_result($result2);


  echo "send truster delegation warning to $lqfb_id\n";
  $notify_email = $line["notify_email"];
  exec("./sendinfo_delegation_self.sh $notify_email");
}
pg_free_result($result);

pg_close($dbconn);


?>


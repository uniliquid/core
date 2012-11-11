<?
require("constants.php");
$sData = file_get_contents("http://mitglieder.piratenpartei.at/adm_api/adm1.php");
if (strlen($datakey1) == 0 || strlen($datakey2) == 0)
  die('Kein Passwort!');

if (strlen($sData) < 100)
  die('Daten von Mitgliederverwaltung zu kurz!');

$dbconn = pg_connect("dbname=liquid_feedback")
  or die('Verbindungsaufbau fehlgeschlagen: ' . pg_last_error());

$query = 'DROP TABLE IF EXISTS member_update_copy';
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);

$query = 'CREATE TABLE member_update_copy AS SELECT * FROM member';
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);

function updateUnits($lqfb_id, $lo_num, $akk)
{
  if ($akk == false && $lo_num == 4)
  {
    //$lo_num = 0;
  }
  // ======================= set units =========================
  // --------> pirate party austria
  $query = "SELECT * FROM privilege WHERE member_id = '$lqfb_id' AND unit_id = 1;";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    //print_r($line);
  }
  else
  {
    $query = "INSERT INTO privilege (unit_id, member_id) VALUES (1, $lqfb_id);";
    echo $query . "\n";
    $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result2);
  }
  pg_free_result($result);
  // ---------> suborganisation
  // remove from old suborganisation if exists
  $query = "SELECT * FROM privilege WHERE member_id = '$lqfb_id' AND unit_id != 1 AND unit_id != $lo_num;";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    $query = "DELETE FROM privilege WHERE member_id = '$lqfb_id' AND unit_id != 1;";
    echo $query . "\n";
    $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result2);
  }
  pg_free_result($result);
  if ($lo_num != 0)
  {
    // check whether already in the right suborganisation
    $query = "SELECT * FROM privilege WHERE member_id = '$lqfb_id' AND unit_id = $lo_num;";
    $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
      //print_r($line);
    }
    else
    {
      // insert into suborganisation
      $query = "INSERT INTO privilege (unit_id, member_id) VALUES ($lo_num, $lqfb_id);";
      echo $query . "\n";
      $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
      pg_free_result($result2);
    }
    pg_free_result($result);
  }
}

$decrypted = rtrim(mcrypt_decrypt(MCRYPT_RIJNDAEL_256, md5($datakey2), base64_decode($sData), MCRYPT_MODE_CBC, md5(md5($datakey2))), "\0");
$lines = explode("\n",$decrypted);
foreach ($lines as $line)
{
  if (strlen($line) < 5) { continue; }
  $values = explode("\t",$line);
  $idc = stripslashes($values[1]);
  if (strlen($values[1]) < 5) { echo "FATAL: idc not valid:\n"; /*print_r($values);*/ continue; }
  $mail_original = stripslashes(trim($values[2]));
  $mail = filter_var($mail_original, FILTER_SANITIZE_EMAIL);
  if (!filter_var($mail, FILTER_VALIDATE_EMAIL)/* || $mail == "mitglied@piratenpartei.at"*/) { /*echo "FATAL: email address invalid: '$mail':\n"; print_r($values);*/ continue; }
  $lo = $values[3];
  $akk = ($values[4] != null);
  if (!$akk)
    continue;
  switch ($lo)
  {
    case 38: $lo_num = 6; break;
    case 40: $lo_num = 10; break;
    case 39: $lo_num = 4; break;
    case 41: $lo_num = 5; break;
    case 42: $lo_num = 7; break;
    case 43: $lo_num = 3; break;
    case 44: $lo_num = 8; break;
    case 45: $lo_num = 9; break;
    case 37: $lo_num = 2; break;
    default: $lo_num = 0; break;
  }
  //echo "insert: identification=$idc, email=$mail, lo=$lo_num, akk=$akk\n";
  $query = "SELECT id,notify_email FROM member WHERE identification='$idc'";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    $lqfb_id = $line["id"];
    pg_free_result($result);

    // unlock user according to admidio data
    $query = "SELECT active,notify_email FROM member WHERE identification='$idc' AND locked = true;";
    $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
      $active = $line["active"];
      $query = "UPDATE member SET locked = false WHERE identification='$idc'";
      echo $query . "\n";
      $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
      pg_free_result($result2);
      if ($active)
      {
        echo "sent info unlocked to $lqfb_id\n";
        $notify_email = $line["notify_email"];
        exec("./sendinfo_unlocked.sh $notify_email");
      }
    }
    pg_free_result($result);

    // remove member from the table copy (so we dont lock it later!)
    $query = "DELETE FROM member_update_copy WHERE identification='$idc'";
    $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result);

    // use caution! this resets ALL accounts!
    // $query = "UPDATE member SET active = false,activated = null,last_activity = null,password = null,notify_email = '$mail' WHERE identification='$idc'";
    // echo $query . "\n";
    // $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    // pg_free_result($result);

    // update mail address if user not active but mail address changed
    $query = "SELECT notify_email,locked FROM member WHERE identification='$idc' AND active = FALSE";
    $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
      pg_free_result($result);
      $lqfb_mail = $line["notify_email"];
      if ($mail != $lqfb_mail || $line["locked"] == 't')
      {
        $query = "UPDATE member SET notify_email = '$mail',locked = false WHERE identification='$idc'";
        echo $query . "\n";
        $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
        pg_free_result($result);

        //echo "replacing lqfb mail ($lqfb_mail) with new mail from admidio ($mail) for $lqfb_id\n";
        //echo "setting new mail from admidio for $lqfb_id\n";
        echo "Sent invitation to $lqfb_id\n";
        exec("./sendinvitation.sh $lqfb_id");
      }
    }


    // send new invitation (after a reset! else you wont need this!)
    // echo "Sent invitation to $lqfb_id\n";
    // exec("echo ./sendinvitation.sh $lqfb_id >> sendmails.sh");
    // exec("echo sleep 120 >> sendmails.sh");
  }
  else
  {
    pg_free_result($result);
    // insert new member directly
    $query = "INSERT INTO member (notify_email, active, identification) VALUES ('$mail', false, '$idc');";
    echo $query . "\n";
    $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result);

    // get the id (!=identification) from the user, we need it for mailing!
    $query = "SELECT id FROM member WHERE identification='$idc'";
    $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    while ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
      $lqfb_id = $line["id"];
    }
    pg_free_result($result);
    
    // send new invitation
    echo "Sent invitation to $lqfb_id\n";
    exec("./sendinvitation.sh $lqfb_id");
  }
  updateUnits($lqfb_id, $lo_num, $akk);
}

$query = "SELECT id,identification,notify_email FROM member_update_copy WHERE locked != true";
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
while ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
  $lqfb_id = $line["id"];
  $id = $line["identification"];
  // lock user according to admidio data (we got no data so this user has to get locked)
  $query = "UPDATE member SET locked = true WHERE identification='$id'";
  echo $query . "\n";
  $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  pg_free_result($result2);

  $query = "DELETE FROM privilege WHERE member_id='$lqfb_id'";
  echo $query . "\n";
  $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  pg_free_result($result2);

  echo "sent info locked to $lqfb_id\n";
  $notify_email = $line["notify_email"];
  exec("./sendinfo_locked.sh $notify_email");
}
pg_free_result($result);


$query = 'DROP TABLE member_update_copy';
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);

pg_close($dbconn);


?>


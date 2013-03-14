<?
require("constants.php");
$sData = file_get_contents("https://mitglieder.piratenpartei.at/adm_api/adm1.php");
if (strlen($datakey1) == 0 || strlen($datakey2) == 0)
  die('Kein Passwort!');

if (strlen($sData) < 1000)
  die('Daten von Mitgliederverwaltung zu kurz!');

$dbconn = pg_connect("dbname=liquid_feedback")
  or die('Verbindungsaufbau fehlgeschlagen: ' . pg_last_error());

$query = 'DROP TABLE IF EXISTS member_update_copy';
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);

$query = 'CREATE TABLE member_update_copy AS SELECT * FROM member';
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);


function updateUnits($lqfb_id, $lo_num, $min, $max)
{
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
  $query = "SELECT * FROM privilege WHERE member_id = '$lqfb_id' AND unit_id >= $min AND unit_id <= $max AND unit_id != $lo_num;";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    $query = "DELETE FROM privilege WHERE member_id = '$lqfb_id' AND unit_id >= $min AND unit_id <= $max AND unit_id != $lo_num;";
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

function updateRegions($lqfb_id, $lo_num, $ro1, $ro2, $min, $max)
{
  if ($ro1 != "AT130" && $ro2 != "AT130" && $lo_num != 2)
  {
   $query = "SELECT * FROM privilege WHERE member_id = '$lqfb_id' AND unit_id = 2;";
   $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
   if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    // remove from AT130
    $query = "DELETE FROM privilege WHERE member_id = '$lqfb_id' AND unit_id = 2;";
    echo $query . "\n";
    $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result2);
   }
   pg_free_result($result);
  }
  // remove from old suborganisation if exists
  $query = "SELECT unit_id FROM privilege LEFT JOIN unit ON unit_id = unit.id WHERE member_id = '$lqfb_id' AND unit_id >= $min AND unit_id <= $max";
  if (strlen($ro1) == 5)
    $query .= " AND description NOT LIKE '%$ro1%'";
  if (strlen($ro2) == 5)
    $query .= " AND description NOT LIKE '%$ro2%'";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    $query = "DELETE FROM privilege WHERE member_id = '$lqfb_id' AND unit_id = {$line['unit_id']};";
    echo $query . "\n";
    $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result2);
  }
  pg_free_result($result);
  if (strlen($ro1) != 5)
    $ro1 = 'ATXXX';
  if (strlen($ro2) != 5)
    $ro2 = 'ATXXX';
  // check whether already in the right suborganisation
  $query = "SELECT * FROM unit WHERE description LIKE '%$ro1%' OR description LIKE '%$ro2%';";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  while ($line = pg_fetch_array($result, null, PGSQL_ASSOC))
  {
    $query2 = "SELECT * FROM privilege WHERE member_id = '$lqfb_id' AND unit_id = {$line['id']}";
    $result2 = pg_query($query2) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    if ($line2 = pg_fetch_array($result2, null, PGSQL_ASSOC))
    {
    }
    else
    {
      // insert into suborganisation
      $query3 = "INSERT INTO privilege (unit_id, member_id) VALUES ({$line['id']}, $lqfb_id);";
      echo $query3 . "\n";
      $result3 = pg_query($query3) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
      pg_free_result($result3);
    }
    pg_free_result($result2);
  }
  pg_free_result($result);
}


$decrypted = rtrim(mcrypt_decrypt(MCRYPT_RIJNDAEL_256, md5($datakey2), base64_decode($sData), MCRYPT_MODE_CBC, md5(md5($datakey2))), "\0");
$lines = explode("\n",$decrypted);
foreach ($lines as $line)
{
  if (strlen($line) < 5) { continue; }
  $values = explode("\t",$line);
  $idc = stripslashes($values[1]);
  if (strlen($values[1]) < 5) { echo "FATAL: idc not valid:\n"; /*print_r($values);*/ continue; }
  $query = "UPDATE member_update_copy SET admin_comment = 'member' WHERE identification = '$idc';";
  $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  pg_free_result($result2);
  $mail_original = stripslashes(trim($values[2]));
  $mail = filter_var($mail_original, FILTER_SANITIZE_EMAIL);
  if (!filter_var($mail, FILTER_VALIDATE_EMAIL)/* || $mail == "mitglied@piratenpartei.at"*/) { /*echo "FATAL: email address invalid: '$mail':\n"; print_r($values);*/ continue; }
  $lo = $values[3];
  $oo = explode(",", $values[4]);
  if (count($oo) == 0)
    $oo[0] = "ATXXX";
  if (count($oo) == 1)
    $oo[1] = "ATXXX";
  $akk = ($values[5] != null);
  $paid = ($values[6] != null);
  if (!$akk || !$paid)
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
  //echo "insert: identification=$idc, email=$mail, lo=$lo_num, oo=$oo_num, akk=$akk, paid=$paid\n";
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
  updateUnits($lqfb_id, $lo_num, 2, 10);
  updateRegions($lqfb_id, $lo_num, $oo[0], $oo[1], 11, 36);
}

$query = "SELECT id,identification,notify_email FROM member_update_copy WHERE locked != true AND admin_comment = 'member'";
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

$query = "SELECT id,identification,notify_email FROM member_update_copy WHERE admin_comment != 'member' AND admin_comment != 'Austritt'";
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
while ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
  $lqfb_id = $line["id"];
  $id = $line["identification"];
  $new_identification = mt_rand();
  // try to delete user - this will only work if the member has done NOTHING in the system except for maybe activating his account...
  $query = "DELETE FROM member WHERE id = $lqfb_id;";
  echo $query . "\n";
  $result2 = pg_query($query) or false;
  $update = $result2 == false ? true : false;
  pg_free_result($result2);
  if ($update)
  {
    // lock user according to admidio data (we got no data so this user has to get locked)
    $query = "UPDATE member SET admin_comment = 'Austritt', active = false, last_activity = NULL, last_login = NULL, login = NULL, password = NULL, locked = true, lang = NULL, notify_email = NULL, notify_email_unconfirmed = NULL, activated = '2000-01-01', notify_email_secret = NULL, notify_level = NULL, notify_email_lock_expiry = NULL, notify_email_secret_expiry = NULL, password_reset_secret = NULL, password_reset_secret_expiry = NULL, identification = '$new_identification', authentication = NULL, organizational_unit = NULL, internal_posts = NULL, realname = NULL, birthday = NULL, address = NULL, email = NULL, xmpp_address = NULL, website = NULL, phone = NULL, mobile_phone = NULL, profession = NULL, external_memberships = NULL, external_posts = NULL, formatting_engine = NULL, statement = NULL, text_search_data = NULL WHERE id = $lqfb_id;";
    echo $query . "\n";
    $result2 = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
    pg_free_result($result2);
  }

  echo "Profile $lqfb_id deleted!!\n";
}
pg_free_result($result);


$query = 'DROP TABLE member_update_copy';
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);

pg_close($dbconn);


?>


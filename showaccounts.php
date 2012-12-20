<?
require("constants.php");
$sData = file_get_contents("http://mitglieder.piratenpartei.at/adm_api/adm1.php");
if (strlen($datakey1) == 0 || strlen($datakey2) == 0)
  die('Kein Passwort!');

if (strlen($sData) < 100)
  die('Daten von Mitgliederverwaltung zu kurz!');

$decrypted = rtrim(mcrypt_decrypt(MCRYPT_RIJNDAEL_256, md5($datakey2), base64_decode($sData), MCRYPT_MODE_CBC, md5(md5($datakey2))), "\0");
$lines = explode("\n",$decrypted);
foreach ($lines as $line)
{
  if (strlen($line) < 5) { continue; }
  $values = explode("\t",$line);
  $idc = stripslashes($values[1]);
  if (strlen($values[1]) < 5) { echo "FATAL: idc not valid:\n"; print_r($values); continue; }
  $mail_original = stripslashes(trim($values[2]));
  $mail = filter_var($mail_original, FILTER_SANITIZE_EMAIL);
  if (!filter_var($mail, FILTER_VALIDATE_EMAIL)/* || $mail == "mitglied@piratenpartei.at"*/) { echo "FATAL: email address invalid: '$mail':\n"; print_r($values); continue; }
  $lo = $values[3];
  $oo = $values[4];
  $akk = ($values[5] != null);
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
  switch ($oo)
  {
    case 90: $oo_num = 11; break;
    default: $oo_num = 0; break;
  }
  echo "insert: identification=$idc, email=$mail, lo=$lo_num, oo=$oo_num, akk=$akk\n";
}

?>


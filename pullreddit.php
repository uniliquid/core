<?

$html = '<div class="initiative_head">';

function printPosts($tid,&$i, &$posts, &$text)
{
  $text .= '<ul style="list-style-type: none;">';
  foreach ($posts as $post)
  {
    if ($post->data->author == 'Liquid')
    {
      if ($post->data->replies && $post->data->replies->data && $post->data->replies->data->children && count($post->data->replies->data->children) > 0)
      {
        $text .= '<li>';
        printPosts($tid,$i,$post->data->replies->data->children,$text);
        $text .= '</li>';
      }
      continue;
    }
    $i++;
    $text .= '<li><b><a href="https://reddit.piratenpartei.at/comments/'.$tid.'#'.$post->data->id.'" target="_blank">'.$post->data->author.'</a>:</b> '.preg_replace('/^<div class="md"><p>(.*)<\/p>\n<\/div>$/','${1}',htmlspecialchars_decode($post->data->body_html));
    if ($post->data->replies)
      printPosts($tid,$i,$post->data->replies->data->children,$text);
    $text .= "</li>";
  }
  $text .= '</ul>';
}
$title = 'Noch keine Diskussionsbeiträge';
$text = '';
if (ereg("^[0-9]+$", $argv[1]))
{
  require("/opt/liquid_feedback_core/constants.php");

  $dbconn = pg_connect("dbname=lfbot") or die('Verbindungsaufbau fehlgeschlagen: ' . pg_last_error());

  $query = "SELECT forum FROM reddit_map WHERE lqfb = '" . $argv[1] . "' AND timestamp < NOW() - '0 minutes'::interval LIMIT 1;";
  $result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
  $tid = 0;
  if ($line = pg_fetch_array($result, null, PGSQL_ASSOC)) {
    $tid = $line["forum"];
  }
  else
  {
    pg_free_result($result);
    pg_close($dbconn);
    return 0;
  }
  pg_free_result($result);

  $data = file_get_contents("https://reddit.piratenpartei.at/comments/$tid.json");
  if (strlen($data) < 100)
  {
    $text = "Noch keine Beiträge";
  }
  else
  {
  $data = json_decode($data);
  $data = $data[1]->data->children;
  $i = 0;
  printPosts($tid,$i,$data,$text);
  if ($i > 0)
  {
    $title = "$i Diskussionsbeiträge";
  }
  else
  {
    $title = 'Noch keine Diskussionsbeiträge';
    $text = '';
  }
  }
}
$html .=<<<END
<a href="https://reddit.piratenpartei.at/comments/$tid" target="_blank" name="discussion" class="title anchor"><img src="/static/icons/16/note.png" class="spaceicon" />$title</a>
<div class="content">
$text
</div>
</div>
END;
echo $html;
$html = pg_escape_string($html);
$query = "UPDATE reddit_map SET timestamp = NOW() WHERE lqfb = '" . $argv[1] . "';";
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);
pg_close($dbconn);
$dbconn = pg_connect("dbname=liquid_feedback") or die('Verbindungsaufbau fehlgeschlagen: ' . pg_last_error());

$query = "DELETE FROM reddit_map WHERE lqfb = '" . $argv[1] . "'; INSERT INTO reddit_map (lqfb,buffer,timestamp) VALUES ('".$argv[1]."','$html',NOW());";
$result = pg_query($query) or die('Abfrage fehlgeschlagen: ' . pg_last_error());
pg_free_result($result);
pg_close($dbconn);
?>


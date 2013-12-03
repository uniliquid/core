<?php
require_once(dirname(__FILE__) . '/../html-to-markdown/HTML_To_Markdown.php');

$file = explode("\n",file_get_contents('/tmp/lqfb_notification.txt'),4);
$file = str_replace("\n","<br />",$file);
$markdown = new HTML_To_Markdown($file[3]);
while (preg_match('/^(.*)\[quote\](.*?)\[\/quote\](.*)$/s',$markdown,$results) == 1)
{
  $markdown = $results[1] . "\n>" . str_replace("\n","\n>",$results[2]) . "\n" . $results[3];
}
echo urlencode($markdown);
?>

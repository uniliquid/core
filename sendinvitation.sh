#!/bin/bash

if [ $# -eq 1 ]; then
  JETZT=`date`
  echo "$JETZT send key to user with lqfb-id $1 via /opt/liquid_feedback_core/sendinvitation.sh" >> /var/log/lqfb/sendinvitation.log
  cd /opt/liquid_feedback_frontend/
  echo "Member:by_id($1):send_invitation(\"/opt/liquid_feedback_frontend/config/invite_mail.txt\",\"[LiquidFeedback] Einladung zum LiquidFeedback der Piratenpartei\")" | ../webmcp/bin/webmcp_shell myconfig
fi


cd /opt/liquid_feedback_frontend/
echo "print(config.footer_html)" | ../webmcp/bin/webmcp_shell myconfig 2>&1 | tail -n +3 | head -n -1

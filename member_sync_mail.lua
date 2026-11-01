-- The mail worker of the member sync, run by lf_member_sync_mail in the
-- frontend's WebMCP shell (README, "Member sync"). One pass over the queue
-- of member_sync.sql:
-- - rows that no longer fit their member's state (view
--   member_sync_mail_stale) are deleted unsent;
-- - each due row (view member_sync_mail_due): "invite" through the
--   frontend's Member:send_invitation(), "locked" and "unlocked" with the
--   texts member_sync_locked.txt and member_sync_unlocked.txt through
--   net.send_mail; the row is deleted after a successful send only (and
--   only if the sync has not replaced it meanwhile), so a failed or
--   interrupted send is retried by the next pass.
-- Prints "<n> sent, <n> failed"; exits with status 1 if any send failed or
-- on any error.

local subjects = {
  locked   = "[Liquid] Sperrung des Accounts",
  unlocked = "[Liquid] Freischaltung des Accounts"
}

local function text(kind)
  local file = assert(io.open(os.getenv("LF_CORE_DIR") .. "/member_sync_" .. kind .. ".txt", "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local sent, failed = 0, 0
local ok, err = pcall(function()
  db:query("DELETE FROM member_sync_mail WHERE member_id IN (SELECT member_id FROM member_sync_mail_stale)")
  local rows = db:query("SELECT member_id, kind, created::text AS created, notify_email FROM member_sync_mail_due ORDER BY member_id")
  for i, row in ipairs(rows) do
    local send_ok, success = pcall(function()
      if row.kind == "invite" then
        return Member:by_id(row.member_id):send_invitation()
      end
      return net.send_mail{
        envelope_from = config.mail_envelope_from,
        from          = config.mail_from,
        reply_to      = config.mail_reply_to,
        to            = row.notify_email,
        subject       = subjects[row.kind],
        content_type  = "text/plain; charset=UTF-8",
        content       = text(row.kind)
      }
    end)
    if send_ok and success then
      db:query{ "DELETE FROM member_sync_mail WHERE member_id = ? AND kind = ? AND created = ?::timestamptz", row.member_id, row.kind, row.created }
      sent = sent + 1
    else
      failed = failed + 1
    end
  end
end)
print(sent .. " sent, " .. failed .. " failed")
if not ok then
  io.stderr:write("member_sync_mail: " .. tostring(err) .. "\n")
end
if not ok or failed > 0 then
  os.exit(1)
end

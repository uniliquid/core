-- The mail worker of the member sync, run by lf_member_sync_mail in the
-- frontend's WebMCP shell (README, "Member sync"). One pass over the queue
-- of member_sync.sql:
-- - rows that no longer fit their member's state (view
--   member_sync_mail_stale) are deleted unsent, unless replaced meanwhile;
-- - each due row (view member_sync_mail_due), in its own transaction:
--   the member row is locked (FOR UPDATE, before the queue row, in the order
--   the sync locks them, so a sync run waits for this mail) and the queue
--   row (FOR UPDATE); if the row was replaced or no longer fits, it is
--   skipped. "invite" goes through the frontend's
--   Member:send_invitation(), "locked" and "unlocked" with the texts
--   member_sync_locked.txt and member_sync_unlocked.txt through
--   net.send_mail; after a successful send the row is deleted and the
--   transaction committed, otherwise rolled back (a new invite code too),
--   so the next pass retries it.
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
  -- The whole key: a row the sync replaces meanwhile (new kind or time,
  -- checked again after the row lock) is not deleted.
  db:query("DELETE FROM member_sync_mail USING member_sync_mail_stale AS stale WHERE member_sync_mail.member_id = stale.member_id AND member_sync_mail.kind = stale.kind AND member_sync_mail.created = stale.created")
  local rows = db:query("SELECT member_id, kind, created::text AS created FROM member_sync_mail_due ORDER BY member_id")
  for i, row in ipairs(rows) do
    local key = { row.member_id, row.kind, row.created }
    db:query("BEGIN")
    local send_ok, success = pcall(function()
      db:query{ "SELECT NULL FROM member WHERE id = ? FOR UPDATE", row.member_id }
      db:query{ "SELECT NULL FROM member_sync_mail WHERE member_id = ? FOR UPDATE", row.member_id }
      local due = db:query{ "SELECT notify_email FROM member_sync_mail_due WHERE member_id = ? AND kind = ? AND created = ?::timestamptz", unpack(key) }
      if #due == 0 then
        return "skipped"
      end
      if row.kind == "invite" then
        return Member:by_id(row.member_id):send_invitation()
      end
      return net.send_mail{
        envelope_from = config.mail_envelope_from,
        from          = config.mail_from,
        reply_to      = config.mail_reply_to,
        to            = due[1].notify_email,
        subject       = subjects[row.kind],
        content_type  = "text/plain; charset=UTF-8",
        content       = text(row.kind)
      }
    end)
    if send_ok and success and success ~= "skipped" then
      db:query{ "DELETE FROM member_sync_mail WHERE member_id = ? AND kind = ? AND created = ?::timestamptz", unpack(key) }
      db:query("COMMIT")
      sent = sent + 1
    else
      db:query("ROLLBACK")
      if not (send_ok and success == "skipped") then
        failed = failed + 1
      end
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

-- The mail worker of the member sync, run by lf_member_sync_mail in the
-- frontend's WebMCP shell (README, "Member sync"). One pass over the queue
-- of member_sync.sql, each row in its own transaction: the member row is
-- locked (FOR UPDATE, before the queue row, in the order the sync locks
-- them, so a sync run waits for this mail) and the queue row (FOR UPDATE);
-- a row that is not due (view member_sync_mail_due: its state no longer
-- fits) is deleted unsent, by its whole key (kind and time too, so a row
-- the sync replaced meanwhile stays for the next pass). "invite" goes
-- through the frontend's Member:send_invitation(), "locked" and "unlocked"
-- with the texts member_sync_locked.txt and member_sync_unlocked.txt
-- through net.send_mail; after a successful send the row is deleted and
-- the transaction committed, otherwise rolled back (a new invite code too),
-- so the next pass retries it.
-- Prints "<n> sent, <n> failed"; exits with status 1 if any send failed or
-- on any error.

local subjects = {
  locked   = "[Liquid] Sperrung des Accounts",
  unlocked = "[Liquid] Freischaltung des Accounts"
}

-- The text of member_sync_<kind>.txt with each #{base_url} replaced by the
-- frontend's config.absolute_base_url (with exactly one final slash); a
-- plain replacement, no pattern.
local function text(kind)
  local file = assert(io.open(os.getenv("LF_CORE_DIR") .. "/member_sync_" .. kind .. ".txt", "r"))
  local content = file:read("*a")
  file:close()
  local placeholder = "#{base_url}"
  local start = content:find(placeholder, 1, true)
  local base_url = start and assert(config.absolute_base_url, "config.absolute_base_url not set"):gsub("/+$", "") .. "/"
  while start do
    content = content:sub(1, start - 1) .. base_url .. content:sub(start + #placeholder)
    start = content:find(placeholder, start + #base_url, true)
  end
  return content
end

local sent, failed = 0, 0
local ok, err = pcall(function()
  local rows = db:query("SELECT member_id, kind, created::text AS created FROM member_sync_mail ORDER BY member_id")
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
    if send_ok and success then
      db:query{ "DELETE FROM member_sync_mail WHERE member_id = ? AND kind = ? AND created = ?::timestamptz", unpack(key) }
      db:query("COMMIT")
      if success ~= "skipped" then
        sent = sent + 1
      end
    else
      db:query("ROLLBACK")
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

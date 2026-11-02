-- Test only: stand-ins for the frontend's WebMCP globals (db, Member, net,
-- config) for tests/member-sync-mail-test.php, with an in-memory member and
-- queue table and transactions; runs member_sync_mail.lua for the scenario
-- in STUB_SCENARIO and prints the outcome:
--   mail <to>|<subject>|<first line>   each mail handed to net.send_mail
--   queue <member id> <kind> <created> the queue after the pass
--   code <member id> <invite code>     the invite codes after the pass
--   exit <status>
-- Mails to addresses containing "fail" fail.

local scenarios = {
  -- one mail of each kind, all sent
  ok = {
    members = { [1] = { email = "m1@example.org" }, [2] = { email = "m2@example.org", locked = true },
      [3] = { email = "m3@example.org", activated = true } },
    queue = { [1] = { kind = "invite" }, [2] = { kind = "locked" }, [3] = { kind = "unlocked" } } },
  -- failing sends stay queued; the invite code saved before the failed send is rolled back
  fail = {
    members = { [1] = { email = "fail1@example.org", code = "OLD" }, [2] = { email = "fail2@example.org" },
      [3] = { email = "m3@example.org", locked = true } },
    queue = { [1] = { kind = "invite" }, [2] = { kind = "unlocked" }, [3] = { kind = "locked" } } },
  -- rows that no longer fit are deleted unsent
  stale = {
    members = { [1] = { email = "m1@example.org", activated = true }, [2] = { email = "m2@example.org" },
      [3] = { email = "m3@example.org", locked = true } },
    queue = { [1] = { kind = "invite" }, [2] = { kind = "locked" }, [3] = { kind = "locked" } } },
  -- the sync replaces rows while the worker waits for the row lock: skipped, neither sent nor failed
  skipped = {
    members = { [1] = { email = "m1@example.org" }, [2] = { email = "m2@example.org", locked = true } },
    queue = { [1] = { kind = "invite" }, [2] = { kind = "locked" } },
    replace = { [1] = { kind = "locked", lock = true }, [2] = { kind = "locked" } } },
  -- a database error outside a send: exit 1
  dberror = {
    members = { [1] = { email = "m1@example.org" } }, queue = { [1] = { kind = "invite" } }, error = true },
}
local scenario = assert(scenarios[os.getenv("STUB_SCENARIO")], "unknown scenario")

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = type(v) == "table" and copy(v) or v end
  return c
end
local committed = { members = copy(scenario.members), queue = copy(scenario.queue) }
for id, row in pairs(committed.queue) do row.created = "t" .. id end
local current = committed  -- the transaction's state, or the committed one
local in_transaction = false

local function due(state, id)
  local q, m = state.queue[id], state.members[id]
  if not q or not m or not m.email then return false end
  if q.kind == "invite" then return not m.activated and not m.locked end
  if q.kind == "locked" then return m.locked == true end
  return not m.locked
end

local function key_matches(state, id, kind, created)
  local q = state.queue[id]
  return q and q.kind == kind and q.created == created
end

db = {}
function db:query(q)
  if type(q) == "string" then
    if q == "BEGIN" then current = copy(committed) in_transaction = true return {} end
    if q == "COMMIT" then committed = current in_transaction = false return {} end
    if q == "ROLLBACK" then current = committed in_transaction = false return {} end
    if q:find("^DELETE FROM member_sync_mail USING member_sync_mail_stale") then
      if scenario.error then error("database error") end
      for id in pairs(current.queue) do
        if not due(current, id) then current.queue[id] = nil end
      end
      return {}
    end
    if q:find("^SELECT member_id, kind, created::text AS created FROM member_sync_mail_due") then
      local rows, ids = {}, {}
      for id in pairs(current.queue) do if due(current, id) then table.insert(ids, id) end end
      table.sort(ids)
      for i, id in ipairs(ids) do
        rows[i] = { member_id = id, kind = current.queue[id].kind, created = current.queue[id].created }
      end
      return rows
    end
    error("unexpected query: " .. q)
  end
  local sql, id = q[1], q[2]
  if sql:find("^SELECT NULL FROM member WHERE id = %? FOR UPDATE$") then return {} end
  if sql:find("^SELECT NULL FROM member_sync_mail WHERE member_id = %? FOR UPDATE$") then
    -- what the sync committed while this lock was awaited
    local replacement = scenario.replace and scenario.replace[id]
    if replacement then
      for _, state in ipairs({ committed, current }) do
        state.queue[id] = { kind = replacement.kind, created = "new" }
        if replacement.lock then state.members[id].locked = true end
      end
    end
    return {}
  end
  if sql:find("^SELECT notify_email FROM member_sync_mail_due WHERE member_id = %? AND kind = %? AND created = %?::timestamptz$") then
    if key_matches(current, id, q[3], q[4]) and due(current, id) then
      return { { notify_email = current.members[id].email } }
    end
    return {}
  end
  if sql:find("^DELETE FROM member_sync_mail WHERE member_id = %? AND kind = %? AND created = %?::timestamptz$") then
    if key_matches(current, id, q[3], q[4]) then current.queue[id] = nil end
    return {}
  end
  error("unexpected query: " .. sql)
end

config = { mail_envelope_from = "liquid@example.org", mail_from = { name = "Liquid", address = "liquid@example.org" },
  mail_reply_to = "liquid@example.org" }

net = {}
function net.send_mail(args)
  print("mail " .. args.to .. "|" .. args.subject .. "|" .. args.content:match("^[^\n]*"))
  return not args.to:find("fail")
end

Member = {}
function Member:by_id(id)
  return { send_invitation = function()
    -- as the frontend: the new code is saved before the mail is sent
    current.members[id].code = "NEW"
    return net.send_mail{ to = current.members[id].email, subject = "Invitation", content = "Invite code" }
  end }
end

local function report()
  local ids = {}
  for id in pairs(committed.members) do table.insert(ids, id) end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local q = committed.queue[id]
    if q then print("queue " .. id .. " " .. q.kind .. " " .. q.created) end
    if committed.members[id].code then print("code " .. id .. " " .. committed.members[id].code) end
  end
  if in_transaction then print("open transaction") end
end

local exit = os.exit
os.exit = function(status) report() print("exit " .. status) exit(status) end
dofile(os.getenv("LF_CORE_DIR") .. "/member_sync_mail.lua")
report()
print("exit 0")

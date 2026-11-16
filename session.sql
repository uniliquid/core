-- Login session additions (on top of core.sql 2.2.1): the database side of
-- the frontend's session hardening (README, "Session additions").
-- Idempotent, one transaction; apply as the owner of the LiquidFeedback
-- tables on every deployment, before a frontend that uses it:
--
--   psql -X -v ON_ERROR_STOP=1 -f session.sql <database>
--
-- Adds:
--   session.logged_in_at        time of the login that created the row
--                               (NULL: anonymous, or created before this
--                               file); the frontend caps "expiry" at
--                               logged_in_at + its maximum lifetime.
--   session_member_id_idx       partial index for deleting a member's
--                               sessions (lock, password change).
--   trigger on member           deletes all sessions of a member when it
--                               becomes locked.
--
-- Needs PostgreSQL 9.6 or newer (ADD COLUMN / CREATE INDEX IF NOT EXISTS).

BEGIN;

ALTER TABLE public.session ADD COLUMN IF NOT EXISTS "logged_in_at" TIMESTAMPTZ;

COMMENT ON COLUMN public.session."logged_in_at" IS
  'Time of the login that created this session; NULL for anonymous sessions and for sessions created before session.sql. The frontend never extends "expiry" beyond this time plus its maximum session lifetime.';

CREATE INDEX IF NOT EXISTS "session_member_id_idx"
  ON public.session ("member_id") WHERE "member_id" IS NOT NULL;

CREATE OR REPLACE FUNCTION public.session_delete_on_member_lock_trigger()
  RETURNS TRIGGER
  LANGUAGE plpgsql VOLATILE
  SET search_path = pg_catalog, public, pg_temp
  AS $$
    BEGIN
      DELETE FROM public.session WHERE "member_id" = NEW."id";
      RETURN NULL;
    END;
  $$;

COMMENT ON FUNCTION public.session_delete_on_member_lock_trigger() IS
  'Implementation of trigger "session_delete_on_member_lock" on table "member"';

DROP TRIGGER IF EXISTS "session_delete_on_member_lock" ON public.member;
CREATE TRIGGER "session_delete_on_member_lock"
  AFTER UPDATE OF "locked" ON public.member FOR EACH ROW
  WHEN (NEW."locked" AND NOT OLD."locked")
  EXECUTE PROCEDURE public.session_delete_on_member_lock_trigger();

COMMENT ON TRIGGER "session_delete_on_member_lock" ON public.member IS
  'A member that becomes locked loses all sessions (logged out everywhere)';

COMMIT;

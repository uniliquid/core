-- Member sync (Admidio -> LiquidFeedback): the database side of
-- member-sync.php (README, "Member sync"). Apply as the owner of the
-- LiquidFeedback tables, on every deployment (idempotent, one transaction):
--
--   psql -X -v ON_ERROR_STOP=1 -v lo_map='<json>' -v region_map='<json>' \
--     -v managed_units='<json>' -f member_sync.sql <database>
--
--   lo_map         {"<Admidio LO role id>": <unit id>, ...}
--   region_map     {"<NUTS-3 code>": <unit id>, ...}
--   managed_units  [<unit id>, ...]: the units whose privileges the sync
--                  manages; must contain unit 1 and every unit of the maps.
--
-- Creates:
--   public.member_sync(jsonb)      SECURITY DEFINER; the only object the
--                                  role lqfb_membersync may use (EXECUTE).
--   public.member_sync_units()     the maps, baked in at apply time.
--   public.member_sync_owned(text) the ownership predicate: the sync only
--                                  ever touches rows whose identification
--                                  is 'mv:<pseudonym>' (64 lowercase hex
--                                  digits, computed by member-sync.php).
--   public.member_sync_mail        the mail queue for lf_member_sync_mail
--                                  (one pending mail per member: member id,
--                                  kind, time; deleted once sent, so an
--                                  lf_export dump holds the unsent ones).
--   public.member_sync_mail_due    queued mails whose state still fits (the
--                                  worker deletes the others unsent).
--
-- The role lqfb_membersync must exist (created by the deployment).

BEGIN;

SET LOCAL search_path = pg_catalog, public, pg_temp;

-- Only the applying role (or a role it belongs to) may own schema public,
-- and no other role (nor PUBLIC) may create in it: the functions below
-- resolve names in it.
DO $$
  BEGIN
    IF NOT EXISTS (
      SELECT NULL FROM pg_catalog.pg_namespace
      WHERE "nspname" = 'public'
      AND pg_catalog.pg_has_role(current_user, "nspowner", 'MEMBER')
    ) THEN
      RAISE EXCEPTION 'member_sync.sql: schema public is not owned by %', current_user;
    END IF;
    IF EXISTS (
      SELECT NULL FROM pg_catalog.pg_namespace, pg_catalog.aclexplode("nspacl") AS "acl"
      WHERE "nspname" = 'public'
      AND "acl"."privilege_type" = 'CREATE'
      AND "acl"."grantee" <> "nspowner"
    ) THEN
      RAISE EXCEPTION 'member_sync.sql: a role other than the owner (or PUBLIC) has CREATE on schema public';
    END IF;
  END;
$$;

-- The maps (psql variables are not substituted inside dollar quotes, so the
-- function is generated with format(); the body is a quoted literal, %L,
-- not dollar-quoted, so no map value can end it).
SELECT pg_catalog.format($f$
CREATE OR REPLACE FUNCTION public.member_sync_units()
  RETURNS JSONB
  LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public, pg_temp
  AS %L
$f$, pg_catalog.format(
  'SELECT pg_catalog.jsonb_build_object(''lo'', %L::jsonb, ''regions'', %L::jsonb, ''managed'', %L::jsonb)',
  :'lo_map', :'region_map', :'managed_units')) \gexec

DO $$
  DECLARE
    "units_v" JSONB := public.member_sync_units();
  BEGIN
    IF
      jsonb_typeof("units_v"->'managed') IS DISTINCT FROM 'array' OR
      jsonb_array_length("units_v"->'managed') = 0 OR
      NOT ("units_v"->'managed') @> '[1]' OR
      EXISTS (
        SELECT NULL FROM jsonb_array_elements("units_v"->'managed') AS "managed_unit"
        WHERE jsonb_typeof("managed_unit") <> 'number'
        OR "managed_unit"::text !~ '^[1-9][0-9]{0,8}$'
        OR NOT EXISTS (SELECT NULL FROM public.unit WHERE "id" = "managed_unit"::text::int4)
      ) OR
      (SELECT count(*) <> count(DISTINCT "managed_unit") FROM jsonb_array_elements("units_v"->'managed') AS "managed_unit")
    THEN
      RAISE EXCEPTION 'member_sync.sql: managed_units must be a list of distinct existing unit ids with unit 1';
    END IF;
    IF
      jsonb_typeof("units_v"->'lo') IS DISTINCT FROM 'object' OR
      EXISTS (
        SELECT NULL FROM jsonb_each("units_v"->'lo')
        WHERE "key" !~ '^[1-9][0-9]{0,8}$'
        OR jsonb_typeof("value") <> 'number'
        OR NOT ("units_v"->'managed') @> jsonb_build_array("value")
        OR "value"::text !~ '^[1-9][0-9]{0,8}$'
      )
    THEN
      RAISE EXCEPTION 'member_sync.sql: lo_map must map role ids to managed units';
    END IF;
    IF
      jsonb_typeof("units_v"->'regions') IS DISTINCT FROM 'object' OR
      EXISTS (
        SELECT NULL FROM jsonb_each("units_v"->'regions')
        WHERE "key" !~ '^[A-Z]{2}[0-9A-Z]{3}$'
        OR jsonb_typeof("value") <> 'number'
        OR NOT ("units_v"->'managed') @> jsonb_build_array("value")
        OR "value"::text !~ '^[1-9][0-9]{0,8}$'
      )
    THEN
      RAISE EXCEPTION 'member_sync.sql: region_map must map NUTS-3 codes to managed units';
    END IF;
  END;
$$;

CREATE OR REPLACE FUNCTION public.member_sync_owned("identification_p" TEXT)
  RETURNS BOOLEAN
  LANGUAGE sql IMMUTABLE
  AS $$ SELECT "identification_p" OPERATOR(pg_catalog.~) '^mv:[0-9a-f]{64}$' $$;

CREATE TABLE IF NOT EXISTS public.member_sync_mail (
        "member_id"             INT4            PRIMARY KEY REFERENCES public.member ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "kind"                  TEXT            NOT NULL CHECK ("kind" IN ('invite', 'locked', 'unlocked')),
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now() );

COMMENT ON TABLE public.member_sync_mail IS 'Mails queued by member_sync() for lf_member_sync_mail; one per member, the latest transition replaces an unsent earlier one';

CREATE OR REPLACE VIEW public.member_sync_mail_due AS
  SELECT "member_sync_mail"."member_id", "member_sync_mail"."kind", "member_sync_mail"."created", "member"."notify_email"
  FROM public.member_sync_mail
  JOIN public.member ON "member"."id" = "member_sync_mail"."member_id"
  WHERE public.member_sync_owned("member"."identification")
  AND "member"."notify_email" NOTNULL
  AND CASE "member_sync_mail"."kind"
    WHEN 'invite'   THEN "member"."activated" ISNULL AND NOT "member"."locked"
    WHEN 'locked'   THEN "member"."locked"
    WHEN 'unlocked' THEN NOT "member"."locked"
  END;

COMMENT ON VIEW public.member_sync_mail_due IS 'Queued mails to send: owned rows with an address whose state still fits the kind (invite: never activated and not locked; locked: locked; unlocked: not locked)';

-- The version with the removals switch (deleted or anonymised members).
DROP FUNCTION IF EXISTS public.member_sync(JSONB, BOOLEAN);

CREATE OR REPLACE FUNCTION public.member_sync("members_p" JSONB)
  RETURNS TABLE (
    "created"            INT4,
    "unlocked"           INT4,
    "locked"             INT4,
    "privileges_granted" INT4,
    "privileges_revoked" INT4,
    "email_updated"      INT4,
    "no_email"           INT4,
    "changes"            TEXT )
  LANGUAGE plpgsql VOLATILE SECURITY DEFINER
  SET search_path = pg_catalog, public, pg_temp
  AS $$
#variable_conflict use_column
    DECLARE
      "units_v"       JSONB := public.member_sync_units();
      "managed_v"     INT4[];
      "entry_v"       JSONB;
      "position_v"    INT8;
      "listed_v"      TEXT[];
      "eligible_v"    TEXT[];
      "want_member_v" INT4[];
      "want_unit_v"   INT4[];
      "count_v"       INT4;
      -- One line per change, 'member <id>: <action>' (member-sync.php
      -- --verbose); the member id only, no other data.
      "changes_v"     TEXT[] := '{}';
    BEGIN
      -- Fail fast while another run holds the lock (member-sync.php holds it
      -- as a session lock from before its fetch).
      IF NOT pg_try_advisory_xact_lock(8251004315201937961) THEN
        RAISE EXCEPTION 'member_sync: another run holds the lock'
          USING ERRCODE = 'lock_not_available';
      END IF;
      -- Validation: the whole list or nothing (no personal data in messages).
      IF
        jsonb_typeof("members_p") IS DISTINCT FROM 'array' OR
        jsonb_array_length("members_p") = 0
      THEN
        RAISE EXCEPTION 'member_sync: not a non-empty list'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;
      FOR "entry_v", "position_v" IN
        SELECT * FROM jsonb_array_elements("members_p") WITH ORDINALITY
      LOOP
        IF
          jsonb_typeof("entry_v") <> 'object' OR
          ARRAY(SELECT "key" FROM jsonb_object_keys("entry_v") AS "key" ORDER BY "key" COLLATE "C")
            <> ARRAY['eligible', 'email', 'identification', 'lo', 'regions']
        THEN
          RAISE EXCEPTION 'member_sync: entry %: not an object with exactly identification, lo, eligible, email, regions', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
        IF
          jsonb_typeof("entry_v"->'identification') <> 'string' OR
          NOT public.member_sync_owned("entry_v"->>'identification')
        THEN
          RAISE EXCEPTION 'member_sync: entry %: bad identification', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
        IF NOT (
          jsonb_typeof("entry_v"->'lo') = 'null' OR (
            jsonb_typeof("entry_v"->'lo') = 'number' AND
            ("units_v"->'lo') ? ("entry_v"->>'lo')
          )
        ) THEN
          RAISE EXCEPTION 'member_sync: entry %: lo not null and not in the map', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
        IF jsonb_typeof("entry_v"->'eligible') <> 'boolean' THEN
          RAISE EXCEPTION 'member_sync: entry %: eligible not a boolean', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
        IF NOT (
          jsonb_typeof("entry_v"->'email') = 'null' OR (
            jsonb_typeof("entry_v"->'email') = 'string' AND
            length("entry_v"->>'email') <= 254 AND
            ("entry_v"->>'email') ~ '^[A-Za-z0-9!#$%&''*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&''*+/=?^_`{|}~-]+)*@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
          )
        ) THEN
          RAISE EXCEPTION 'member_sync: entry %: email not null and not valid', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
        IF
          jsonb_typeof("entry_v"->'regions') <> 'array' OR
          EXISTS (
            SELECT NULL FROM jsonb_array_elements("entry_v"->'regions') AS "region"
            WHERE jsonb_typeof("region") <> 'string'
            OR NOT ("units_v"->'regions') ? ("region" #>> '{}')
          ) OR
          (SELECT count(*) <> count(DISTINCT "region") FROM jsonb_array_elements("entry_v"->'regions') AS "region")
        THEN
          RAISE EXCEPTION 'member_sync: entry %: regions not a list of distinct codes of the map', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
      END LOOP;
      SELECT
        array_agg("identification"),
        coalesce(array_agg("identification") FILTER (WHERE "eligible"), '{}'),
        count(DISTINCT "identification")
        INTO "listed_v", "eligible_v", "count_v"
        FROM jsonb_to_recordset("members_p") AS "entry" ("identification" TEXT, "eligible" BOOLEAN);
      IF "count_v" <> cardinality("listed_v") THEN
        RAISE EXCEPTION 'member_sync: duplicate identification'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;
      -- A list that matches none of the owned rows (e.g. pseudonyms made
      -- with another key) would lock them all.
      IF
        EXISTS (SELECT NULL FROM public.member WHERE public.member_sync_owned("identification")) AND
        NOT EXISTS (SELECT NULL FROM public.member WHERE "identification" = ANY ("listed_v"))
      THEN
        RAISE EXCEPTION 'member_sync: no listed member has a row (another key?)'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;
      SELECT array_agg("unit"::text::int4) INTO "managed_v"
        FROM jsonb_array_elements("units_v"->'managed') AS "unit";
      -- Eligible without a row: a new account (with an address) and an invite.
      WITH "new" AS (
        INSERT INTO public.member ("identification", "notify_email")
        SELECT "entry"."identification", "entry"."email"
        FROM jsonb_to_recordset("members_p") AS "entry" ("identification" TEXT, "eligible" BOOLEAN, "email" TEXT)
        WHERE "entry"."eligible" AND "entry"."email" NOTNULL
        AND NOT EXISTS (SELECT NULL FROM public.member WHERE "identification" = "entry"."identification")
        RETURNING "id"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", 'invite' FROM "new"
        RETURNING "member_id", "kind"
      )
      SELECT (SELECT count(*) FROM "new"),
        "changes_v" || ARRAY(SELECT 'member ' || "id" || ': created' FROM "new" ORDER BY "id")
          || ARRAY(SELECT 'member ' || "member_id" || ': mail queued ' || "kind" FROM "queued" ORDER BY "member_id")
        INTO "created", "changes_v";
      SELECT count(*) INTO "no_email"
        FROM jsonb_to_recordset("members_p") AS "entry" ("identification" TEXT, "eligible" BOOLEAN, "email" TEXT)
        WHERE "entry"."eligible" AND "entry"."email" ISNULL
        AND NOT EXISTS (SELECT NULL FROM public.member WHERE "identification" = "entry"."identification");
      -- Expired password resets (or ones without expiry) cleared on every
      -- run: the frontend refuses a new reset while any secret is set.
      UPDATE public.member SET "password_reset_secret" = NULL, "password_reset_secret_expiry" = NULL
        WHERE public.member_sync_owned("identification")
        AND "password_reset_secret" NOTNULL
        AND ("password_reset_secret_expiry" ISNULL OR "password_reset_secret_expiry" <= now());
      -- Eligible and locked: unlock; the "unlocked" mail for activated
      -- members (active or not), the invite again for never activated ones
      -- without a code.
      WITH "unlocked" AS (
        UPDATE public.member SET "locked" = FALSE
        WHERE public.member_sync_owned("identification")
        AND "identification" = ANY ("eligible_v")
        AND "locked"
        RETURNING "id", "activated", "invite_code"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", CASE WHEN "activated" NOTNULL THEN 'unlocked' ELSE 'invite' END
        FROM "unlocked"
        WHERE "activated" NOTNULL OR "invite_code" ISNULL
        ON CONFLICT ("member_id") DO UPDATE SET "kind" = EXCLUDED."kind", "created" = EXCLUDED."created"
        RETURNING "member_id", "kind"
      )
      SELECT (SELECT count(*) FROM "unlocked"),
        "changes_v" || ARRAY(SELECT 'member ' || "id" || ': unlocked' FROM "unlocked" ORDER BY "id")
          || ARRAY(SELECT 'member ' || "member_id" || ': mail queued ' || "kind" FROM "queued" ORDER BY "member_id")
        INTO "unlocked", "changes_v";
      -- Eligible, not active, another address: take it, drop pending
      -- confirmations and resets; if never activated, revoke the invite code
      -- sent to the old address and invite again.
      WITH "updated" AS (
        UPDATE public.member SET
          "invite_code"                  = CASE WHEN "member"."activated" ISNULL THEN NULL ELSE "member"."invite_code" END,
          "invite_code_expiry"           = CASE WHEN "member"."activated" ISNULL THEN NULL ELSE "member"."invite_code_expiry" END,
          "notify_email"                 = "entry"."email",
          "notify_email_unconfirmed"     = NULL,
          "notify_email_secret"          = NULL,
          "notify_email_secret_expiry"   = NULL,
          "password_reset_secret"        = NULL,
          "password_reset_secret_expiry" = NULL
        FROM jsonb_to_recordset("members_p") AS "entry" ("identification" TEXT, "eligible" BOOLEAN, "email" TEXT)
        WHERE public.member_sync_owned("member"."identification")
        AND "member"."identification" = "entry"."identification"
        AND "entry"."eligible" AND "entry"."email" NOTNULL
        AND NOT "member"."active"
        AND "member"."notify_email" IS DISTINCT FROM "entry"."email"
        RETURNING "member"."id", "member"."activated"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", 'invite' FROM "updated" WHERE "activated" ISNULL
        ON CONFLICT ("member_id") DO UPDATE SET "kind" = EXCLUDED."kind", "created" = EXCLUDED."created"
        RETURNING "member_id", "kind"
      )
      SELECT (SELECT count(*) FROM "updated"),
        "changes_v" || ARRAY(SELECT 'member ' || "id" || ': email updated' FROM "updated" ORDER BY "id")
          || ARRAY(SELECT 'member ' || "member_id" || ': mail queued ' || "kind" FROM "queued" ORDER BY "member_id")
        INTO "email_updated", "changes_v";
      -- Privileges: unit 1, the LO unit and the region units of eligible
      -- members; the sync owns voting_right and initiative_right on the
      -- managed units of listed members and admins.
      SELECT array_agg("member"."id"), array_agg("unit"."id")
        INTO "want_member_v", "want_unit_v"
        FROM jsonb_to_recordset("members_p") AS "entry" ("identification" TEXT, "lo" INT4, "eligible" BOOLEAN, "regions" JSONB)
        JOIN public.member ON "member"."identification" = "entry"."identification"
        CROSS JOIN LATERAL (
          SELECT 1
          UNION SELECT ("units_v"->'lo'->>"entry"."lo"::text)::int4 WHERE "entry"."lo" NOTNULL
          UNION SELECT ("units_v"->'regions'->>"region")::int4
            FROM jsonb_array_elements_text("entry"."regions") AS "region"
        ) AS "unit" ("id")
        WHERE "entry"."eligible";
      WITH "granted" AS (
        INSERT INTO public.privilege ("unit_id", "member_id", "voting_right", "initiative_right")
        SELECT "unit_id", "member_id", TRUE, TRUE
        FROM unnest("want_member_v", "want_unit_v") AS "wanted" ("member_id", "unit_id")
        ON CONFLICT ("unit_id", "member_id") DO UPDATE SET "voting_right" = TRUE, "initiative_right" = TRUE
        WHERE NOT ("privilege"."voting_right" AND "privilege"."initiative_right")
        RETURNING "member_id"
      )
      SELECT (SELECT count(*) FROM "granted"),
        "changes_v" || ARRAY(SELECT 'member ' || "member_id" || ': privileges +' || count(*)
          FROM "granted" GROUP BY "member_id" ORDER BY "member_id")
        INTO "privileges_granted", "changes_v";
      -- Owned and not eligible (listed or not, admins too): locked, on
      -- every run; the "locked" mail on the transition only. Nothing is
      -- deleted: a departed member stays a locked row.
      WITH "locked" AS (
        UPDATE public.member SET "locked" = TRUE
        WHERE public.member_sync_owned("identification")
        AND NOT "identification" = ANY ("eligible_v")
        AND NOT "locked"
        RETURNING "id"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", 'locked' FROM "locked"
        ON CONFLICT ("member_id") DO UPDATE SET "kind" = EXCLUDED."kind", "created" = EXCLUDED."created"
        RETURNING "member_id", "kind"
      )
      SELECT (SELECT count(*) FROM "locked"),
        "changes_v" || ARRAY(SELECT 'member ' || "id" || ': locked' FROM "locked" ORDER BY "id")
          || ARRAY(SELECT 'member ' || "member_id" || ': mail queued ' || "kind" FROM "queued" ORDER BY "member_id")
        INTO "locked", "changes_v";
      -- Locked rows deactivated, also those locked earlier (LQFB counts
      -- "active" members, not unlocked ones; a login activates again).
      UPDATE public.member SET "active" = FALSE
        WHERE public.member_sync_owned("identification") AND "locked" AND "active";
      DELETE FROM public.session USING public.member
        WHERE "session"."member_id" = "member"."id"
        AND public.member_sync_owned("member"."identification")
        AND "member"."locked";
      -- Unwanted rights in the managed units: the two flags cleared, the row
      -- kept (a later grant sets them again).
      WITH "revoked" AS (
        UPDATE public.privilege SET "voting_right" = FALSE, "initiative_right" = FALSE
        FROM public.member
        WHERE "member"."id" = "privilege"."member_id"
        AND public.member_sync_owned("member"."identification")
        AND "privilege"."unit_id" = ANY ("managed_v")
        AND ("privilege"."voting_right" OR "privilege"."initiative_right")
        AND ("privilege"."member_id", "privilege"."unit_id") NOT IN (
          SELECT * FROM unnest("want_member_v", "want_unit_v"))
        RETURNING "privilege"."member_id"
      )
      SELECT (SELECT count(*) FROM "revoked"),
        "changes_v" || ARRAY(SELECT 'member ' || "member_id" || ': privileges -' || count(*)
          FROM "revoked" GROUP BY "member_id" ORDER BY "member_id")
        INTO "privileges_revoked", "changes_v";
      "changes" := array_to_string("changes_v", E'\n');
      RETURN NEXT;
    END;
  $$;

COMMENT ON FUNCTION public.member_sync(JSONB) IS 'Applies the member list [{"identification", "lo", "eligible", "email", "regions"}, ...] of member-sync.php (README, "Member sync") to the rows with an identification ''mv:<pseudonym>'' (never deletes members or privileges); returns the counts';

REVOKE ALL ON FUNCTION public.member_sync(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.member_sync_units() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.member_sync_owned(TEXT) FROM PUBLIC;
REVOKE ALL ON TABLE public.member_sync_mail, public.member_sync_mail_due FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_sync(JSONB) TO lqfb_membersync;

COMMIT;

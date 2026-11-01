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
--   public.member_sync(jsonb)      SECURITY DEFINER; the only object the role
--                                  lqfb_membersync may use (EXECUTE).
--   public.member_sync_units()     the maps, baked in at apply time.
--   public.member_sync_owned(text) the ownership predicate: the sync only
--                                  ever touches rows whose identification
--                                  is 'mv:<Admidio user id>'.
--   public.member_sync_mail        the mail queue for lf_member_sync_mail
--                                  (one pending mail per member).
--   public.member_sync_mail_due    queued mails whose state still fits.
--   public.member_sync_mail_stale  the other queue rows (dropped unsent).
-- Replaces delete_private_data() and the member search trigger by the
-- versions of core.sql (identification neither exported nor searchable).
--
-- The role lqfb_membersync must exist (created by the deployment).

BEGIN;

SET LOCAL search_path = pg_catalog, public, pg_temp;

-- Only the applying role (or a role it belongs to) may own schema public,
-- and PUBLIC must not create in it: the functions below resolve names in it.
DO $$
  BEGIN
    IF NOT EXISTS (
      SELECT NULL FROM pg_catalog.pg_namespace
      WHERE "nspname" = 'public'
      AND pg_catalog.pg_has_role(current_user, "nspowner", 'MEMBER')
    ) THEN
      RAISE EXCEPTION 'member_sync.sql: schema public is not owned by %', current_user;
    END IF;
    IF pg_catalog.has_schema_privilege('public', 'public', 'CREATE') THEN
      RAISE EXCEPTION 'member_sync.sql: PUBLIC has CREATE on schema public';
    END IF;
  END;
$$;

-- The maps (psql variables are not substituted inside dollar quotes, so the
-- function is generated with format()).
SELECT pg_catalog.format($f$
CREATE OR REPLACE FUNCTION public.member_sync_units()
  RETURNS JSONB
  LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public, pg_temp
  AS $b$ SELECT pg_catalog.jsonb_build_object('lo', %L::jsonb, 'regions', %L::jsonb, 'managed', %L::jsonb) $b$
$f$, :'lo_map', :'region_map', :'managed_units') \gexec

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
  AS $$ SELECT "identification_p" OPERATOR(pg_catalog.~) '^mv:[1-9][0-9]*$' $$;

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

CREATE OR REPLACE VIEW public.member_sync_mail_stale AS
  SELECT "member_id", "kind", "created" FROM public.member_sync_mail
  WHERE "member_id" NOT IN (SELECT "member_id" FROM public.member_sync_mail_due);

COMMENT ON VIEW public.member_sync_mail_due   IS 'Queued mails to send: owned rows with an address whose state still fits the kind (invite: never activated and not locked; locked: locked; unlocked: not locked)';
COMMENT ON VIEW public.member_sync_mail_stale IS 'Queued mails that no longer fit; the mail worker deletes them unsent';

CREATE OR REPLACE FUNCTION public.member_sync("members_p" JSONB)
  RETURNS TABLE (
    "created"            INT4,
    "unlocked"           INT4,
    "locked"             INT4,
    "deleted"            INT4,
    "anonymised"         INT4,
    "privileges_granted" INT4,
    "privileges_revoked" INT4,
    "email_updated"      INT4,
    "no_email"           INT4 )
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
      "member_id_v"   INT4;
      "anonymise_v"   BOOLEAN;
      "count_v"       INT4;
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
            <> ARRAY['eligible', 'email', 'id', 'lo', 'regions']
        THEN
          RAISE EXCEPTION 'member_sync: entry %: not an object with exactly id, lo, eligible, email, regions', "position_v"
            USING ERRCODE = 'invalid_parameter_value';
        END IF;
        IF
          jsonb_typeof("entry_v"->'id') <> 'number' OR
          ("entry_v"->>'id') !~ '^[1-9][0-9]{0,9}$' OR
          ("entry_v"->>'id')::int8 > 2147483647
        THEN
          RAISE EXCEPTION 'member_sync: entry %: bad id', "position_v"
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
        array_agg('mv:' || "id"),
        coalesce(array_agg('mv:' || "id") FILTER (WHERE "eligible"), '{}'),
        count(DISTINCT "id")
        INTO "listed_v", "eligible_v", "count_v"
        FROM jsonb_to_recordset("members_p") AS "entry" ("id" INT4, "eligible" BOOLEAN);
      IF "count_v" <> cardinality("listed_v") THEN
        RAISE EXCEPTION 'member_sync: duplicate id'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;
      SELECT array_agg("unit"::text::int4) INTO "managed_v"
        FROM jsonb_array_elements("units_v"->'managed') AS "unit";
      -- Eligible without a row: a new account (with an address) and an invite.
      WITH "new" AS (
        INSERT INTO public.member ("identification", "notify_email")
        SELECT 'mv:' || "entry"."id", "entry"."email"
        FROM jsonb_to_recordset("members_p") AS "entry" ("id" INT4, "eligible" BOOLEAN, "email" TEXT)
        WHERE "entry"."eligible" AND "entry"."email" NOTNULL
        AND NOT EXISTS (SELECT NULL FROM public.member WHERE "identification" = 'mv:' || "entry"."id")
        RETURNING "id"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", 'invite' FROM "new"
      )
      SELECT count(*) INTO "created" FROM "new";
      SELECT count(*) INTO "no_email"
        FROM jsonb_to_recordset("members_p") AS "entry" ("id" INT4, "eligible" BOOLEAN, "email" TEXT)
        WHERE "entry"."eligible" AND "entry"."email" ISNULL
        AND NOT EXISTS (SELECT NULL FROM public.member WHERE "identification" = 'mv:' || "entry"."id");
      -- Eligible and locked: unlock; the "unlocked" mail for activated active
      -- members, the invite again for never activated ones without a code.
      WITH "unlocked" AS (
        UPDATE public.member SET "locked" = FALSE
        WHERE public.member_sync_owned("identification")
        AND "identification" = ANY ("eligible_v")
        AND "locked"
        RETURNING "id", "activated", "active", "invite_code"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", CASE WHEN "activated" NOTNULL THEN 'unlocked' ELSE 'invite' END
        FROM "unlocked"
        WHERE ("activated" NOTNULL AND "active") OR ("activated" ISNULL AND "invite_code" ISNULL)
        ON CONFLICT ("member_id") DO UPDATE SET "kind" = EXCLUDED."kind", "created" = EXCLUDED."created"
      )
      SELECT count(*) INTO "unlocked" FROM "unlocked";
      -- Eligible, not active, another address: take it, drop pending
      -- confirmations and resets; invite again if never activated.
      WITH "updated" AS (
        UPDATE public.member SET
          "notify_email"                 = "entry"."email",
          "notify_email_unconfirmed"     = NULL,
          "notify_email_secret"          = NULL,
          "notify_email_secret_expiry"   = NULL,
          "password_reset_secret"        = NULL,
          "password_reset_secret_expiry" = NULL
        FROM jsonb_to_recordset("members_p") AS "entry" ("id" INT4, "eligible" BOOLEAN, "email" TEXT)
        WHERE public.member_sync_owned("member"."identification")
        AND "member"."identification" = 'mv:' || "entry"."id"
        AND "entry"."eligible" AND "entry"."email" NOTNULL
        AND NOT "member"."active"
        AND "member"."notify_email" IS DISTINCT FROM "entry"."email"
        RETURNING "member"."id", "member"."activated"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", 'invite' FROM "updated" WHERE "activated" ISNULL
        ON CONFLICT ("member_id") DO UPDATE SET "kind" = EXCLUDED."kind", "created" = EXCLUDED."created"
      )
      SELECT count(*) INTO "email_updated" FROM "updated";
      -- Listed and not eligible, or a departed admin: locked, reconciled on
      -- every run; the "locked" mail on the transition only.
      WITH "locked" AS (
        UPDATE public.member SET "locked" = TRUE
        WHERE public.member_sync_owned("identification")
        AND NOT "identification" = ANY ("eligible_v")
        AND ("identification" = ANY ("listed_v") OR "admin")
        AND NOT "locked"
        RETURNING "id"
      ), "queued" AS (
        INSERT INTO public.member_sync_mail ("member_id", "kind")
        SELECT "id", 'locked' FROM "locked"
        ON CONFLICT ("member_id") DO UPDATE SET "kind" = EXCLUDED."kind", "created" = EXCLUDED."created"
      )
      SELECT count(*) INTO "locked" FROM "locked";
      DELETE FROM public.session USING public.member
        WHERE "session"."member_id" = "member"."id"
        AND public.member_sync_owned("member"."identification")
        AND NOT "member"."identification" = ANY ("eligible_v")
        AND ("member"."identification" = ANY ("listed_v") OR "member"."admin");
      -- Privileges: unit 1, the LO unit and the region units of eligible
      -- members; the sync owns voting_right and initiative_right on the
      -- managed units of listed members and admins.
      SELECT array_agg("member"."id"), array_agg("unit"."id")
        INTO "want_member_v", "want_unit_v"
        FROM jsonb_to_recordset("members_p") AS "entry" ("id" INT4, "lo" INT4, "eligible" BOOLEAN, "regions" JSONB)
        JOIN public.member ON "member"."identification" = 'mv:' || "entry"."id"
        CROSS JOIN LATERAL (
          SELECT 1
          UNION SELECT ("units_v"->'lo'->>"entry"."lo"::text)::int4 WHERE "entry"."lo" NOTNULL
          UNION SELECT ("units_v"->'regions'->>"region")::int4
            FROM jsonb_array_elements_text("entry"."regions") AS "region"
        ) AS "unit" ("id")
        WHERE "entry"."eligible";
      INSERT INTO public.privilege ("unit_id", "member_id", "voting_right", "initiative_right")
        SELECT "unit_id", "member_id", TRUE, TRUE
        FROM unnest("want_member_v", "want_unit_v") AS "wanted" ("member_id", "unit_id")
        ON CONFLICT ("unit_id", "member_id") DO UPDATE SET "voting_right" = TRUE, "initiative_right" = TRUE
        WHERE NOT ("privilege"."voting_right" AND "privilege"."initiative_right");
      GET DIAGNOSTICS "privileges_granted" = ROW_COUNT;
      -- Unwanted: the row is deleted, unless it carries a manager or polling
      -- right; then only the owned flags are cleared.
      WITH "unwanted" AS (
        SELECT "privilege"."unit_id", "privilege"."member_id",
          "privilege"."admin_manager" OR "privilege"."unit_manager" OR "privilege"."area_manager" OR
          "privilege"."member_manager" OR "privilege"."polling_right" AS "keep"
        FROM public.privilege
        JOIN public.member ON "member"."id" = "privilege"."member_id"
        WHERE public.member_sync_owned("member"."identification")
        AND ("member"."identification" = ANY ("listed_v") OR "member"."admin")
        AND "privilege"."unit_id" = ANY ("managed_v")
        AND ("privilege"."voting_right" OR "privilege"."initiative_right" OR NOT (
          "privilege"."admin_manager" OR "privilege"."unit_manager" OR "privilege"."area_manager" OR
          "privilege"."member_manager" OR "privilege"."polling_right"))
        AND ("privilege"."member_id", "privilege"."unit_id") NOT IN (
          SELECT * FROM unnest("want_member_v", "want_unit_v"))
      ), "deleted" AS (
        DELETE FROM public.privilege USING "unwanted"
        WHERE "privilege"."unit_id" = "unwanted"."unit_id"
        AND "privilege"."member_id" = "unwanted"."member_id"
        AND NOT "unwanted"."keep"
        RETURNING 1
      ), "cleared" AS (
        UPDATE public.privilege SET "voting_right" = FALSE, "initiative_right" = FALSE
        FROM "unwanted"
        WHERE "privilege"."unit_id" = "unwanted"."unit_id"
        AND "privilege"."member_id" = "unwanted"."member_id"
        AND "unwanted"."keep"
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM "deleted") + (SELECT count(*) FROM "cleared")
        INTO "privileges_revoked";
      -- Departed (not listed, not admin): deleted when nothing that matters
      -- references the row (ON DELETE CASCADE would silently drop initiators,
      -- incoming delegations and support), otherwise anonymised.
      "deleted" := 0;
      "anonymised" := 0;
      FOR "member_id_v" IN
        SELECT "id" FROM public.member
        WHERE public.member_sync_owned("identification")
        AND NOT "identification" = ANY ("listed_v")
        AND NOT "admin"
        ORDER BY "id"
        FOR UPDATE
      LOOP
        "anonymise_v" := (
          EXISTS (SELECT NULL FROM public.initiator  WHERE "member_id"  = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.delegation WHERE "trustee_id" = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.interest   WHERE "member_id"  = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.supporter  WHERE "member_id"  = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.opinion    WHERE "member_id"  = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.direct_voter WHERE "member_id" = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.suggestion WHERE "author_id"  = "member_id_v") OR
          EXISTS (SELECT NULL FROM public.argument   WHERE "author_id"  = "member_id_v")
        );
        IF NOT "anonymise_v" THEN
          BEGIN
            -- Deferred triggers fire here, inside the block, not at COMMIT.
            SET CONSTRAINTS ALL IMMEDIATE;
            DELETE FROM public.member WHERE "id" = "member_id_v";
            "deleted" := "deleted" + 1;
          EXCEPTION WHEN OTHERS THEN
            "anonymise_v" := TRUE;
          END;
        END IF;
        IF "anonymise_v" THEN
          PERFORM public.delete_member("member_id_v");
          DELETE FROM public.privilege WHERE "member_id" = "member_id_v";
          DELETE FROM public.member_sync_mail WHERE "member_id" = "member_id_v";
          UPDATE public.member SET
            "invite_code"        = NULL,
            "invite_code_expiry" = NULL,
            "identification"     = NULL,
            "admin_comment"      = 'Austritt',
            "locked"             = TRUE
            WHERE "id" = "member_id_v";
          "anonymised" := "anonymised" + 1;
        END IF;
      END LOOP;
      RETURN NEXT;
    END;
  $$;

COMMENT ON FUNCTION public.member_sync(JSONB) IS 'Applies the Admidio member list [{"id", "lo", "eligible", "email", "regions"}, ...] (README, "Member sync") to the rows with identification ''mv:<id>''; returns the counts';

REVOKE ALL ON FUNCTION public.member_sync(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.member_sync_units() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.member_sync_owned(TEXT) FROM PUBLIC;
REVOKE ALL ON TABLE public.member_sync_mail, public.member_sync_mail_due, public.member_sync_mail_stale FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_sync(JSONB) TO lqfb_membersync;

-- core.sql: the identification is not searchable. An existing database gets
-- the trigger without it, and its search data refreshed, once.
DO $$
  BEGIN
    IF EXISTS (
      SELECT NULL FROM pg_catalog.pg_trigger
      WHERE "tgrelid" = 'public.member'::regclass
      AND "tgname" = 'update_text_search_data'
      AND pg_catalog.pg_get_triggerdef("oid") LIKE '%identification%'
    ) THEN
      DROP TRIGGER "update_text_search_data" ON public.member;
      CREATE TRIGGER "update_text_search_data"
        BEFORE INSERT OR UPDATE ON "member"
        FOR EACH ROW EXECUTE PROCEDURE
        tsvector_update_trigger('text_search_data', 'pg_catalog.simple',
          "name", "organizational_unit", "internal_posts",
          "realname", "external_memberships", "external_posts", "statement" );
      UPDATE public.member SET "text_search_data" = NULL
        WHERE "identification" NOTNULL;
    END IF;
  END;
$$;

-- core.sql: the export clears the identification and the mail queue.
CREATE OR REPLACE FUNCTION public."delete_private_data"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      UPDATE "member" SET
        "invite_code"                  = NULL,
        "invite_code_expiry"           = NULL,
        "admin_comment"                = NULL,
        "last_login"                   = NULL,
        "login"                        = NULL,
        "password"                     = NULL,
        "lang"                         = NULL,
        "notify_email"                 = NULL,
        "notify_email_unconfirmed"     = NULL,
        "notify_email_secret"          = NULL,
        "notify_email_secret_expiry"   = NULL,
        "notify_email_lock_expiry"     = NULL,
        "notify_level"                 = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
        "identification"               = NULL,
        "organizational_unit"          = NULL,
        "internal_posts"               = NULL,
        "realname"                     = NULL,
        "birthday"                     = NULL,
        "address"                      = NULL,
        "email"                        = NULL,
        "xmpp_address"                 = NULL,
        "website"                      = NULL,
        "phone"                        = NULL,
        "mobile_phone"                 = NULL,
        "profession"                   = NULL,
        "external_memberships"         = NULL,
        "external_posts"               = NULL,
        "formatting_engine"            = NULL,
        "statement"                    = NULL;
      -- "text_search_data" is updated by triggers
      DELETE FROM "setting";
      DELETE FROM "setting_map";
      DELETE FROM "member_relation_setting";
      DELETE FROM "member_image";
      DELETE FROM "contact";
      DELETE FROM "ignored_member";
      DELETE FROM "session";
      DELETE FROM "area_setting";
      DELETE FROM "issue_setting";
      DELETE FROM "ignored_initiative";
      DELETE FROM "initiative_setting";
      DELETE FROM "suggestion_setting";
      DELETE FROM "non_voter";
      DELETE FROM "direct_voter" USING "issue"
        WHERE "direct_voter"."issue_id" = "issue"."id"
        AND "issue"."closed" ISNULL;
      -- the mail queue of member_sync.sql, if applied
      IF to_regclass('member_sync_mail') NOTNULL THEN
        DELETE FROM "member_sync_mail";
      END IF;
      RETURN;
    END;
  $$;

COMMIT;

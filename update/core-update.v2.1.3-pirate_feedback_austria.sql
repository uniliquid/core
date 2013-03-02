COMMENT ON FUNCTION "highlight"
   ( "body_p"       TEXT,
     "query_text_p" TEXT )
  IS 'For a given user query this function encapsulates all matches with asterisks. Asterisks and backslashes being already present are preceeded with one extra backslash.';
 
 
DROP TYPE "notify_level";
 
 CREATE TYPE "notify_level" AS ENUM
  ('expert', 'none', 'voting', 'verification', 'discussion', 'all');
 
COMMENT ON TYPE "notify_level" IS 'Level of notification: ''expert'' = detailed settings in table ''notify'', ''none'' = no notifications, ''voting'' = notifications about finished issues and issues in voting, ''verification'' = notifications about finished issues, issues in voting and verification phase, ''discussion'' = notifications about everything except issues in admission phase, ''all'' = notifications about everything';
 
 
 CREATE TABLE "member" (
@@ -173,7 +173,41 @@ COMMENT ON COLUMN "member"."formatting_engine"    IS 'Allows different formattin
 COMMENT ON COLUMN "member"."statement"            IS 'Freely chosen text of the member for his/her profile';
 
DROP TYPE "notify_interest";
 
CREATE TYPE "notify_interest" AS ENUM
  ('all', 'my_units', 'my_areas', 'interested', 'potentially', 'supported', 'initiated', 'voted');


CREATE TABLE "notify" (
        "member_id"                                          INT4    NOT NULL REFERENCES "member" ("id")
                                                             ON DELETE CASCADE ON UPDATE CASCADE,
        "interest"                                           "notify_interest" NOT NULL,
        "initiative_created_in_new_issue"                    BOOLEAN NOT NULL DEFAULT FALSE,
        "admission__initiative_created_in_existing_issue"    BOOLEAN NOT NULL DEFAULT FALSE,
        "admission__new_draft_created"                       BOOLEAN NOT NULL DEFAULT FALSE,
        "admission__suggestion_created"                      BOOLEAN NOT NULL DEFAULT FALSE,
        "admission__initiative_revoked"                      BOOLEAN NOT NULL DEFAULT FALSE,
        "canceled_revoked_before_accepted"                   BOOLEAN NOT NULL DEFAULT FALSE,
        "canceled_issue_not_accepted"                        BOOLEAN NOT NULL DEFAULT FALSE,
        "discussion"                                         BOOLEAN NOT NULL DEFAULT FALSE,
        "discussion__initiative_created_in_existing_issue"   BOOLEAN NOT NULL DEFAULT FALSE,
        "discussion__new_draft_created"                      BOOLEAN NOT NULL DEFAULT FALSE,
        "discussion__suggestion_created"                     BOOLEAN NOT NULL DEFAULT FALSE,
        "discussion__argument_created"                       BOOLEAN NOT NULL DEFAULT FALSE,
        "discussion__initiative_revoked"                     BOOLEAN NOT NULL DEFAULT FALSE,
        "canceled_after_revocation_during_discussion"        BOOLEAN NOT NULL DEFAULT FALSE,
        "verification"                                       BOOLEAN NOT NULL DEFAULT FALSE,
        "verification__initiative_created_in_existing_issue" BOOLEAN NOT NULL DEFAULT FALSE,
        "verification__argument_created"                     BOOLEAN NOT NULL DEFAULT FALSE,
        "verification__initiative_revoked"                   BOOLEAN NOT NULL DEFAULT FALSE,
        "canceled_after_revocation_during_verification"      BOOLEAN NOT NULL DEFAULT FALSE,
        "canceled_no_initiative_admitted"                    BOOLEAN NOT NULL DEFAULT FALSE,
        "voting"                                             BOOLEAN NOT NULL DEFAULT FALSE,
        "finished_with_winner"                               BOOLEAN NOT NULL DEFAULT FALSE,
        "finished_without_winner"                            BOOLEAN NOT NULL DEFAULT FALSE );
CREATE UNIQUE INDEX notify_member_interest ON notify USING btree (member_id, interest);

COMMENT ON TABLE "notify" IS 'Member settings in export mode which notifications are to be sent; No entry if the member does not use the expert mode';


ALTER TABLE "issue" ADD COLUMN "direct_voter_count"    INT4;

COMMENT ON COLUMN "issue"."voter_count"             IS 'Total number of direct voters';
 
 
ALTER TABLE "initiative" ADD COLUMN "positive_direct_votes" INT4;
ALTER TABLE "initiative" ADD COLUMN "negative_direct_votes" INT4;
ALTER TABLE "initiative" DROP CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results";
ALTER TABLE "initiative" ADD CONSTRAINT         CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results" CHECK (
          ( "admitted" NOTNULL AND "admitted" = TRUE ) OR
          ( "positive_votes" ISNULL AND "negative_votes" ISNULL AND
            "positive_direct_votes" ISNULL AND "negative_direct_votes" ISNULL AND
            "direct_majority" ISNULL AND "indirect_majority" ISNULL AND
            "schulze_rank" ISNULL AND
            "better_than_status_quo" ISNULL AND "worse_than_status_quo" ISNULL AND
            "reverse_beat_path" ISNULL AND "multistage_majority" ISNULL AND
            "eligible" ISNULL AND "winner" ISNULL AND "rank" ISNULL ) );

COMMENT ON COLUMN "initiative"."positive_direct_votes"  IS 'Calculated from table "direct_voter"';
COMMENT ON COLUMN "initiative"."negative_direct_votes"  IS 'Calculated from table "direct_voter"';

ALTER TABLE "battle" ADD COLUMN "direct_count"          INT4;

COMMENT ON TABLE "rendered_suggestion" IS 'This table may be used by frontends to cache "rendered" suggestions (e.g. HTML output generated from wiki text)';
 

CREATE TYPE side AS ENUM ('pro', 'contra');

CREATE TABLE "argument" (
        UNIQUE ("initiative_id", "id"),  -- index needed for foreign-key on table "rating"
        "initiative_id"         INT4            REFERENCES "initiative" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "id"                    SERIAL8         PRIMARY KEY,
        --"parent_id"             SERIAL8,
        "created"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "author_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "name"                  TEXT            NOT NULL,
        "formatting_engine"     TEXT,
        "content"               TEXT            NOT NULL DEFAULT '',
        "text_search_data"      TSVECTOR,
        "side"                  side            NOT NULL,
        "minus_count"           INT4            NOT NULL DEFAULT 0,
        "plus_count"            INT4            NOT NULL DEFAULT 0 );
CREATE INDEX "argument_created_idx" ON "argument" ("created");
CREATE INDEX "argument_author_id_created_idx" ON "argument" ("author_id", "created");
CREATE INDEX "argument_text_search_data_idx" ON "argument" USING gin ("text_search_data");
CREATE TRIGGER "update_text_search_data"
  BEFORE INSERT OR UPDATE ON "argument"
  FOR EACH ROW EXECUTE PROCEDURE
  tsvector_update_trigger('text_search_data', 'pg_catalog.simple',
    "name", "content");

COMMENT ON TABLE "argument" IS 'Arguments to initiatives';

COMMENT ON COLUMN "argument"."minus_count" IS 'Number of negative ratings; delegations are not considered';
COMMENT ON COLUMN "argument"."plus_count"  IS 'Number of positive ratings; delegations are not considered';


CREATE TABLE "rendered_argument" (
        PRIMARY KEY ("argument_id", "format"),
        "argument_id"           INT8            NOT NULL REFERENCES "argument" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "format"                TEXT,
        "content"               TEXT            NOT NULL );

COMMENT ON TABLE "rendered_argument" IS 'This table may be used by frontends to cache "rendered" arguments (e.g. HTML output generated from wiki text)';
 
CREATE TABLE "rating" (
        "issue_id"              INT4            NOT NULL,
        "initiative_id"         INT4            NOT NULL,
        PRIMARY KEY ("argument_id", "member_id"),
        "argument_id"           INT8            REFERENCES "argument" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE RESTRICT ON UPDATE CASCADE,
        "negative"              BOOLEAN         NOT NULL DEFAULT FALSE,
        FOREIGN KEY ("issue_id", "member_id") REFERENCES "interest" ("issue_id", "member_id") ON DELETE CASCADE ON UPDATE CASCADE );
CREATE INDEX "rating_member_id_argument_id_idx" ON "rating" ("member_id", "initiative_id");

COMMENT ON TABLE "rating" IS 'Rating of arguments; Frontends must ensure that ratings are not created modified or deleted when related to fully_frozen or closed issues.';

 
CREATE TABLE "issue_comment" (
        PRIMARY KEY ("issue_id", "member_id"),
        "issue_id"              INT4            REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "member_id"             INT4            REFERENCES "member" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "changed"               TIMESTAMPTZ     NOT NULL DEFAULT now(),
        "formatting_engine"     TEXT,
        "content"               TEXT            NOT NULL,
        "text_search_data"      TSVECTOR );
CREATE INDEX "issue_comment_member_id_idx" ON "issue_comment" ("member_id");
CREATE INDEX "issue_comment_text_search_data_idx" ON "issue_comment" USING gin ("text_search_data");
CREATE TRIGGER "update_text_search_data"
  BEFORE INSERT OR UPDATE ON "issue_comment"
  FOR EACH ROW EXECUTE PROCEDURE
  tsvector_update_trigger('text_search_data', 'pg_catalog.simple', "content");

COMMENT ON TABLE "issue_comment" IS 'Place to store free comments of members related to issues';

COMMENT ON COLUMN "issue_comment"."changed" IS 'Time the comment was last changed';


CREATE TABLE "rendered_issue_comment" (
        PRIMARY KEY ("issue_id", "member_id", "format"),
        FOREIGN KEY ("issue_id", "member_id")
          REFERENCES "issue_comment" ("issue_id", "member_id")
          ON DELETE CASCADE ON UPDATE CASCADE,
        "issue_id"              INT4,
        "member_id"             INT4,
        "format"                TEXT,
        "content"               TEXT            NOT NULL );

COMMENT ON TABLE "rendered_issue_comment" IS 'This table may be used by frontends to cache "rendered" issue comments (e.g. HTML output generated from wiki text)';

DROP TYPE "event_type";
 CREATE TYPE "event_type" AS ENUM (
         'issue_state_changed',
         'initiative_created_in_new_issue',
         'initiative_created_in_existing_issue',
         'initiative_revoked',
         'new_draft_created',
         'suggestion_created',
         'argument_created');

ALTER TABLE "event" ADD COLUMN "argument_id"           INT8;

ALTER TABLE "event" ADD FOREIGN KEY ("initiative_id", "argument_id")
          REFERENCES "argument" ("initiative_id", "id")
          ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "event" DROP CONSTRAINT "null_constraints_for_issue_state_changed";

ALTER TABLE "event" ADD CONSTRAINT "null_constraints_for_issue_state_changed" CHECK (
          "event" != 'issue_state_changed' OR (
            "member_id"     ISNULL  AND
            "issue_id"      NOTNULL AND
            "state"         NOTNULL AND
            "initiative_id" ISNULL  AND
            "draft_id"      ISNULL  AND
            "suggestion_id" ISNULL  AND
            "argument_id"   ISNULL  ));
            
ALTER TABLE "event" ADD CONSTRAINT "null_constraints_for_argument_creation" CHECK (
          "event" != 'argument_created' OR (
            "member_id"     NOTNULL AND
            "issue_id"      NOTNULL AND
            "state"         NOTNULL AND
            "initiative_id" NOTNULL AND
            "draft_id"      ISNULL  AND
            "argument_id"   NOTNULL )) );
 
CREATE FUNCTION "write_event_argument_created_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_row" "initiative"%ROWTYPE;
      "issue_row"      "issue"%ROWTYPE;
    BEGIN
      SELECT * INTO "initiative_row" FROM "initiative"
        WHERE "id" = NEW."initiative_id";
      SELECT * INTO "issue_row" FROM "issue"
        WHERE "id" = "initiative_row"."issue_id";
      INSERT INTO "event" (
          "event", "member_id",
          "issue_id", "state", "initiative_id", "argument_id"
        ) VALUES (
          'argument_created',
          NEW."author_id",
          "initiative_row"."issue_id",
          "issue_row"."state",
          "initiative_row"."id",
          NEW."id" );
      RETURN NULL;
    END;
  $$;

CREATE TRIGGER "write_event_argument_created"
  AFTER INSERT ON "argument" FOR EACH ROW EXECUTE PROCEDURE
  "write_event_argument_created_trigger"();

COMMENT ON FUNCTION "write_event_argument_created_trigger"()      IS 'Implementation of trigger "write_event_argument_created" on table "issue"';
COMMENT ON TRIGGER "write_event_argument_created" ON "argument" IS 'Create entry in "event" table on argument creation';

CREATE TRIGGER "autocreate_interest_rating" BEFORE INSERT ON "rating"
  FOR EACH ROW EXECUTE PROCEDURE "autocreate_interest_trigger"();

COMMENT ON TRIGGER "autocreate_interest_rating" ON "rating" IS 'Rating an argument implies interest in the issue, thus automatically creates an entry in the "interest" table';

DROP FUNCTION "autocreate_supporter_trigger"();

DROP VIEW "battle_view";
CREATE VIEW "battle_view" AS
  SELECT
    "issue"."id" AS "issue_id",
    "winning_initiative"."id" AS "winning_initiative_id",
    "losing_initiative"."id" AS "losing_initiative_id",
    sum(
      CASE WHEN
        coalesce("better_vote"."grade", 0) >
        coalesce("worse_vote"."grade", 0)
      THEN "direct_voter"."weight" ELSE 0 END
    ) AS "count",
    sum(
      CASE WHEN
        coalesce("better_vote"."grade", 0) >
        coalesce("worse_vote"."grade", 0)
      THEN 1 ELSE 0 END
    ) AS "direct_count"
  FROM "issue"
  LEFT JOIN "direct_voter"
  ON "issue"."id" = "direct_voter"."issue_id"
  JOIN "battle_participant" AS "winning_initiative"
    ON "issue"."id" = "winning_initiative"."issue_id"
  JOIN "battle_participant" AS "losing_initiative"
    ON "issue"."id" = "losing_initiative"."issue_id"
  LEFT JOIN "vote" AS "better_vote"
    ON "direct_voter"."member_id" = "better_vote"."member_id"
    AND "winning_initiative"."id" = "better_vote"."initiative_id"
  LEFT JOIN "vote" AS "worse_vote"
    ON "direct_voter"."member_id" = "worse_vote"."member_id"
    AND "losing_initiative"."id" = "worse_vote"."initiative_id"
  WHERE "issue"."closed" NOTNULL
  AND "issue"."cleaned" ISNULL
  AND (
    "winning_initiative"."id" != "losing_initiative"."id" OR
    ( ("winning_initiative"."id" NOTNULL AND "losing_initiative"."id" ISNULL) OR
      ("winning_initiative"."id" ISNULL AND "losing_initiative"."id" NOTNULL) ) )
  GROUP BY
    "issue"."id",
    "winning_initiative"."id",
    "losing_initiative"."id";

COMMENT ON VIEW "battle_view" IS 'Number of members preferring one initiative (or status-quo) to another initiative (or status-quo); Used to fill "battle" table';

DROP VIEW "event_seen_by_member";

CREATE VIEW "event_seen_by_member" AS
  SELECT
    "member"."id" AS "seen_by_member_id",
    CASE WHEN "event"."state" IN (
      'voting',
      'finished_without_winner',
      'finished_with_winner'
    ) THEN
      'voting'::"notify_level"
    ELSE
      CASE WHEN "event"."state" IN (
        'verification',
        'canceled_after_revocation_during_verification',
        'canceled_no_initiative_admitted'
      ) THEN
        'verification'::"notify_level"
      ELSE
        CASE WHEN "event"."state" IN (
          'discussion',
          'canceled_after_revocation_during_discussion'
        ) THEN
          'discussion'::"notify_level"
        ELSE
          'all'::"notify_level"
        END
      END
    END AS "notify_level",
    "event".*
  FROM "member" CROSS JOIN "event"
  LEFT JOIN "issue"
    ON "event"."issue_id" = "issue"."id"
  LEFT JOIN "area"
    ON "issue"."area_id" = "area"."id"
  LEFT JOIN "privilege"
    ON "member"."id" = "privilege"."member_id"
    AND "privilege"."unit_id" = "area"."unit_id"
    AND "privilege"."voting_right" = TRUE
  LEFT JOIN "membership"
    ON "member"."id" = "membership"."member_id"
    AND "issue"."area_id" = "membership"."area_id"
  LEFT JOIN "interest"
    ON "member"."id" = "interest"."member_id"
    AND "event"."issue_id" = "interest"."issue_id"
  LEFT JOIN "supporter"
    ON "member"."id" = "supporter"."member_id"
    AND "event"."initiative_id" = "supporter"."initiative_id"
  LEFT JOIN "critical_opinion"
    ON "member"."id" = "critical_opinion"."member_id"
    AND "event"."initiative_id" = "critical_opinion"."initiative_id"
  LEFT JOIN "initiator"
    ON "member"."id" = "initiator"."member_id"
    AND "event"."initiative_id" = "initiator"."initiative_id"
    AND "initiator"."accepted" = TRUE
  LEFT JOIN "direct_voter"
    ON "member"."id" = "direct_voter"."member_id"
    AND "issue"."id" = "direct_voter"."issue_id"
    AND "issue"."closed" NOTNULL
  LEFT JOIN "ignored_member"
    ON "member"."id" = "ignored_member"."member_id"
    AND "event"."member_id" = "ignored_member"."other_member_id"
  LEFT JOIN "ignored_initiative"
    ON "member"."id" = "ignored_initiative"."member_id"
    AND "event"."initiative_id" = "ignored_initiative"."initiative_id"
  FULL JOIN "notify"
    ON "member"."id" = "notify"."member_id"
  WHERE
    now() - "event"."occurrence" BETWEEN '-3 days'::interval AND '3 days'::interval AND (
    -- standard mode
    (
      (
        ( "member"."notify_level" >= 'all' ) OR
        ( "member"."notify_level" >= 'voting' AND
          "event"."state" IN (
            'voting',
            'finished_without_winner',
            'finished_with_winner' ) ) OR
        ( "member"."notify_level" >= 'verification' AND
          "event"."state" IN (
            'verification',
            'canceled_after_revocation_during_verification',
            'canceled_no_initiative_admitted' ) ) OR
        ( "member"."notify_level" >= 'discussion' AND
          "event"."state" IN (
            'discussion',
            'canceled_after_revocation_during_discussion' ) )
      ) AND (
    "supporter"."member_id" NOTNULL OR
    "interest"."member_id" NOTNULL OR
    ( "membership"."member_id" NOTNULL AND
      "event"."event" IN (
        'issue_state_changed',
        'initiative_created_in_new_issue',
        'initiative_created_in_existing_issue',
            'initiative_revoked' ) )
      )
    )
    -- expert mode
    OR (
      "member"."notify_level" = 'expert' AND (
        "notify"."interest" = 'all' OR
        ("notify"."interest" = 'my_units'    AND "privilege"."member_id" NOTNULL) OR
        ("notify"."interest" = 'my_areas'    AND "membership"."member_id" NOTNULL) OR
        ("notify"."interest" = 'interested'  AND "interest"."member_id" NOTNULL) OR
        ("notify"."interest" = 'potentially' AND "supporter"."member_id" NOTNULL AND "critical_opinion"."member_id" NOTNULL) OR
        ("notify"."interest" = 'supported'   AND "supporter"."member_id" NOTNULL AND "critical_opinion"."member_id" ISNULL) OR
        ("notify"."interest" = 'initiated'   AND "initiator"."member_id" NOTNULL) OR
        ("notify"."interest" = 'voted'       AND "direct_voter"."member_id" NOTNULL)
      ) AND (
        -- admission / new
        ("notify"."initiative_created_in_new_issue" AND
          "event"."event" = 'initiative_created_in_new_issue') OR
        ("notify"."admission__initiative_created_in_existing_issue" AND
          "event"."event" = 'initiative_created_in_existing_issue' AND "event"."state" = 'admission') OR
        ("notify"."admission__new_draft_created" AND
          "event"."event" = 'new_draft_created'                    AND "event"."state" = 'admission') OR
        ("notify"."admission__suggestion_created" AND
          "event"."event" = 'suggestion_created'                   AND "event"."state" = 'admission') OR
        ("notify"."admission__initiative_revoked" AND
          "event"."event" = 'initiative_revoked'                   AND "event"."state" = 'admission') OR
        ("notify"."canceled_revoked_before_accepted" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'canceled_revoked_before_accepted') OR
        ("notify"."canceled_issue_not_accepted" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'canceled_issue_not_accepted') OR
        -- discussion
        ("notify"."discussion" AND
          "event"."event" = 'issue_state_changed'                  AND "event"."state" = 'discussion') OR
        ("notify"."discussion__initiative_created_in_existing_issue" AND
          "event"."event" = 'initiative_created_in_existing_issue' AND "event"."state" = 'discussion') OR
        ("notify"."discussion__new_draft_created" AND
          "event"."event" = 'new_draft_created'                    AND "event"."state" = 'discussion') OR
        ("notify"."discussion__suggestion_created" AND
          "event"."event" = 'suggestion_created'                   AND "event"."state" = 'discussion') OR
        ("notify"."discussion__argument_created" AND
          "event"."event" = 'argument_created'                     AND "event"."state" = 'discussion') OR
        ("notify"."discussion__initiative_revoked" AND
          "event"."event" = 'initiative_revoked'                   AND "event"."state" = 'discussion') OR
        ("notify"."canceled_after_revocation_during_discussion" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'canceled_after_revocation_during_discussion') OR
        -- verification
        ("notify"."verification" AND
          "event"."event" = 'issue_state_changed'                  AND "event"."state" = 'verification') OR
        ("notify"."verification__initiative_created_in_existing_issue" AND
          "event"."event" = 'initiative_created_in_existing_issue' AND "event"."state" = 'verification') OR
        ("notify"."discussion__argument_created" AND
          "event"."event" = 'argument_created'                     AND "event"."state" = 'verification') OR
        ("notify"."verification__initiative_revoked" AND
          "event"."event" = 'initiative_revoked'                   AND "event"."state" = 'verification') OR
        ("notify"."canceled_after_revocation_during_verification" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'canceled_after_revocation_during_verification') OR
        ("notify"."canceled_no_initiative_admitted" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'canceled_no_initiative_admitted') OR
        -- voting
        ("notify"."voting" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'voting') OR
        ("notify"."finished_with_winner" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'finished_with_winner') OR
        ("notify"."finished_without_winner" AND
          "event"."event" = 'issue_state_changed' AND "event"."state" = 'finished_without_winner')
      )
    )
  )
  AND "ignored_member"."member_id" ISNULL
  AND "ignored_initiative"."member_id" ISNULL
  GROUP BY "member"."id", "event"."id", "event"."occurrence", "event"."event", "event"."member_id", "event"."issue_id", "event"."state", "event"."initiative_id", "event"."draft_id", "event"."suggestion_id", "event"."argument_id";

COMMENT ON VIEW "event_seen_by_member" IS 'Events as seen by a member, depending on its memberships, interests and support, but ignoring members "notify_level"';
 
DROP FUNCTION "create_snapshot";
CREATE FUNCTION "create_snapshot"
  ( "issue_id_p" "issue"."id"%TYPE )
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "initiative_id_v"    "initiative"."id"%TYPE;
      "suggestion_id_v"    "suggestion"."id"%TYPE;
      "argument_id_v"      "argument"."id"%TYPE;
      "side_v"             "argument"."side"%TYPE;
    BEGIN
      PERFORM "lock_issue"("issue_id_p");
      PERFORM "create_population_snapshot"("issue_id_p");
      PERFORM "create_interest_snapshot"("issue_id_p");
      UPDATE "issue" SET
        "snapshot" = now(),
        "latest_snapshot_event" = 'periodic',
        "population" = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_population_snapshot"
          WHERE "issue_id" = "issue_id_p"
          AND "event" = 'periodic'
        )
        WHERE "id" = "issue_id_p";
      FOR "initiative_id_v" IN
        SELECT "id" FROM "initiative" WHERE "issue_id" = "issue_id_p"
      LOOP
        UPDATE "initiative" SET
          "supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
          ),
          "informed_supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
            AND "ds"."informed"
          ),
          "satisfied_supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
            AND "ds"."satisfied"
          ),
          "satisfied_informed_supporter_count" = (
            SELECT coalesce(sum("di"."weight"), 0)
            FROM "direct_interest_snapshot" AS "di"
            JOIN "direct_supporter_snapshot" AS "ds"
            ON "di"."member_id" = "ds"."member_id"
            WHERE "di"."issue_id" = "issue_id_p"
            AND "di"."event" = 'periodic'
            AND "ds"."initiative_id" = "initiative_id_v"
            AND "ds"."event" = 'periodic'
            AND "ds"."informed"
            AND "ds"."satisfied"
          )
          WHERE "id" = "initiative_id_v";
        FOR "suggestion_id_v" IN
          SELECT "id" FROM "suggestion"
          WHERE "initiative_id" = "initiative_id_v"
        LOOP
          UPDATE "suggestion" SET
            "minus2_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = -2
              AND "opinion"."fulfilled" = FALSE
            ),
            "minus2_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = -2
              AND "opinion"."fulfilled" = TRUE
            ),
            "minus1_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = -1
              AND "opinion"."fulfilled" = FALSE
            ),
            "minus1_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = -1
              AND "opinion"."fulfilled" = TRUE
            ),
            "plus1_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = 1
              AND "opinion"."fulfilled" = FALSE
            ),
            "plus1_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = 1
              AND "opinion"."fulfilled" = TRUE
            ),
            "plus2_unfulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = 2
              AND "opinion"."fulfilled" = FALSE
            ),
            "plus2_fulfilled_count" = (
              SELECT coalesce(sum("snapshot"."weight"), 0)
              FROM "issue" CROSS JOIN "opinion"
              JOIN "direct_interest_snapshot" AS "snapshot"
              ON "snapshot"."issue_id" = "issue"."id"
              AND "snapshot"."event" = "issue"."latest_snapshot_event"
              AND "snapshot"."member_id" = "opinion"."member_id"
              WHERE "issue"."id" = "issue_id_p"
              AND "opinion"."suggestion_id" = "suggestion_id_v"
              AND "opinion"."degree" = 2
              AND "opinion"."fulfilled" = TRUE
            )
            WHERE "suggestion"."id" = "suggestion_id_v";
        END LOOP;
        FOR "argument_id_v", "side_v" IN
          SELECT "id", "side" FROM "argument"
          WHERE "initiative_id" = "initiative_id_v"
        LOOP
          IF "side_v" = 'pro' THEN
            -- count only ratings by supporters
            UPDATE "argument" SET
              "plus_count"  = "subquery"."plus_count",
              "minus_count" = "subquery"."minus_count"
            FROM (
              SELECT
                COUNT(CASE WHEN "rating"."negative" = FALSE THEN 1 ELSE NULL END) AS "plus_count",
                COUNT(CASE WHEN "rating"."negative" = TRUE  THEN 1 ELSE NULL END) AS "minus_count"
              FROM "issue" CROSS JOIN "rating"
              JOIN "direct_supporter_snapshot" AS "snapshot"
                ON "snapshot"."initiative_id" = "rating"."initiative_id"
                AND "snapshot"."event" = "issue"."latest_snapshot_event"
                AND "snapshot"."member_id" = "rating"."member_id"
              WHERE "issue"."id" = "issue_id_p"
                AND "rating"."argument_id" = "argument_id_v"
            ) AS "subquery"
            WHERE "argument"."id" = "argument_id_v";
          ELSE
            -- count only ratings by non-supporters
            UPDATE "argument" SET
              "plus_count"  = "subquery"."plus_count",
              "minus_count" = "subquery"."minus_count"
            FROM (
              SELECT
                COUNT(CASE WHEN "rating"."negative" = FALSE THEN 1 ELSE NULL END) AS "plus_count",
                COUNT(CASE WHEN "rating"."negative" = TRUE  THEN 1 ELSE NULL END) AS "minus_count"
              FROM "issue" CROSS JOIN "rating"
              LEFT JOIN "direct_supporter_snapshot" AS "snapshot"
                ON "snapshot"."initiative_id" = "rating"."initiative_id"
                AND "snapshot"."event" = "issue"."latest_snapshot_event"
                AND "snapshot"."member_id" = "rating"."member_id"
              WHERE "issue"."id" = "issue_id_p"
                AND "rating"."argument_id" = "argument_id_v"
                AND "snapshot"."member_id" IS NULL
            ) AS "subquery"
            WHERE "argument"."id" = "argument_id_v";
          END IF;
        END LOOP;
      END LOOP;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "create_snapshot"
  ( "issue"."id"%TYPE )
  IS 'This function creates a complete new ''periodic'' snapshot of population, interest and support for the given issue. All involved tables are locked, and after completion precalculated values in the source tables are updated.';

DROP FUNCTION "close_voting"("issue_id_p" "issue"."id"%TYPE);
CREATE FUNCTION "close_voting"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "area_id_v"   "area"."id"%TYPE;
      "unit_id_v"   "unit"."id"%TYPE;
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      PERFORM "lock_issue"("issue_id_p");
      SELECT "area_id" INTO "area_id_v" FROM "issue" WHERE "id" = "issue_id_p";
      SELECT "unit_id" INTO "unit_id_v" FROM "area"  WHERE "id" = "area_id_v";
      -- delete timestamp of voting comment:
      UPDATE "direct_voter" SET "comment_changed" = NULL
        WHERE "issue_id" = "issue_id_p";
      -- delete delegating votes (in cases of manual reset of issue state):
      DELETE FROM "delegating_voter"
        WHERE "issue_id" = "issue_id_p";
      -- delete votes from non-privileged voters:
      DELETE FROM "direct_voter"
        USING (
          SELECT
            "direct_voter"."member_id"
          FROM "direct_voter"
          JOIN "member" ON "direct_voter"."member_id" = "member"."id"
          LEFT JOIN "privilege"
          ON "privilege"."unit_id" = "unit_id_v"
          AND "privilege"."member_id" = "direct_voter"."member_id"
          WHERE "direct_voter"."issue_id" = "issue_id_p" AND (
            "member"."active" = FALSE OR
            "privilege"."voting_right" ISNULL OR
            "privilege"."voting_right" = FALSE
          )
        ) AS "subquery"
        WHERE "direct_voter"."issue_id" = "issue_id_p"
        AND "direct_voter"."member_id" = "subquery"."member_id";
      -- consider delegations:
      UPDATE "direct_voter" SET "weight" = 1
        WHERE "issue_id" = "issue_id_p";
      PERFORM "add_vote_delegations"("issue_id_p");
      -- set voter count and mark issue as being calculated:
      UPDATE "issue" SET
        "state"  = 'calculation',
        "closed" = now(),
        "voter_count"        = "subquery"."voter_count",
        "direct_voter_count" = "subquery"."direct_voter_count"
        FROM (
          SELECT



            coalesce(sum("weight"), 0) AS "voter_count",
            count(1)                   AS "direct_voter_count"
          FROM "direct_voter"
          WHERE "issue_id" = "issue_id_p"
        ) AS "subquery"
        WHERE "id" = "issue_id_p";
      -- materialize battle_view:
      -- NOTE: "closed" column of issue must be set at this point
      DELETE FROM "battle" WHERE "issue_id" = "issue_id_p";
      INSERT INTO "battle" (
        "issue_id",
        "winning_initiative_id", "losing_initiative_id",
        "count", "direct_count"
      ) SELECT
        "issue_id",
        "winning_initiative_id", "losing_initiative_id",
        "count", "direct_count"
        FROM "battle_view" WHERE "issue_id" = "issue_id_p";
      -- copy "positive_votes" and "negative_votes" from "battle" table:
      UPDATE "initiative" SET
        "positive_votes" = "battle_win"."count",
        "negative_votes" = "battle_lose"."count",
        "positive_direct_votes" = "battle_win"."direct_count",
        "negative_direct_votes" = "battle_lose"."direct_count"
        FROM "battle" AS "battle_win", "battle" AS "battle_lose"
        WHERE
          "battle_win"."issue_id" = "issue_id_p" AND
          "battle_win"."winning_initiative_id" = "initiative"."id" AND
          "battle_win"."losing_initiative_id" ISNULL AND
          "battle_lose"."issue_id" = "issue_id_p" AND
          "battle_lose"."losing_initiative_id" = "initiative"."id" AND
          "battle_lose"."winning_initiative_id" ISNULL;
    END;
  $$;

COMMENT ON FUNCTION "close_voting"
  ( "issue"."id"%TYPE )
  IS 'Closes the voting on an issue, and calculates positive and negative votes for each initiative; The ranking is not calculated yet, to keep the (locking) transaction short.';

DROP FUNCTION "clean_issue"("issue_id_p" "issue"."id"%TYPE);
CREATE FUNCTION "clean_issue"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row" "issue"%ROWTYPE;
    BEGIN
      SELECT * INTO "issue_row"
        FROM "issue" WHERE "id" = "issue_id_p"
        FOR UPDATE;
      IF "issue_row"."cleaned" ISNULL THEN
        UPDATE "issue" SET
          "state"           = 'voting',
          "closed"          = NULL,
          "ranks_available" = FALSE
          WHERE "id" = "issue_id_p";
        DELETE FROM "issue_comment"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "delegating_voter"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "direct_voter"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "delegating_interest_snapshot"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "direct_interest_snapshot"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "delegating_population_snapshot"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "direct_population_snapshot"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "non_voter"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "delegation"
          WHERE "issue_id" = "issue_id_p";
        DELETE FROM "supporter"
          WHERE "issue_id" = "issue_id_p";
        UPDATE "issue" SET
          "state"           = "issue_row"."state",
          "closed"          = "issue_row"."closed",
          "ranks_available" = "issue_row"."ranks_available",
          "cleaned"         = now()
          WHERE "id" = "issue_id_p";
      END IF;
      RETURN;
    END;
  $$;

COMMENT ON FUNCTION "clean_issue"("issue"."id"%TYPE) IS 'Delete discussion data and votes belonging to an issue';

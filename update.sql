BEGIN;

CREATE TYPE "tie_breaking" AS ENUM ('simple', 'variant1', 'variant2');

CREATE TYPE "defeat_strength" AS ENUM ('simple', 'tuple');

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('3.0.2', 3, 0, 2))
  AS "subquery"("string", "major", "minor", "revision");

CREATE TABLE "temporary_transaction_data" (
        PRIMARY KEY ("txid", "key"),
        "txid"                  INT8            DEFAULT txid_current(),
        "key"                   TEXT,
        "value"                 TEXT            NOT NULL );

 

DROP TABLE "issue_order_in_admission_state";
CREATE TABLE "issue_order_in_admission_state" (
        "id"                    INT8            PRIMARY KEY, --REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "order_in_area"         INT4,
        "order_in_unit"         INT4 );
 
CREATE VIEW "issue_supporter_in_admission_state" AS
  SELECT DISTINCT
    "area"."unit_id",
    "issue"."area_id",
    "issue"."id" AS "issue_id",
    "supporter"."member_id",
    "direct_interest_snapshot"."weight"
  FROM "issue"
  JOIN "area" ON "area"."id" = "issue"."area_id"
  JOIN "supporter" ON "supporter"."issue_id" = "issue"."id"
  JOIN "direct_interest_snapshot"
    ON  "direct_interest_snapshot"."issue_id" = "issue"."id"
    AND "direct_interest_snapshot"."event" = "issue"."latest_snapshot_event"
    AND "direct_interest_snapshot"."member_id" = "supporter"."member_id"
  WHERE "issue"."state" = 'admission'::"issue_state";

COMMENT ON VIEW "issue_supporter_in_admission_state" IS 'Helper view for "lf_update_issue_order" to allow a (proportional) ordering of issues within an area';

 
CREATE OR REPLACE FUNCTION "secondary_link_strength"
  ( "initiative1_ord_p" INT4,
    "initiative2_ord_p" INT4,
    "tie_breaking_p"   "tie_breaking" )
  RETURNS INT8
  LANGUAGE 'plpgsql' IMMUTABLE AS $$
    BEGIN
      IF "initiative1_ord_p" = "initiative2_ord_p" THEN
        RAISE EXCEPTION 'Identical initiative ids passed to "secondary_link_strength" function (should not happen)';
      END IF;
      RETURN (
        CASE WHEN "tie_breaking_p" = 'simple'::"tie_breaking" THEN
          0
        ELSE
          CASE WHEN "initiative1_ord_p" < "initiative2_ord_p" THEN
            1::INT8 << 62
          ELSE 0 END
          +
          CASE WHEN "tie_breaking_p" = 'variant2'::"tie_breaking" THEN
            ("initiative2_ord_p"::INT8 << 31) - "initiative1_ord_p"::INT8
          ELSE
            "initiative2_ord_p"::INT8 - ("initiative1_ord_p"::INT8 << 31)
          END
        END
      );
    END;
  $$;

COMMENT ON FUNCTION "secondary_link_strength"(INT4, INT4, "tie_breaking") IS 'Calculates a secondary criterion for the defeat strength (tie-breaking of the links)';


CREATE TYPE "link_strength" AS (
        "primary"               INT8,
        "secondary"             INT8 );

COMMENT ON TYPE "link_strength" IS 'Type to store the defeat strength of a link between two candidates plus a secondary criterion to create unique link strengths between the candidates (needed for tie-breaking ''variant1'' and ''variant2'')';


CREATE OR REPLACE FUNCTION "find_best_paths"("matrix_d" "link_strength"[][])
  RETURNS "link_strength"[][]
  LANGUAGE 'plpgsql' IMMUTABLE AS $$
    DECLARE
      "dimension_v" INT4;
      "matrix_p"    "link_strength"[][];
      "i"           INT4;
      "j"           INT4;
      "k"           INT4;
    BEGIN
      "dimension_v" := array_upper("matrix_d", 1);
      "matrix_p" := "matrix_d";
      "i" := 1;
      LOOP
        "j" := 1;
        LOOP
          IF "i" != "j" THEN
            "k" := 1;
            LOOP
              IF "i" != "k" AND "j" != "k" THEN
                IF "matrix_p"["j"]["i"] < "matrix_p"["i"]["k"] THEN
                  IF "matrix_p"["j"]["i"] > "matrix_p"["j"]["k"] THEN
                    "matrix_p"["j"]["k"] := "matrix_p"["j"]["i"];
                  END IF;
                ELSE
                  IF "matrix_p"["i"]["k"] > "matrix_p"["j"]["k"] THEN
                    "matrix_p"["j"]["k"] := "matrix_p"["i"]["k"];
                  END IF;
                END IF;
              END IF;
              EXIT WHEN "k" = "dimension_v";
              "k" := "k" + 1;
            END LOOP;
          END IF;
          EXIT WHEN "j" = "dimension_v";
          "j" := "j" + 1;
        END LOOP;
        EXIT WHEN "i" = "dimension_v";
        "i" := "i" + 1;
      END LOOP;
      RETURN "matrix_p";
    END;
  $$;

COMMENT ON FUNCTION "find_best_paths"("link_strength"[][]) IS 'Computes the strengths of the best beat-paths from a square matrix';

ALTER TABLE "member" ADD COLUMN "last_delegation_check" TIMESTAMPTZ;
ALTER TABLE "member" ADD COLUMN "login_recovery_expiry" TIMESTAMPTZ;

ALTER TABLE "session" ADD COLUMN "needs_delegation_check" BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE "policy" ADD COLUMN "defeat_strength" "defeat_strength" NOT NULL DEFAULT 'tuple';
ALTER TABLE "policy" ADD COLUMN "tie_breaking"    "tie_breaking"    NOT NULL DEFAULT 'variant1';

ALTER TABLE "policy" ADD
  CONSTRAINT "no_reverse_beat_path_requires_tuple_defeat_strength" CHECK (
    ("defeat_strength" = 'tuple'::"defeat_strength" OR "no_reverse_beat_path" = FALSE)
  );

ALTER TABLE "issue" ADD COLUMN "admin_notice" TEXT;


ALTER TABLE "issue" DROP CONSTRAINT "valid_state";
ALTER TABLE "issue" ADD
        CONSTRAINT "valid_state" CHECK (
          (
            ("accepted" ISNULL  AND "half_frozen" ISNULL  AND "fully_frozen" ISNULL ) OR
            ("accepted" NOTNULL AND "half_frozen" ISNULL  AND "fully_frozen" ISNULL ) OR
            ("accepted" NOTNULL AND "half_frozen" NOTNULL AND "fully_frozen" ISNULL ) OR
            ("accepted" NOTNULL AND "half_frozen" NOTNULL AND "fully_frozen" NOTNULL)
          ) AND (
            ("state" = 'admission'    AND "closed" ISNULL AND "accepted" ISNULL) OR
            ("state" = 'discussion'   AND "closed" ISNULL AND "accepted" NOTNULL AND "half_frozen" ISNULL) OR
            ("state" = 'verification' AND "closed" ISNULL AND "half_frozen" NOTNULL AND "fully_frozen" ISNULL) OR
            ("state" = 'voting'       AND "closed" ISNULL AND "fully_frozen" NOTNULL) OR
            ("state" = 'canceled_by_admin' AND "closed" NOTNULL) OR
            ("state" = 'canceled_revoked_before_accepted'              AND "closed" NOTNULL AND "accepted" ISNULL) OR
            ("state" = 'canceled_issue_not_accepted'                   AND "closed" NOTNULL AND "accepted" ISNULL) OR
            ("state" = 'canceled_after_revocation_during_discussion'   AND "closed" NOTNULL AND "half_frozen"  ISNULL) OR
            ("state" = 'canceled_after_revocation_during_verification' AND "closed" NOTNULL AND "fully_frozen" ISNULL) OR
            ("state" = 'canceled_no_initiative_admitted' AND "closed" NOTNULL AND "fully_frozen" NOTNULL AND "closed" = "fully_frozen") OR
            ("state" = 'finished_without_winner'         AND "closed" NOTNULL AND "fully_frozen" NOTNULL AND "closed" != "fully_frozen") OR
            ("state" = 'finished_with_winner'            AND "closed" NOTNULL AND "fully_frozen" NOTNULL AND "closed" != "fully_frozen")
          ));

ALTER TABLE "initiative" ADD COLUMN "first_preference_votes" INT4;

ALTER TABLE "initiative" DROP CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results";
ALTER TABLE "initiative" ADD CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results" CHECK (
          ( "admitted" NOTNULL AND "admitted" = TRUE ) OR
          ( "first_preference_votes" ISNULL AND
            "positive_votes" ISNULL AND "negative_votes" ISNULL AND
            "positive_direct_votes" ISNULL AND "negative_direct_votes" ISNULL AND
            "direct_majority" ISNULL AND "indirect_majority" ISNULL AND
            "schulze_rank" ISNULL AND
            "better_than_status_quo" ISNULL AND "worse_than_status_quo" ISNULL AND
            "reverse_beat_path" ISNULL AND "multistage_majority" ISNULL AND
            "eligible" ISNULL AND "winner" ISNULL AND "rank" ISNULL ) );

ALTER TABLE "vote" ALTER COLUMN "grade" SET NOT NULL;

ALTER TABLE "vote" ADD COLUMN "first_preference" BOOLEAN;

ALTER TABLE "vote" ADD
        CONSTRAINT "first_preference_flag_only_set_on_positive_grades"
        CHECK ("grade" > 0 OR "first_preference" ISNULL);

CREATE OR REPLACE FUNCTION "forbid_changes_on_closed_issue_trigger"()
  RETURNS TRIGGER
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_id_v" "issue"."id"%TYPE;
      "issue_row"  "issue"%ROWTYPE;
    BEGIN
      IF EXISTS (
        SELECT NULL FROM "temporary_transaction_data"
        WHERE "txid" = txid_current()
        AND "key" = 'override_protection_triggers'
        AND "value" = TRUE::TEXT
      ) THEN
        RETURN NULL;
      END IF;
      IF TG_OP = 'DELETE' THEN
        "issue_id_v" := OLD."issue_id";
      ELSE
        "issue_id_v" := NEW."issue_id";
      END IF;
      SELECT INTO "issue_row" * FROM "issue"
        WHERE "id" = "issue_id_v" FOR SHARE;
      IF (
        "issue_row"."closed" NOTNULL OR (
          "issue_row"."state" = 'voting' AND
          "issue_row"."phase_finished" NOTNULL
        )
      ) THEN
        IF
          TG_RELID = 'direct_voter'::regclass AND
          TG_OP = 'UPDATE'
        THEN
          IF
            OLD."issue_id"  = NEW."issue_id"  AND
            OLD."member_id" = NEW."member_id" AND
            OLD."weight" = NEW."weight"
          THEN
            RETURN NULL;  -- allows changing of voter comment
          END IF;
        END IF;
        RAISE EXCEPTION 'Tried to modify data after voting has been closed.';
      END IF;
      RETURN NULL;
    END;
  $$;

CREATE OR REPLACE FUNCTION "close_voting"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "area_id_v"   "area"."id"%TYPE;
      "unit_id_v"   "unit"."id"%TYPE;
      "member_id_v" "member"."id"%TYPE;
    BEGIN
      PERFORM "require_transaction_isolation"();
      SELECT "area_id" INTO "area_id_v" FROM "issue" WHERE "id" = "issue_id_p";
      SELECT "unit_id" INTO "unit_id_v" FROM "area"  WHERE "id" = "area_id_v";
      -- override protection triggers:
      INSERT INTO "temporary_transaction_data" ("key", "value")
        VALUES ('override_protection_triggers', TRUE::TEXT);
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
      -- mark first preferences:
      UPDATE "vote" SET "first_preference" = "subquery"."first_preference"
        FROM (
          SELECT
            "vote"."initiative_id",
            "vote"."member_id",
            CASE WHEN "vote"."grade" > 0 THEN
              CASE WHEN "vote"."grade" = max("agg"."grade") THEN TRUE ELSE FALSE END
            ELSE NULL
            END AS "first_preference"
          FROM "vote"
          JOIN "initiative"  -- NOTE: due to missing index on issue_id
          ON "vote"."issue_id" = "initiative"."issue_id"
          JOIN "vote" AS "agg"
          ON "initiative"."id" = "agg"."initiative_id"
          AND "vote"."member_id" = "agg"."member_id"
          GROUP BY "vote"."initiative_id", "vote"."member_id", "vote"."grade"
        ) AS "subquery"
        WHERE "vote"."issue_id" = "issue_id_p"
        AND "vote"."initiative_id" = "subquery"."initiative_id"
        AND "vote"."member_id" = "subquery"."member_id";
      -- finish overriding protection triggers (avoids garbage):
      DELETE FROM "temporary_transaction_data"
        WHERE "key" = 'override_protection_triggers';
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
      -- set voter count:
      UPDATE "issue" SET
        "voter_count" = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_voter" WHERE "issue_id" = "issue_id_p"
        )
        WHERE "id" = "issue_id_p";
      -- set direct voter count:
      UPDATE "issue" SET
        "direct_voter_count" = (
          SELECT count(*) FROM "direct_voter" WHERE "issue_id" = "issue_id_p"
        )
        WHERE "id" = "issue_id_p";
      -- calculate "first_preference_votes":
      UPDATE "initiative"
        SET "first_preference_votes" = coalesce("subquery"."sum", 0)
        FROM (
          SELECT "vote"."initiative_id", sum("direct_voter"."weight")
          FROM "vote" JOIN "direct_voter"
          ON "vote"."issue_id" = "direct_voter"."issue_id"
          AND "vote"."member_id" = "direct_voter"."member_id"
          WHERE "vote"."first_preference"
          GROUP BY "vote"."initiative_id"
        ) AS "subquery"
        WHERE "initiative"."issue_id" = "issue_id_p"
        AND "initiative"."admitted"
        AND "initiative"."id" = "subquery"."initiative_id";
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

CREATE OR REPLACE FUNCTION "defeat_strength"
  ( "positive_votes_p"  INT4,
    "negative_votes_p"  INT4,
    "defeat_strength_p" "defeat_strength" )
  RETURNS INT8
  LANGUAGE 'plpgsql' IMMUTABLE AS $$
    BEGIN
      IF "defeat_strength_p" = 'simple'::"defeat_strength" THEN
        IF "positive_votes_p" > "negative_votes_p" THEN
          RETURN "positive_votes_p";
        ELSE
          RETURN 0;
        END IF;
      ELSE
        IF "positive_votes_p" > "negative_votes_p" THEN
          RETURN ("positive_votes_p"::INT8 << 31) - "negative_votes_p"::INT8;
        ELSIF "positive_votes_p" = "negative_votes_p" THEN
          RETURN 0;
        ELSE
          RETURN -1;
        END IF;
      END IF;
    END;
  $$;

CREATE OR REPLACE FUNCTION "calculate_ranks"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"       "issue"%ROWTYPE;
      "policy_row"      "policy"%ROWTYPE;
      "dimension_v"     INT4;
      "matrix_a"        INT4[][];  -- absolute votes
      "matrix_d"        "link_strength"[][];  -- defeat strength (direct)
      "matrix_p"        "link_strength"[][];  -- defeat strength (best path)
      "matrix_t"        "link_strength"[][];  -- defeat strength (tie-breaking)
      "matrix_f"        BOOLEAN[][];  -- forbidden link (tie-breaking)
      "matrix_b"        BOOLEAN[][];  -- final order (who beats who)
      "i"               INT4;
      "j"               INT4;
      "m"               INT4;
      "n"               INT4;
      "battle_row"      "battle"%ROWTYPE;
      "rank_ary"        INT4[];
      "rank_v"          INT4;
      "initiative_id_v" "initiative"."id"%TYPE;
    BEGIN
      PERFORM "require_transaction_isolation"();
      SELECT * INTO "issue_row"
        FROM "issue" WHERE "id" = "issue_id_p";
      SELECT * INTO "policy_row"
        FROM "policy" WHERE "id" = "issue_row"."policy_id";
      SELECT count(1) INTO "dimension_v"
        FROM "battle_participant" WHERE "issue_id" = "issue_id_p";
      -- create "matrix_a" with absolute number of votes in pairwise
      -- comparison:
      "matrix_a" := array_fill(NULL::INT4, ARRAY["dimension_v", "dimension_v"]);
      "i" := 1;
      "j" := 2;
      FOR "battle_row" IN
        SELECT * FROM "battle" WHERE "issue_id" = "issue_id_p"
        ORDER BY
        "winning_initiative_id" NULLS FIRST,
        "losing_initiative_id" NULLS FIRST
      LOOP
        "matrix_a"["i"]["j"] := "battle_row"."count";
        IF "j" = "dimension_v" THEN
          "i" := "i" + 1;
          "j" := 1;
        ELSE
          "j" := "j" + 1;
          IF "j" = "i" THEN
            "j" := "j" + 1;
          END IF;
        END IF;
      END LOOP;
      IF "i" != "dimension_v" OR "j" != "dimension_v" + 1 THEN
        RAISE EXCEPTION 'Wrong battle count (should not happen)';
      END IF;
      -- store direct defeat strengths in "matrix_d" using "defeat_strength"
      -- and "secondary_link_strength" functions:
      "matrix_d" := array_fill(NULL::INT8, ARRAY["dimension_v", "dimension_v"]);
      "i" := 1;
      LOOP
        "j" := 1;
        LOOP
          IF "i" != "j" THEN
            "matrix_d"["i"]["j"] := (
              "defeat_strength"(
                "matrix_a"["i"]["j"],
                "matrix_a"["j"]["i"],
                "policy_row"."defeat_strength"
              ),
              "secondary_link_strength"(
                "i",
                "j",
                "policy_row"."tie_breaking"
              )
            )::"link_strength";
          END IF;
          EXIT WHEN "j" = "dimension_v";
          "j" := "j" + 1;
        END LOOP;
        EXIT WHEN "i" = "dimension_v";
        "i" := "i" + 1;
      END LOOP;
      -- find best paths:
      "matrix_p" := "find_best_paths"("matrix_d");
      -- create partial order:
      "matrix_b" := array_fill(NULL::BOOLEAN, ARRAY["dimension_v", "dimension_v"]);
      "i" := 1;
      LOOP
        "j" := "i" + 1;
        LOOP
          IF "i" != "j" THEN
            IF "matrix_p"["i"]["j"] > "matrix_p"["j"]["i"] THEN
              "matrix_b"["i"]["j"] := TRUE;
              "matrix_b"["j"]["i"] := FALSE;
            ELSIF "matrix_p"["i"]["j"] < "matrix_p"["j"]["i"] THEN
              "matrix_b"["i"]["j"] := FALSE;
              "matrix_b"["j"]["i"] := TRUE;
            END IF;
          END IF;
          EXIT WHEN "j" = "dimension_v";
          "j" := "j" + 1;
        END LOOP;
        EXIT WHEN "i" = "dimension_v" - 1;
        "i" := "i" + 1;
      END LOOP;
      -- tie-breaking by forbidding shared weakest links in beat-paths
      -- (unless "tie_breaking" is set to 'simple', in which case tie-breaking
      -- is performed later by initiative id):
      IF "policy_row"."tie_breaking" != 'simple'::"tie_breaking" THEN
        "m" := 1;
        LOOP
          "n" := "m" + 1;
          LOOP
            -- only process those candidates m and n, which are tied:
            IF "matrix_b"["m"]["n"] ISNULL THEN
              -- start with beat-paths prior tie-breaking:
              "matrix_t" := "matrix_p";
              -- start with all links allowed:
              "matrix_f" := array_fill(FALSE, ARRAY["dimension_v", "dimension_v"]);
              LOOP
                -- determine (and forbid) that link that is the weakest link
                -- in both the best path from candidate m to candidate n and
                -- from candidate n to candidate m:
                "i" := 1;
                <<forbid_one_link>>
                LOOP
                  "j" := 1;
                  LOOP
                    IF "i" != "j" THEN
                      IF "matrix_d"["i"]["j"] = "matrix_t"["m"]["n"] THEN
                        "matrix_f"["i"]["j"] := TRUE;
                        -- exit for performance reasons,
                        -- as exactly one link will be found:
                        EXIT forbid_one_link;
                      END IF;
                    END IF;
                    EXIT WHEN "j" = "dimension_v";
                    "j" := "j" + 1;
                  END LOOP;
                  IF "i" = "dimension_v" THEN
                    RAISE EXCEPTION 'Did not find shared weakest link for tie-breaking (should not happen)';
                  END IF;
                  "i" := "i" + 1;
                END LOOP;
                -- calculate best beat-paths while ignoring forbidden links:
                "i" := 1;
                LOOP
                  "j" := 1;
                  LOOP
                    IF "i" != "j" THEN
                      "matrix_t"["i"]["j"] := CASE
                         WHEN "matrix_f"["i"]["j"]
                         THEN ((-1::INT8) << 63, 0)::"link_strength"  -- worst possible value
                         ELSE "matrix_d"["i"]["j"] END;
                    END IF;
                    EXIT WHEN "j" = "dimension_v";
                    "j" := "j" + 1;
                  END LOOP;
                  EXIT WHEN "i" = "dimension_v";
                  "i" := "i" + 1;
                END LOOP;
                "matrix_t" := "find_best_paths"("matrix_t");
                -- extend partial order, if tie-breaking was successful:
                IF "matrix_t"["m"]["n"] > "matrix_t"["n"]["m"] THEN
                  "matrix_b"["m"]["n"] := TRUE;
                  "matrix_b"["n"]["m"] := FALSE;
                  EXIT;
                ELSIF "matrix_t"["m"]["n"] < "matrix_t"["n"]["m"] THEN
                  "matrix_b"["m"]["n"] := FALSE;
                  "matrix_b"["n"]["m"] := TRUE;
                  EXIT;
                END IF;
              END LOOP;
            END IF;
            EXIT WHEN "n" = "dimension_v";
            "n" := "n" + 1;
          END LOOP;
          EXIT WHEN "m" = "dimension_v" - 1;
          "m" := "m" + 1;
        END LOOP;
      END IF;
      -- store a unique ranking in "rank_ary":
      "rank_ary" := array_fill(NULL::INT4, ARRAY["dimension_v"]);
      "rank_v" := 1;
      LOOP
        "i" := 1;
        <<assign_next_rank>>
        LOOP
          IF "rank_ary"["i"] ISNULL THEN
            "j" := 1;
            LOOP
              IF
                "i" != "j" AND
                "rank_ary"["j"] ISNULL AND
                ( "matrix_b"["j"]["i"] OR
                  -- tie-breaking by "id"
                  ( "matrix_b"["j"]["i"] ISNULL AND
                    "j" < "i" ) )
              THEN
                -- someone else is better
                EXIT;
              END IF;
              IF "j" = "dimension_v" THEN
                -- noone is better
                "rank_ary"["i"] := "rank_v";
                EXIT assign_next_rank;
              END IF;
              "j" := "j" + 1;
            END LOOP;
          END IF;
          "i" := "i" + 1;
          IF "i" > "dimension_v" THEN
            RAISE EXCEPTION 'Schulze ranking does not compute (should not happen)';
          END IF;
        END LOOP;
        EXIT WHEN "rank_v" = "dimension_v";
        "rank_v" := "rank_v" + 1;
      END LOOP;
      -- write preliminary results:
      "i" := 2;  -- omit status quo with "i" = 1
      FOR "initiative_id_v" IN
        SELECT "id" FROM "initiative"
        WHERE "issue_id" = "issue_id_p" AND "admitted"
        ORDER BY "id"
      LOOP
        UPDATE "initiative" SET
          "direct_majority" =
            CASE WHEN "policy_row"."direct_majority_strict" THEN
              "positive_votes" * "policy_row"."direct_majority_den" >
              "policy_row"."direct_majority_num" * ("positive_votes"+"negative_votes")
            ELSE
              "positive_votes" * "policy_row"."direct_majority_den" >=
              "policy_row"."direct_majority_num" * ("positive_votes"+"negative_votes")
            END
            AND "positive_votes" >= "policy_row"."direct_majority_positive"
            AND "issue_row"."voter_count"-"negative_votes" >=
                "policy_row"."direct_majority_non_negative",
            "indirect_majority" =
            CASE WHEN "policy_row"."indirect_majority_strict" THEN
              "positive_votes" * "policy_row"."indirect_majority_den" >
              "policy_row"."indirect_majority_num" * ("positive_votes"+"negative_votes")
            ELSE
              "positive_votes" * "policy_row"."indirect_majority_den" >=
              "policy_row"."indirect_majority_num" * ("positive_votes"+"negative_votes")
            END
            AND "positive_votes" >= "policy_row"."indirect_majority_positive"
            AND "issue_row"."voter_count"-"negative_votes" >=
                "policy_row"."indirect_majority_non_negative",
          "schulze_rank"           = "rank_ary"["i"],
          "better_than_status_quo" = "rank_ary"["i"] < "rank_ary"[1],
          "worse_than_status_quo"  = "rank_ary"["i"] > "rank_ary"[1],
          "multistage_majority"    = "rank_ary"["i"] >= "rank_ary"[1],
          "reverse_beat_path"      = CASE WHEN "policy_row"."defeat_strength" = 'simple'::"defeat_strength"
                                     THEN NULL
                                     ELSE "matrix_p"[1]["i"]."primary" >= 0 END,
          "eligible"               = FALSE,
          "winner"                 = FALSE,
          "rank"                   = NULL  -- NOTE: in cases of manual reset of issue state
          WHERE "id" = "initiative_id_v";
        "i" := "i" + 1;
      END LOOP;
      IF "i" != "dimension_v" + 1 THEN
        RAISE EXCEPTION 'Wrong winner count (should not happen)';
      END IF;
      -- take indirect majorities into account:
      LOOP
        UPDATE "initiative" SET "indirect_majority" = TRUE
          FROM (
            SELECT "new_initiative"."id" AS "initiative_id"
            FROM "initiative" "old_initiative"
            JOIN "initiative" "new_initiative"
              ON "new_initiative"."issue_id" = "issue_id_p"
              AND "new_initiative"."indirect_majority" = FALSE
            JOIN "battle" "battle_win"
              ON "battle_win"."issue_id" = "issue_id_p"
              AND "battle_win"."winning_initiative_id" = "new_initiative"."id"
              AND "battle_win"."losing_initiative_id" = "old_initiative"."id"
            JOIN "battle" "battle_lose"
              ON "battle_lose"."issue_id" = "issue_id_p"
              AND "battle_lose"."losing_initiative_id" = "new_initiative"."id"
              AND "battle_lose"."winning_initiative_id" = "old_initiative"."id"
            WHERE "old_initiative"."issue_id" = "issue_id_p"
            AND "old_initiative"."indirect_majority" = TRUE
            AND CASE WHEN "policy_row"."indirect_majority_strict" THEN
              "battle_win"."count" * "policy_row"."indirect_majority_den" >
              "policy_row"."indirect_majority_num" *
              ("battle_win"."count"+"battle_lose"."count")
            ELSE
              "battle_win"."count" * "policy_row"."indirect_majority_den" >=
              "policy_row"."indirect_majority_num" *
              ("battle_win"."count"+"battle_lose"."count")
            END
            AND "battle_win"."count" >= "policy_row"."indirect_majority_positive"
            AND "issue_row"."voter_count"-"battle_lose"."count" >=
                "policy_row"."indirect_majority_non_negative"
          ) AS "subquery"
          WHERE "id" = "subquery"."initiative_id";
        EXIT WHEN NOT FOUND;
      END LOOP;
      -- set "multistage_majority" for remaining matching initiatives:
      UPDATE "initiative" SET "multistage_majority" = TRUE
        FROM (
          SELECT "losing_initiative"."id" AS "initiative_id"
          FROM "initiative" "losing_initiative"
          JOIN "initiative" "winning_initiative"
            ON "winning_initiative"."issue_id" = "issue_id_p"
            AND "winning_initiative"."admitted"
          JOIN "battle" "battle_win"
            ON "battle_win"."issue_id" = "issue_id_p"
            AND "battle_win"."winning_initiative_id" = "winning_initiative"."id"
            AND "battle_win"."losing_initiative_id" = "losing_initiative"."id"
          JOIN "battle" "battle_lose"
            ON "battle_lose"."issue_id" = "issue_id_p"
            AND "battle_lose"."losing_initiative_id" = "winning_initiative"."id"
            AND "battle_lose"."winning_initiative_id" = "losing_initiative"."id"
          WHERE "losing_initiative"."issue_id" = "issue_id_p"
          AND "losing_initiative"."admitted"
          AND "winning_initiative"."schulze_rank" <
              "losing_initiative"."schulze_rank"
          AND "battle_win"."count" > "battle_lose"."count"
          AND (
            "battle_win"."count" > "winning_initiative"."positive_votes" OR
            "battle_lose"."count" < "losing_initiative"."negative_votes" )
        ) AS "subquery"
        WHERE "id" = "subquery"."initiative_id";
      -- mark eligible initiatives:
      UPDATE "initiative" SET "eligible" = TRUE
        WHERE "issue_id" = "issue_id_p"
        AND "initiative"."direct_majority"
        AND "initiative"."indirect_majority"
        AND "initiative"."better_than_status_quo"
        AND (
          "policy_row"."no_multistage_majority" = FALSE OR
          "initiative"."multistage_majority" = FALSE )
        AND (
          "policy_row"."no_reverse_beat_path" = FALSE OR
          coalesce("initiative"."reverse_beat_path", FALSE) = FALSE );
      -- mark final winner:
      UPDATE "initiative" SET "winner" = TRUE
        FROM (
          SELECT "id" AS "initiative_id"
          FROM "initiative"
          WHERE "issue_id" = "issue_id_p" AND "eligible" AND "schulze_rank" = 1
          ORDER BY
            "schulze_rank",
            "id"
          LIMIT 1
        ) AS "subquery"
        WHERE "id" = "subquery"."initiative_id";
      -- write final ranks which should be equal(!) to schulze ranks (this behaviour differs from the one liquid feedback has implemented):
      "rank_v" := 1;
      FOR "initiative_id_v" IN
        SELECT "id"
        FROM "initiative"
        WHERE "issue_id" = "issue_id_p" AND "admitted"
        ORDER BY
          "schulze_rank",
          "winner" DESC,
          "eligible" DESC,
          "id"
      LOOP
        UPDATE "initiative" SET "rank" = "rank_v"
          WHERE "id" = "initiative_id_v";
        "rank_v" := "rank_v" + 1;
      END LOOP;
      -- set schulze rank of status quo and mark issue as finished:
      UPDATE "issue" SET
        "status_quo_schulze_rank" = "rank_ary"[1],
        "state" =
          CASE WHEN EXISTS (
            SELECT NULL FROM "initiative"
            WHERE "issue_id" = "issue_id_p" AND "winner"
          ) THEN
            'finished_with_winner'::"issue_state"
          ELSE
            'finished_without_winner'::"issue_state"
          END,
        "closed" = "phase_finished",
        "phase_finished" = NULL
        WHERE "id" = "issue_id_p";
      RETURN;
    END;
  $$;
CREATE OR REPLACE FUNCTION "clean_issue"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      IF EXISTS (
        SELECT NULL FROM "issue" WHERE "id" = "issue_id_p" AND "cleaned" ISNULL
      ) THEN
        -- override protection triggers:
        INSERT INTO "temporary_transaction_data" ("key", "value")
          VALUES ('override_protection_triggers', TRUE::TEXT);
        -- clean data:
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
          USING "initiative"  -- NOTE: due to missing index on issue_id
          WHERE "initiative"."issue_id" = "issue_id_p"
          AND "supporter"."initiative_id" = "initiative_id";
        -- mark issue as cleaned:
        UPDATE "issue" SET "cleaned" = now() WHERE "id" = "issue_id_p";
        -- finish overriding protection triggers (avoids garbage):
        DELETE FROM "temporary_transaction_data"
          WHERE "key" = 'override_protection_triggers';
      END IF;
      RETURN;
    END;
  $$;


CREATE OR REPLACE FUNCTION "delete_member"("member_id_p" "member"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      UPDATE "member" SET
        "last_login"                   = NULL,
        "last_delegation_check"        = NULL,
        "login"                        = NULL,
        "password"                     = NULL,
        "locked"                       = TRUE,
        "active"                       = FALSE,
        "notify_email"                 = NULL,
        "notify_email_unconfirmed"     = NULL,
        "notify_email_secret"          = NULL,
        "notify_email_secret_expiry"   = NULL,
        "notify_email_lock_expiry"     = NULL,
        "login_recovery_expiry"        = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
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
        "statement"                    = NULL
        WHERE "id" = "member_id_p";
      -- "text_search_data" is updated by triggers
      DELETE FROM "setting"            WHERE "member_id" = "member_id_p";
      DELETE FROM "setting_map"        WHERE "member_id" = "member_id_p";
      DELETE FROM "member_relation_setting" WHERE "member_id" = "member_id_p";
      DELETE FROM "member_image"       WHERE "member_id" = "member_id_p";
      DELETE FROM "contact"            WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_member"     WHERE "member_id" = "member_id_p";
      DELETE FROM "session"            WHERE "member_id" = "member_id_p";
      DELETE FROM "area_setting"       WHERE "member_id" = "member_id_p";
      DELETE FROM "issue_setting"      WHERE "member_id" = "member_id_p";
      DELETE FROM "ignored_initiative" WHERE "member_id" = "member_id_p";
      DELETE FROM "initiative_setting" WHERE "member_id" = "member_id_p";
      DELETE FROM "suggestion_setting" WHERE "member_id" = "member_id_p";
      DELETE FROM "membership"         WHERE "member_id" = "member_id_p";
      DELETE FROM "delegation"         WHERE "truster_id" = "member_id_p";
      DELETE FROM "non_voter"          WHERE "member_id" = "member_id_p";
      DELETE FROM "direct_voter" USING "issue"
        WHERE "direct_voter"."issue_id" = "issue"."id"
        AND "issue"."closed" ISNULL
        AND "member_id" = "member_id_p";
      RETURN;
    END;
  $$;

CREATE OR REPLACE FUNCTION "delete_private_data"()
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    BEGIN
      DELETE FROM "temporary_transaction_data";
      UPDATE "member" SET
        "invite_code"                  = NULL,
        "invite_code_expiry"           = NULL,
        "admin_comment"                = NULL,
        "last_login"                   = NULL,
        "last_delegation_check"        = NULL,
        "login"                        = NULL,
        "password"                     = NULL,
        "lang"                         = NULL,
        "notify_email"                 = NULL,
        "notify_email_unconfirmed"     = NULL,
        "notify_email_secret"          = NULL,
        "notify_email_secret_expiry"   = NULL,
        "notify_email_lock_expiry"     = NULL,
        "notify_level"                 = NULL,
        "login_recovery_expiry"        = NULL,
        "password_reset_secret"        = NULL,
        "password_reset_secret_expiry" = NULL,
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
      RETURN;
    END;
  $$;

COMMENT ON TABLE "temporary_transaction_data" IS 'Table to store temporary transaction data; shall be emptied before a transaction is ommitted';

COMMENT ON COLUMN "temporary_transaction_data"."txid" IS 'Value returned by function txid_current(); should be added to WHERE clause, when oing SELECT on this table, but ignored when doing DELETE on this table';

COMMENT ON COLUMN "member"."last_delegation_check" IS 'Timestamp of last delegation check (i.e. confirmation of all unit and area delegations)';
COMMENT ON COLUMN "member"."login_recovery_expiry"        IS 'Date/time after which another login recovery attempt is allowed';
COMMENT ON COLUMN "member"."password_reset_secret"        IS 'Secret string sent via e-mail for password recovery';
COMMENT ON COLUMN "member"."password_reset_secret_expiry" IS 'Date/time until the password recovery secret is valid, and date/time after which another password recovery attempt is allowed';
COMMENT ON COLUMN "session"."needs_delegation_check" IS 'Set to TRUE, if member must perform a delegation check to proceed with login; see column "last_delegation_check" in "member" table';

COMMENT ON TYPE "defeat_strength" IS 'How pairwise defeats are measured for the Schulze method: ''simple'' = only the number of winning votes, ''tuple'' = primarily the number of winning votes, secondarily the number of losing votes';

COMMENT ON TYPE "tie_breaking" IS 'Tie-breaker for the Schulze method: ''simple'' = only initiative ids are used, ''variant1'' = use initiative ids in variant 1 for tie breaking of the links (TBRL) and sequentially forbid shared links, ''variant2'' = use initiative ids in variant 2 for tie breaking of the links (TBRL) and sequentially forbid shared links';
COMMENT ON COLUMN "policy"."defeat_strength"       IS 'How pairwise defeats are measured for the Schulze method; see type "defeat_strength"; ''tuple'' is the recommended setting';
COMMENT ON COLUMN "policy"."tie_breaking"          IS 'Tie-breaker for the Schulze method; see type "tie_breaking"; ''variant1'' or ''variant2'' are recommended';
COMMENT ON COLUMN "policy"."no_reverse_beat_path" IS 'EXPERIMENTAL FEATURE: Causes initiatives with "reverse_beat_path" flag to not be "eligible", thus disallowing them to be winner. See comment on column "initiative"."reverse_beat_path". This option ensures both that a winning initiative is never tied in a (weak) condorcet paradox with the status quo and a winning initiative always beats the status quo directly with a simple majority.';
COMMENT ON COLUMN "policy"."no_multistage_majority" IS 'EXPERIMENTAL FEATURE: Causes initiatives with "multistage_majority" flag to not be "eligible", thus disallowing them to be winner. See comment on column "initiative"."multistage_majority". This disqualifies initiatives which could cause an instable result. An instable result in this meaning is a result such that repeating the ballot with same preferences but with the winner of the first ballot as status quo would lead to a different winner in the second ballot. If there are no direct majorities required for the winner, or if in direct comparison only simple majorities are required and "no_reverse_beat_path" is true, then results are always stable and this flag does not have any effect on the winner (but still affects the "eligible" flag of an "initiative").';
COMMENT ON COLUMN "issue"."admin_notice"            IS 'Public notice by admin to explain manual interventions, or to announce corrections';

COMMENT ON TABLE "issue_order_in_admission_state" IS 'Ordering information for issues that are not stored in the "issue" table to avoid locking of multiple issues at once; Filled/updated by "lf_update_issue_order"';

COMMENT ON COLUMN "issue_order_in_admission_state"."id"            IS 'References "issue" ("id") but has no referential integrity trigger associated, due to performance/locking issues';
COMMENT ON COLUMN "issue_order_in_admission_state"."order_in_area" IS 'Order of issues in admission state within a single area; NULL values sort last';
COMMENT ON COLUMN "issue_order_in_admission_state"."order_in_unit" IS 'Order of issues in admission state within all areas of a unit; NULL values sort last';

COMMENT ON COLUMN "initiative"."first_preference_votes" IS 'Number of direct and delegating voters who ranked this initiative as their first choice';
COMMENT ON COLUMN "initiative"."positive_votes"         IS 'Number of direct and delegating voters who ranked this initiative better than the status quo';
COMMENT ON COLUMN "initiative"."negative_votes"         IS 'Number of direct and delegating voters who ranked this initiative worse than the status quo';
COMMENT ON COLUMN "initiative"."schulze_rank"           IS 'Schulze-Ranking';
COMMENT ON COLUMN "initiative"."better_than_status_quo" IS 'TRUE, if initiative has a schulze-ranking better than the status quo';
COMMENT ON COLUMN "initiative"."worse_than_status_quo"  IS 'TRUE, if initiative has a schulze-ranking worse than the status quo (DEPRECATED, since schulze-ranking is unique per issue; use "better_than_status_quo"=FALSE)';
COMMENT ON COLUMN "initiative"."reverse_beat_path"      IS 'TRUE, if there is a beat path (may include ties) from this initiative to the status quo; set to NULL if "policy"."defeat_strength" is set to ''simple''';
COMMENT ON COLUMN "initiative"."winner"                 IS 'Winner is the "eligible" initiative with best "schulze_rank"';
COMMENT ON TABLE "rendered_suggestion" IS 'This table may be used by frontends to cache "rendered" suggestions (e.g. HTML output generated from wiki text)';
COMMENT ON TABLE "direct_population_snapshot" IS 'Snapshot of active members having either a "membership" in the "area" or an "interest" in the "issue"; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_population_snapshot" IS 'Delegations increasing the weight of entries in the "direct_population_snapshot" table; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_interest_snapshot" IS 'Snapshot of active members having an "interest" in the "issue"; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "delegating_interest_snapshot" IS 'Delegations increasing the weight of entries in the "direct_interest_snapshot" table; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_supporter_snapshot" IS 'Snapshot of supporters of initiatives (weight is stored in "direct_interest_snapshot"); for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_voter" IS 'Members having directly voted for/against initiatives of an issue; frontends must ensure that no voters are added or removed to/from this table when the issue has been closed; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "delegating_voter" IS 'Delegations increasing the weight of entries in the "direct_voter" table; for corrections refer to column "issue_notice" of "issue" table';
 
COMMENT ON TABLE "vote" IS 'Manual and delegated votes without abstentions; frontends must ensure that no votes are added modified or removed when the issue has been closed; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON COLUMN "vote"."issue_id"         IS 'WARNING: No index: For selections use column "initiative_id" and join via table "initiative" where neccessary';
COMMENT ON COLUMN "vote"."grade"            IS 'Values smaller than zero mean reject, values greater than zero mean acceptance, zero or missing row means abstention. Preferences are expressed by different positive or negative numbers.';
COMMENT ON COLUMN "vote"."first_preference" IS 'Value is automatically set after voting is finished. For positive grades, this value is set to true for the highest (i.e. best) grade.';
COMMENT ON FUNCTION "defeat_strength"(INT4, INT4, "defeat_strength") IS 'Calculates defeat strength (INT8!) according to the "defeat_strength" option (see comment on type "defeat_strength")';

UPDATE "policy" SET "no_reverse_beat_path" = FALSE;  -- recommended

INSERT INTO "temporary_transaction_data" ("key", "value")
  VALUES ('override_protection_triggers', TRUE::TEXT);

UPDATE "vote" SET "first_preference" = "subquery"."first_preference"
  FROM (
    SELECT
      "vote"."initiative_id",
      "vote"."member_id",
      CASE WHEN "vote"."grade" > 0 THEN
        CASE WHEN "vote"."grade" = max("agg"."grade") THEN TRUE ELSE FALSE END
      ELSE NULL
      END AS "first_preference"
    FROM "vote"
    JOIN "initiative"  -- NOTE: due to missing index on issue_id
    ON "vote"."issue_id" = "initiative"."issue_id"
    JOIN "vote" AS "agg"
    ON "initiative"."id" = "agg"."initiative_id"
    AND "vote"."member_id" = "agg"."member_id"
    GROUP BY "vote"."initiative_id", "vote"."member_id"
  ) AS "subquery"
  WHERE "vote"."initiative_id" = "subquery"."initiative_id"
  AND "vote"."member_id" = "subquery"."member_id";

DELETE FROM "temporary_transaction_data"
  WHERE "key" = 'override_protection_triggers';

UPDATE "initiative"
  SET "first_preference_votes" = coalesce("subquery"."sum", 0)
  FROM (
    SELECT "vote"."initiative_id", sum("direct_voter"."weight")
    FROM "vote" JOIN "direct_voter"
    ON "vote"."issue_id" = "direct_voter"."issue_id"
    AND "vote"."member_id" = "direct_voter"."member_id"
    WHERE "vote"."first_preference"
    GROUP BY "vote"."initiative_id"
  ) AS "subquery"
  WHERE "initiative"."admitted"
  AND "initiative"."id" = "subquery"."initiative_id";

-- reconstruct battle data (originating from LiquidFeedback Core before v2.0.0)
-- to avoid future data loss when executing "clean_issue" to delete voting data:
INSERT INTO "battle" (
    "issue_id",
    "winning_initiative_id",
    "losing_initiative_id",
    "count"
  ) SELECT
    "battle_view"."issue_id",
    "battle_view"."winning_initiative_id",
    "battle_view"."losing_initiative_id",
    "battle_view"."count"
  FROM (
    SELECT
      "issue"."id" AS "issue_id",
      "winning_initiative"."id" AS "winning_initiative_id",
      "losing_initiative"."id" AS "losing_initiative_id",
      sum(
        CASE WHEN
          coalesce("better_vote"."grade", 0) >
          coalesce("worse_vote"."grade", 0)
        THEN "direct_voter"."weight" ELSE 0 END
      ) AS "count"
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
    WHERE "issue"."state" IN ('finished_with_winner', 'finished_without_winner')
    AND "winning_initiative"."id" != "losing_initiative"."id"
    -- NOTE: comparisons with status-quo are intentionally omitted to mark
    --       issues that were counted prior LiquidFeedback Core v2.0.0
    GROUP BY
      "issue"."id",
      "winning_initiative"."id",
      "losing_initiative"."id"
  ) AS "battle_view"
  LEFT JOIN "battle"
  ON "battle_view"."winning_initiative_id" = "battle"."winning_initiative_id"
  AND "battle_view"."losing_initiative_id" = "battle"."losing_initiative_id"
  WHERE "battle" ISNULL;


COMMIT;

-- ALTER TYPE "issue_state" ADD VALUE 'canceled_by_admin' AFTER 'voting';

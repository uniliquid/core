BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('3.0.1', 3, 0, 1))
  AS "subquery"("string", "major", "minor", "revision");

CREATE TABLE "issue_order_in_admission_state" (
        "id"                    INT8            PRIMARY KEY, --REFERENCES "issue" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
        "order_in_area"         INT4,
        "order_in_unit"         INT4 );

COMMENT ON TABLE "issue_order_in_admission_state" IS 'Ordering information for issues that are not stored in the "issue" table to avoid locking of multiple issues at once; Filled/updated by "lf_update_issue_order"';

COMMENT ON COLUMN "issue_order_in_admission_state"."id"            IS 'References "issue" ("id") but has no referential integrity trigger associated, due to performance/locking issues';
COMMENT ON COLUMN "issue_order_in_admission_state"."order_in_area" IS 'Order of issues in admission state within a single area; NULL values sort last';
COMMENT ON COLUMN "issue_order_in_admission_state"."order_in_unit" IS 'Order of issues in admission state within all areas of a unit; NULL values sort last';

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

COMMENT ON COLUMN "initiative"."schulze_rank"           IS 'Schulze-Ranking';
COMMENT ON COLUMN "initiative"."better_than_status_quo" IS 'TRUE, if initiative has a schulze-ranking better than the status quo';
COMMENT ON COLUMN "initiative"."worse_than_status_quo"  IS 'TRUE, if initiative has a schulze-ranking worse than the status quo (DEPRECATED, since schulze-ranking is unique per issue; use "better_than_status_quo"=FALSE)';
COMMENT ON COLUMN "initiative"."winner"                 IS 'Winner is the "eligible" initiative with best "schulze_rank"';

CREATE OR REPLACE FUNCTION "calculate_ranks"("issue_id_p" "issue"."id"%TYPE)
  RETURNS VOID
  LANGUAGE 'plpgsql' VOLATILE AS $$
    DECLARE
      "issue_row"         "issue"%ROWTYPE;
      "policy_row"        "policy"%ROWTYPE;
      "dimension_v"       INTEGER;
      "vote_matrix"       INT4[][];  -- absolute votes
      "matrix"            INT8[][];  -- defeat strength / best paths
      "i"                 INTEGER;
      "j"                 INTEGER;
      "k"                 INTEGER;
      "battle_row"        "battle"%ROWTYPE;
      "rank_ary"          INT4[];
      "rank_v"            INT4;
      "initiative_id_v"   "initiative"."id"%TYPE;
    BEGIN
      PERFORM "require_transaction_isolation"();
      SELECT * INTO "issue_row"
        FROM "issue" WHERE "id" = "issue_id_p";
      SELECT * INTO "policy_row"
        FROM "policy" WHERE "id" = "issue_row"."policy_id";
      SELECT count(1) INTO "dimension_v"
        FROM "battle_participant" WHERE "issue_id" = "issue_id_p";
      -- Create "vote_matrix" with absolute number of votes in pairwise
      -- comparison:
      "vote_matrix" := array_fill(NULL::INT4, ARRAY["dimension_v", "dimension_v"]);
      "i" := 1;
      "j" := 2;
      FOR "battle_row" IN
        SELECT * FROM "battle" WHERE "issue_id" = "issue_id_p"
        ORDER BY
        "winning_initiative_id" NULLS FIRST,
        "losing_initiative_id" NULLS FIRST
      LOOP
        "vote_matrix"["i"]["j"] := "battle_row"."count";
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
      -- Store defeat strengths in "matrix" using "defeat_strength"
      -- function:
      "matrix" := array_fill(NULL::INT8, ARRAY["dimension_v", "dimension_v"]);
      "i" := 1;
      LOOP
        "j" := 1;
        LOOP
          IF "i" != "j" THEN
            "matrix"["i"]["j"] := "defeat_strength"(
              "vote_matrix"["i"]["j"],
              "vote_matrix"["j"]["i"]
            );
          END IF;
          EXIT WHEN "j" = "dimension_v";
          "j" := "j" + 1;
        END LOOP;
        EXIT WHEN "i" = "dimension_v";
        "i" := "i" + 1;
      END LOOP;
      -- Find best paths:
      "i" := 1;
      LOOP
        "j" := 1;
        LOOP
          IF "i" != "j" THEN
            "k" := 1;
            LOOP
              IF "i" != "k" AND "j" != "k" THEN
                IF "matrix"["j"]["i"] < "matrix"["i"]["k"] THEN
                  IF "matrix"["j"]["i"] > "matrix"["j"]["k"] THEN
                    "matrix"["j"]["k"] := "matrix"["j"]["i"];
                  END IF;
                ELSE
                  IF "matrix"["i"]["k"] > "matrix"["j"]["k"] THEN
                    "matrix"["j"]["k"] := "matrix"["i"]["k"];
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
      -- Determine order of winners:
      "rank_ary" := array_fill(NULL::INT4, ARRAY["dimension_v"]);
      "rank_v" := 1;
      LOOP
        "i" := 1;
        LOOP
          IF "rank_ary"["i"] ISNULL THEN
            "j" := 1;
            LOOP
              IF
                "i" != "j" AND
                "rank_ary"["j"] ISNULL AND
                ( "matrix"["j"]["i"] > "matrix"["i"]["j"] OR
                  -- tie-breaking by "id"
                  ( "matrix"["j"]["i"] = "matrix"["i"]["j"] AND
                    "j" < "i" ) )
              THEN
                -- someone else is better
                EXIT;
              END IF;
              "j" := "j" + 1;
              IF "j" = "dimension_v" + 1 THEN
                -- noone is better
                "rank_ary"["i"] := "rank_v";
                EXIT;
              END IF;
            END LOOP;
            EXIT WHEN "j" = "dimension_v" + 1;
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
          "reverse_beat_path"      = "matrix"[1]["i"] >= 0,
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
          "initiative"."reverse_beat_path" = FALSE );
      -- mark final winner:
      UPDATE "initiative" SET "winner" = TRUE
        FROM (
          SELECT "id" AS "initiative_id"
          FROM "initiative"
          WHERE "issue_id" = "issue_id_p" AND "eligible"
          ORDER BY
            "schulze_rank",
            "id"
          LIMIT 1
        ) AS "subquery"
        WHERE "id" = "subquery"."initiative_id";
      -- write (final) ranks:
      "rank_v" := 1;
      FOR "initiative_id_v" IN
        SELECT "id"
        FROM "initiative"
        WHERE "issue_id" = "issue_id_p" AND "admitted"
        ORDER BY
          "winner" DESC,
          "eligible" DESC,
          "schulze_rank",
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

ALTER TABLE "initiative" ADD COLUMN "first_preference_votes" INT4;

ALTER TABLE "initiative" DROP CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results";
ALTER TABLE "initiative" ADD CONSTRAINT "non_admitted_initiatives_cant_contain_voting_results" CHECK (
          ( "admitted" NOTNULL AND "admitted" = TRUE ) OR
          ( "first_preference_votes" ISNULL AND
            "positive_votes" ISNULL AND "negative_votes" ISNULL AND
            "direct_majority" ISNULL AND "indirect_majority" ISNULL AND
            "schulze_rank" ISNULL AND
            "better_than_status_quo" ISNULL AND "worse_than_status_quo" ISNULL AND
            "reverse_beat_path" ISNULL AND "multistage_majority" ISNULL AND
            "eligible" ISNULL AND "winner" ISNULL AND "rank" ISNULL ) );

COMMENT ON COLUMN "initiative"."first_preference_votes" IS 'Number of direct and delegating voters who ranked this initiative as their first choice';
COMMENT ON COLUMN "initiative"."positive_votes"         IS 'Number of direct and delegating voters who ranked this initiative better than the status quo';
COMMENT ON COLUMN "initiative"."negative_votes"         IS 'Number of direct and delegating voters who ranked this initiative worse than the status quo';

-- UPDATE TABLE "vote" SET "grade" = 0 WHERE "grade" ISNULL;  -- should not be necessary
ALTER TABLE "vote" ALTER COLUMN "grade" SET NOT NULL;

ALTER TABLE "vote" ADD COLUMN "first_preference" BOOLEAN;

ALTER TABLE "vote" ADD
        CONSTRAINT "first_preference_flag_only_set_on_positive_grades"
        CHECK ("grade" > 0 OR "first_preference" ISNULL);

COMMENT ON COLUMN "vote"."first_preference" IS 'Value is automatically set after voting is finished. For positive grades, this value is set to true for the highest (i.e. best) grade.';
 
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
          GROUP BY "vote"."initiative_id", "vote"."member_id"
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
        "count"
      ) SELECT
        "issue_id",
        "winning_initiative_id", "losing_initiative_id",
        "count"
        FROM "battle_view" WHERE "issue_id" = "issue_id_p";
      -- set voter count:
      UPDATE "issue" SET
        "voter_count" = (
          SELECT coalesce(sum("weight"), 0)
          FROM "direct_voter" WHERE "issue_id" = "issue_id_p"
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
        "negative_votes" = "battle_lose"."count"
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

COMMIT;

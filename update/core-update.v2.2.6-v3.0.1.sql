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

COMMIT;

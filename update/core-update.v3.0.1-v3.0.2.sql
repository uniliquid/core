BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('3.0.2', 3, 0, 2))
  AS "subquery"("string", "major", "minor", "revision");


CREATE TYPE "defeat_strength" AS ENUM ('simple', 'tuple');

COMMENT ON TYPE "defeat_strength" IS 'How pairwise defeats are measured for the Schulze method: ''simple'' = only the number of winning votes, ''tuple'' = primarily the number of winning votes, secondarily the number of losing votes';


CREATE TYPE "tie_breaking" AS ENUM ('simple', 'variant1', 'variant2');

COMMENT ON TYPE "tie_breaking" IS 'Tie-breaker for the Schulze method: ''simple'' = only initiative ids are used, ''variant1'' = use initiative ids in variant 1 for tie breaking of the links (TBRL) and sequentially forbid shared links, ''variant2'' = use initiative ids in variant 2 for tie breaking of the links (TBRL) and sequentially forbid shared links';


ALTER TABLE "policy" ADD COLUMN "defeat_strength" "defeat_strength" NOT NULL DEFAULT 'tuple';
ALTER TABLE "policy" ADD COLUMN "tie_breaking"    "tie_breaking"    NOT NULL DEFAULT 'variant1';

ALTER TABLE "policy" ADD
  CONSTRAINT "no_reverse_beat_path_requires_tuple_defeat_strength" CHECK (
    ("defeat_strength" = 'tuple'::"defeat_strength" OR "no_reverse_beat_path" = FALSE)
  );

COMMENT ON COLUMN "policy"."defeat_strength"       IS 'How pairwise defeats are measured for the Schulze method; see type "defeat_strength"; ''tuple'' is the recommended setting';
COMMENT ON COLUMN "policy"."tie_breaking"          IS 'Tie-breaker for the Schulze method; see type "tie_breaking"; ''variant1'' or ''variant2'' are recommended';
COMMENT ON COLUMN "initiative"."reverse_beat_path"      IS 'TRUE, if there is a beat path (may include ties) from this initiative to the status quo; set to NULL if "policy"."defeat_strength" is set to ''simple''';
 

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


DROP FUNCTION "calculate_ranks"("issue"."id"%TYPE);
DROP FUNCTION "defeat_strength"(INT4, INT4);


CREATE FUNCTION "defeat_strength"
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

COMMENT ON FUNCTION "defeat_strength"(INT4, INT4, "defeat_strength") IS 'Calculates defeat strength (INT8!) according to the "defeat_strength" option (see comment on type "defeat_strength")';


CREATE FUNCTION "secondary_link_strength"
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


CREATE FUNCTION "find_best_paths"("matrix_d" "link_strength"[][])
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
 

CREATE FUNCTION "calculate_ranks"("issue_id_p" "issue"."id"%TYPE)
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

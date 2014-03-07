BEGIN;
DROP VIEW "battle_view_any_state";
CREATE VIEW "battle_view_any_state" AS
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
  WHERE (
    "winning_initiative"."id" != "losing_initiative"."id" OR
    ( ("winning_initiative"."id" NOTNULL AND "losing_initiative"."id" ISNULL) OR
      ("winning_initiative"."id" ISNULL AND "losing_initiative"."id" NOTNULL) ) )
  GROUP BY
    "issue"."id",
    "winning_initiative"."id",
    "losing_initiative"."id";

COMMENT ON VIEW "battle_view_any_state" IS 'Number of members preferring one initiative (or status-quo) to another initiative (or status-quo); Used to fill "battle" table (ANY STATE)';
COMMIT;

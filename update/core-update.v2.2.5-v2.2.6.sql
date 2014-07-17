-- NOTICE: This update script disables the "no_reserve_beat_path" setting for
--         all policies. If this is not intended, please edit this script
--         before applying it to your database.

BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('2.2.6', 2, 2, 6))
  AS "subquery"("string", "major", "minor", "revision");

ALTER TABLE "policy" ALTER COLUMN "no_reverse_beat_path" SET DEFAULT FALSE;

UPDATE "policy" SET "no_reverse_beat_path" = FALSE;  -- recommended

COMMENT ON COLUMN "policy"."no_reverse_beat_path" IS 'EXPERIMENTAL FEATURE: Causes initiatives with "reverse_beat_path" flag to not be "eligible", thus disallowing them to be winner. See comment on column "initiative"."reverse_beat_path". This option ensures both that a winning initiative is never tied in a (weak) condorcet paradox with the status quo and a winning initiative always beats the status quo directly with a simple majority.';

COMMENT ON COLUMN "policy"."no_multistage_majority" IS 'EXPERIMENTAL FEATURE: Causes initiatives with "multistage_majority" flag to not be "eligible", thus disallowing them to be winner. See comment on column "initiative"."multistage_majority". This disqualifies initiatives which could cause an instable result. An instable result in this meaning is a result such that repeating the ballot with same preferences but with the winner of the first ballot as status quo would lead to a different winner in the second ballot. If there are no direct majorities required for the winner, or if in direct comparison only simple majorities are required and "no_reverse_beat_path" is true, then results are always stable and this flag does not have any effect on the winner (but still affects the "eligible" flag of an "initiative").';

COMMIT;

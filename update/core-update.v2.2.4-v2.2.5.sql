-- NOTICE: This update script requires PostgreSQL version 9.1 or higher.
--         If you use an older version, please dump your database and
--         update it on a system with PostgreSQL 9.1 or higher, before
--         restoring it on your original system.

-- NOTICE: The following command cannot be executed within a transaction block
--         and must be rolled back manually, if the update fails:
ALTER TYPE "issue_state" ADD VALUE 'canceled_by_admin' AFTER 'voting';

BEGIN;

CREATE OR REPLACE VIEW "liquid_feedback_version" AS
  SELECT * FROM (VALUES ('2.2.5', 2, 2, 5))
  AS "subquery"("string", "major", "minor", "revision");

ALTER TABLE "issue" ADD COLUMN "admin_notice" TEXT;
COMMENT ON COLUMN "issue"."admin_notice" IS 'Public notice by admin to explain manual interventions, or to announce corrections';

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

COMMENT ON TABLE "direct_population_snapshot" IS 'Snapshot of active members having either a "membership" in the "area" or an "interest" in the "issue"; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_population_snapshot" IS 'Delegations increasing the weight of entries in the "direct_population_snapshot" table; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_interest_snapshot" IS 'Snapshot of active members having an "interest" in the "issue"; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "delegating_interest_snapshot" IS 'Delegations increasing the weight of entries in the "direct_interest_snapshot" table; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_supporter_snapshot" IS 'Snapshot of supporters of initiatives (weight is stored in "direct_interest_snapshot"); for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "direct_voter" IS 'Members having directly voted for/against initiatives of an issue; frontends must ensure that no voters are added or removed to/from this table when the issue has been closed; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "delegating_voter" IS 'Delegations increasing the weight of entries in the "direct_voter" table; for corrections refer to column "issue_notice" of "issue" table';
COMMENT ON TABLE "vote" IS 'Manual and delegated votes without abstentions; frontends must ensure that no votes are added modified or removed when the issue has been closed; for corrections refer to column "issue_notice" of "issue" table';

COMMIT;

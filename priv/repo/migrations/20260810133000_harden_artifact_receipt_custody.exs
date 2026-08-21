defmodule SpruceGoose.Repo.Migrations.HardenArtifactReceiptCustody do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION enforce_artifact_receipt_readiness()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = ''
    AS $$
    DECLARE
      requirement text;
      receipt jsonb;
      digest text;
    BEGIN
      IF NEW.state = 'ready' THEN
        FOREACH requirement IN ARRAY NEW.artifact_requirements LOOP
          IF NOT EXISTS (
            SELECT 1 FROM unnest(NEW.artifact_receipts) AS candidate
            WHERE candidate->>'name' = requirement
          ) THEN
            RAISE EXCEPTION 'missing verified artifact receipt for %', requirement
              USING ERRCODE = '23514';
          END IF;
        END LOOP;

        FOREACH receipt IN ARRAY NEW.artifact_receipts LOOP
          digest := receipt->>'sha256';

          IF (SELECT count(*) FROM jsonb_object_keys(receipt)) <> 7
             OR NOT (receipt ?& ARRAY['name','sha256','size_bytes','storage_locator',
                                      'source_identity','retrieval_verifier',
                                      'retrieval_verified_at'])
             OR digest !~ '^[0-9a-f]{64}$'
             OR receipt->>'storage_locator' <> 'cas:sha256:' || digest
             OR (receipt->>'size_bytes')::bigint <= 0
             OR char_length(receipt->>'source_identity') NOT BETWEEN 1 AND 512
             OR char_length(receipt->>'retrieval_verifier') NOT BETWEEN 1 AND 64
             OR (receipt->>'retrieval_verified_at')::timestamptz > statement_timestamp()
          THEN
            RAISE EXCEPTION 'invalid verified artifact receipt'
              USING ERRCODE = '23514';
          END IF;
        END LOOP;
      END IF;

      RETURN NEW;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'workflow_tasks_artifact_receipt_guard'
          AND NOT tgisinternal
      ) THEN
        CREATE TRIGGER workflow_tasks_artifact_receipt_guard
        BEFORE INSERT OR UPDATE OF state, artifact_requirements, artifact_receipts
        ON workflow_tasks
        FOR EACH ROW EXECUTE FUNCTION enforce_artifact_receipt_readiness();
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM workflow_tasks
        WHERE cardinality(artifact_requirements) > 0
           OR cardinality(artifact_receipts) > 0
      ) THEN
        RAISE EXCEPTION 'refusing rollback: artifact custody evidence exists';
      END IF;
    END
    $$;
    """)

    execute("DROP TRIGGER IF EXISTS workflow_tasks_artifact_receipt_guard ON workflow_tasks")
    execute("DROP FUNCTION IF EXISTS enforce_artifact_receipt_readiness()")
  end
end

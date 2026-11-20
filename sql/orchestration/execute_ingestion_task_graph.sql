-- Newly created tasks are suspended. Resume only the child tasks; the root
-- remains suspended and has no schedule, so it runs only when manually invoked.
ALTER TASK SKYPOINTS_DB.RAW.TASK_REDEMPTION_INGESTION RESUME;
ALTER TASK SKYPOINTS_DB.RAW.TASK_INGESTION_VALIDATION RESUME;

-- Single command to trigger and wait for the full graph.
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;

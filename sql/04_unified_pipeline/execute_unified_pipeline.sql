-- Run only after deploy_unified_pipeline.sql.
-- Returns a run ID, Snowflake graph-run ID, and outcome; a task failure is re-raised
-- after cleanup. Failed reconciliation checks fail the task graph after their
-- individual check rows and reconciliation execution error are persisted.
CALL SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE();

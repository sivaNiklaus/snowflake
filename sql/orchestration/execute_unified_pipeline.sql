-- Run only after deploy_unified_pipeline.sql.
-- Returns a run ID, Snowflake graph-run ID, and outcome; a task failure is re-raised
-- after all descendants are suspended and the original error is audited.
CALL SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE();

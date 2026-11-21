-- Compatibility entry point for the complete Phase 3-6C graph.
-- Deploy deploy_unified_pipeline.sql first; the controlled procedure manages
-- overlap protection, task resumption, completion, audit, and cleanup.
CALL SKYPOINTS_DB.AUDIT.SP_RUN_COMPLETE_PIPELINE();

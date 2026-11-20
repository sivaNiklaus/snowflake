-- Deployment resumes child tasks in dependency order. This command triggers
-- the suspended root manually and waits for the full graph.
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;

-- Deployment resumes the graph in child-to-root order. This command triggers
-- the root manually and waits for the full graph.
EXECUTE TASK SKYPOINTS_DB.RAW.TASK_MEMBER_INGESTION AWAIT;

-- Account-level setup. Run once with a role that can create storage integrations.
-- Replace <AWS_IAM_ROLE_ARN>, <AWS_S3_BUCKET>, and both prefix placeholders
-- with deployment-specific values. Prefixes must end in '/'.
-- Keep the two allowed locations aligned with the stage URLs in
-- sources/definitions/02_raw_ingestion.sql.
CREATE STORAGE INTEGRATION SKYPOINTS_S3_STORAGE_INT
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    STORAGE_AWS_ROLE_ARN = '<AWS_IAM_ROLE_ARN>'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS =
    (
        's3://<AWS_S3_BUCKET>/<AWS_S3_MEMBERS_PREFIX>',
        's3://<AWS_S3_BUCKET>/<AWS_S3_REDEMPTIONS_PREFIX>'
    )
    COMMENT = 'Read-only access for SkyPoints raw S3 ingestion';

DESC INTEGRATION SKYPOINTS_S3_STORAGE_INT;

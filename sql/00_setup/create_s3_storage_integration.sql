-- Rendered by manage.py from config/<target>.yml.
-- The lifecycle creates this only when it is absent; IF NOT EXISTS also makes
-- the rendered setup safe to rerun without replacing an existing integration.
CREATE STORAGE INTEGRATION IF NOT EXISTS {{INTEGRATION}}
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    STORAGE_AWS_ROLE_ARN = '{{AWS_IAM_ROLE_ARN}}'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS =
    (
        's3://{{S3_BUCKET}}/{{MEMBER_PREFIX}}',
        's3://{{S3_BUCKET}}/{{REDEMPTION_PREFIX}}'
    )
    COMMENT = 'Read-only access for SkyPoints raw S3 ingestion';

DESC INTEGRATION {{INTEGRATION}};

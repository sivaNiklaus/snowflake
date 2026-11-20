# SQL scripts

Snowflake CLI DCM Projects only reads project definitions from
`sources/definitions/`; see [01_foundation.sql](../sources/definitions/01_foundation.sql).
This directory is reserved for standalone SQL utilities and one-time bootstrap
scripts that are not DCM definitions.

Run [bootstrap_dcm.sql](./bootstrap_dcm.sql) once with an authorized Snowflake
CLI connection to create the database and schema that host the DCM project
object. The DCM project subsequently manages the declared database, schemas,
and warehouse.

## S3 storage integration (account-level)

[create_s3_storage_integration.sql](./create_s3_storage_integration.sql) is a
one-time account-level setup, separate from normal DCM deployment. An
administrator with the required account privilege must replace the IAM role
ARN, bucket, and both prefix placeholders and run the script before deploying
the ingestion definitions. Prefixes must end in `/`. Use the same values in
the external stage URLs in `sources/definitions/02_raw_ingestion.sql`.

After running the script, inspect `DESC INTEGRATION SKYPOINTS_S3_STORAGE_INT`.
In the output, use `STORAGE_AWS_IAM_USER_ARN` as the trusted principal and
`STORAGE_AWS_EXTERNAL_ID` as the `sts:ExternalId` condition on the AWS IAM
role. The trust relationship has this shape; substitute the values returned
by Snowflake:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "<STORAGE_AWS_IAM_USER_ARN>" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>"
        }
      }
    }
  ]
}
```

Attach a separate least-privilege S3 policy allowing `s3:ListBucket` on the
configured bucket (restricted by the configured prefixes) and `s3:GetObject`
and `s3:GetObjectVersion` on objects under those prefixes. Never put AWS
access keys in Snowflake or this repository.

## Deploying and enabling the two pipes

After AWS trust and bucket access are configured, create/plan/deploy the DCM
project using the existing workflow in the root README. Then, for each pipe,
run `DESC PIPE SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE` and
`DESC PIPE SKYPOINTS_DB.RAW.REDEMPTION_PIPE`. In the result, use
`notification_channel` as the target for an S3 event notification. Configure
`ObjectCreated` events for the matching `members/` or `redemptions/` prefix.
Each pipe has its own Snowflake-managed SQS queue; do not share or substitute
the queue between prefixes.

Member files must contain exactly 12 delimited fields per row. The first field
is intentionally empty for the supplied leading delimiter; the next field
retains the `H` or `D` record indicator. Column-count mismatches fail the
whole file (`ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE`, `ON_ERROR = SKIP_FILE`)
instead of truncating extra fields or skipping individual rows. Check pipe
load history and correct a failed file, then republish it under a new object
key; valid records in a malformed file are not loaded until corrected. No
business validation or transformation is performed.

Redemption files are stored as complete JSON documents in `PAYLOAD` (`VARIANT`),
including nested arrays. They are not flattened. Both raw tables include
source filename, row number, content key, and Snowpipe scan timestamp metadata.

# Snowflake SQL deployment

DCM Project object definitions belong under `sources/definitions/`; Snowflake
CLI does not upload SQL files from this directory. Phase 2 keeps the database,
schemas, warehouse, file formats, raw tables, and external stages in DCM.
Snowflake's DCM `DEFINE PIPE` feature is Preview, so the two pipes are created
separately with conventional `CREATE PIPE` statements under `sql/ingestion/`.

## Deployment order

Deploy these steps in order:

1. **Account-level storage integration.** Set the S3 bucket and prefix
   placeholders consistently in
   [create_s3_storage_integration.sql](./create_s3_storage_integration.sql)
   and `sources/definitions/02_raw_ingestion.sql`. Run the account-level script
   with a role that can create storage integrations (typically `ACCOUNTADMIN`):

   ```powershell
   snow sql --connection <connection_name> --filename sql/create_s3_storage_integration.sql
   ```

   The integration requires the AWS IAM role ARN. After the integration is
   created, inspect `DESC INTEGRATION SKYPOINTS_S3_STORAGE_INT`. Configure the
   AWS role trust relationship with `STORAGE_AWS_IAM_USER_ARN` as the trusted
   principal and `STORAGE_AWS_EXTERNAL_ID` as the `sts:ExternalId` condition:

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

   Grant that AWS role only `s3:ListBucket` for the configured prefixes and
   `s3:GetObject` / `s3:GetObjectVersion` for objects under them. Do not put
   AWS credentials in this repository.

2. **DCM-managed objects.** Use the root README's DCM workflow to bootstrap
   the host schema, create the project, review `snow dcm plan`, and deploy.
   The integration must exist before DCM creates the external stages.

3. **Standalone pipes.** After the stages and raw tables exist, execute both
   pipe scripts with an appropriately privileged Snowflake connection:

   ```powershell
   snow sql --connection <connection_name> --filename sql/ingestion/create_member_profile_pipe.sql
   snow sql --connection <connection_name> --filename sql/ingestion/create_redemption_pipe.sql
   ```

   Each script creates one independent pipe with `AUTO_INGEST = TRUE`. Re-run
   DCM after changing DCM-managed objects; pipe definitions are managed by
   these standalone scripts.

4. **S3 event notifications.** Run `DESC PIPE
   SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE` and `DESC PIPE
   SKYPOINTS_DB.RAW.REDEMPTION_PIPE`; inspect the `notification_channel`
   returned for each. Snowflake may reuse a notification queue for multiple
   pipes in the same AWS region; do not assume one queue per pipe.

   In the S3 bucket notification configuration, route `ObjectCreated` events
   for the members prefix to the member pipe's queue and events for the
   redemptions prefix to the redemption pipe's queue. If both pipes report the
   same queue, configure two rules targeting that queue with the disjoint
   prefixes. If the channels differ, target each rule to its corresponding
   queue. Do not add a prefix-less `ObjectCreated` rule or overlapping prefix
   rules for the same event types. Check existing bucket notifications too:
   prefixes such as `members/` and `members/archive/` overlap.

## Raw member record preservation

The assessment's formal member specification includes `Post_Code`, while the
supplied flat-file sample does not. The member CSV file format therefore uses
`FIELD_DELIMITER = NONE`, with the normal newline record delimiter, and the
pipe copies `$1` directly to `SOURCE_RECORD`. `MULTI_LINE = FALSE`, no field
enclosure, and `ESCAPE_UNENCLOSED_FIELD = NONE` keep line boundaries literal.
This supported CSV configuration loads each complete physical source line as
one `VARCHAR`: the leading pipe, `H`/`D` indicator, delimiters, and all fields
are preserved, regardless of field count or later source-layout changes. No
field parsing or business transformation occurs in this phase.

The fixture intentionally contains both the sample layout and a record with
an additional field, representing the formal `Post_Code` discrepancy. Blank
or otherwise malformed files still fail visibly under `ON_ERROR = SKIP_FILE`;
correct and republish a failed file under a new S3 object key.

Redemption files use a JSON file format with `STRIP_OUTER_ARRAY = FALSE`.
Each top-level JSON document is copied intact to `PAYLOAD` (`VARIANT`), so
nested redemption arrays—including empty arrays—are not flattened.

## Local and account smoke tests

Run the local fixture and definition checks before deploying:

```powershell
python -m pytest
```

After configuring S3 notifications, upload the fixtures under their matching
prefixes using unique object names. Verify the raw member lines and metadata:

```sql
SELECT SOURCE_RECORD, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
       SOURCE_FILE_CONTENT_KEY, INGESTED_AT
FROM SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW
ORDER BY INGESTED_AT, SOURCE_ROW_NUMBER;
```

Verify redemption documents and metadata:

```sql
SELECT PAYLOAD, SOURCE_FILENAME, SOURCE_ROW_NUMBER,
       SOURCE_FILE_CONTENT_KEY, INGESTED_AT
FROM SKYPOINTS_DB.RAW.REDEMPTION_RAW
ORDER BY INGESTED_AT, SOURCE_ROW_NUMBER;
```

These queries should show the `H` and `D` member lines unchanged, and each
redemption document as one `VARIANT` value.

## Monitoring

Check each pipe's current execution state, pending files, and notification
queue:

```sql
SELECT SYSTEM$PIPE_STATUS('SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE');
SELECT SYSTEM$PIPE_STATUS('SKYPOINTS_DB.RAW.REDEMPTION_PIPE');
```

Review recent load outcomes and parse errors (the history function covers the
last 14 days):

```sql
SELECT FILE_NAME, LAST_LOAD_TIME, STATUS, ROW_COUNT, ERROR_COUNT,
       FIRST_ERROR_MESSAGE
FROM TABLE(SKYPOINTS_DB.INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SKYPOINTS_DB.RAW.MEMBER_PROFILE_RAW',
    START_TIME => DATEADD('DAY', -7, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;
```

Use the redemption raw table name in the query to inspect that pipe. Failed
files are not partially loaded; correct and republish them under a new object
key. AWS resources, IAM trust, event notifications, and live Snowflake
deployment must be configured and verified per environment.

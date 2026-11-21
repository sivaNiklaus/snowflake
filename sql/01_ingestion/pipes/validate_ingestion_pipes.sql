EXECUTE IMMEDIATE $$
DECLARE
    e_member_pipe_mismatch EXCEPTION
        (-20081, 'MEMBER_PROFILE_PIPE does not use the project member stage and raw table');
    e_redemption_pipe_mismatch EXCEPTION
        (-20082, 'REDEMPTION_PIPE does not use the project redemption stage and raw table');
    v_member_ddl VARCHAR;
    v_redemption_ddl VARCHAR;
BEGIN
    SELECT GET_DDL(
        'PIPE',
        'SKYPOINTS_DB.RAW.MEMBER_PROFILE_PIPE'
    ) INTO :v_member_ddl;
    IF (
        POSITION('MEMBER_S3_STAGE' IN UPPER(v_member_ddl)) = 0
        OR POSITION('MEMBER_PROFILE_RAW' IN UPPER(v_member_ddl)) = 0
        OR POSITION('MEMBER_PROFILE_CSV' IN UPPER(v_member_ddl)) = 0
    ) THEN
        RAISE e_member_pipe_mismatch;
    END IF;

    SELECT GET_DDL(
        'PIPE',
        'SKYPOINTS_DB.RAW.REDEMPTION_PIPE'
    ) INTO :v_redemption_ddl;
    IF (
        POSITION('REDEMPTION_S3_STAGE' IN UPPER(v_redemption_ddl)) = 0
        OR POSITION('REDEMPTION_RAW' IN UPPER(v_redemption_ddl)) = 0
        OR POSITION('REDEMPTION_JSON' IN UPPER(v_redemption_ddl)) = 0
    ) THEN
        RAISE e_redemption_pipe_mismatch;
    END IF;
END;
$$;

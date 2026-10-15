-- Test helpers, loaded into the same session before each test file.
-- Session-local (pg_temp) so nothing is left behind in the database.

-- Asserts that p_sql fails with SQLSTATE p_sqlstate and a message matching p_message_like.
CREATE OR REPLACE FUNCTION pg_temp.assert_raises(p_sql text, p_sqlstate text, p_message_like text DEFAULT '%')
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_state   text;
    v_message text;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    END;

    IF v_state IS NULL THEN
        RAISE EXCEPTION 'FAIL: expected SQLSTATE % but statement succeeded: %', p_sqlstate, p_sql;
    END IF;
    IF v_state <> p_sqlstate OR v_message NOT LIKE p_message_like THEN
        RAISE EXCEPTION 'FAIL: expected % "%", got % "%" for: %',
            p_sqlstate, p_message_like, v_state, v_message, p_sql;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.pass(p_name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'PASS  %', p_name;
END;
$$;

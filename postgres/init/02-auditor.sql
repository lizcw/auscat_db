CREATE EXTENSION IF NOT EXISTS pgaudit;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_roles
        WHERE rolname = 'pgaudit_auditor'
    ) THEN
        CREATE ROLE pgaudit_auditor NOLOGIN;
    END IF;
END
$$;

-- Existing tables
GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA public
TO pgaudit_auditor;

-- Future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLES
TO pgaudit_auditor;

-- Remove Read from all but Key Table (example)
-- REVOKE SELECT
-- ON ALL TABLES IN SCHEMA public
-- FROM pgaudit_auditor;

-- GRANT SELECT
-- ON TABLE public.key_data
-- TO pgaudit_auditor;

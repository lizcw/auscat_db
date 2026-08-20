#!/bin/bash
set -e

POSTGRES_RW_PASSWORD="$(cat /run/secrets/postgres_rw_password)"

psql \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set=rw_user="$POSTGRES_RW_USER" \
    --set=rw_password="$POSTGRES_RW_PASSWORD" <<-'EOSQL'

CREATE EXTENSION IF NOT EXISTS pgaudit;

-- Create the read/write login.
SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
    :'rw_user',
    :'rw_password'
)
WHERE NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = :'rw_user'
)\gexec

-- Allow connection to this database.
SELECT format(
    'GRANT CONNECT ON DATABASE %I TO %I',
    current_database(),
    :'rw_user'
)\gexec

-- Allow use of public schema.
SELECT format(
    'GRANT USAGE ON SCHEMA public TO %I',
    :'rw_user'
)\gexec

-- Read/write existing tables.
SELECT format(
    'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %I',
    :'rw_user'
)\gexec

-- Required for SERIAL / identity-backed sequences.
SELECT format(
    'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %I',
    :'rw_user'
)\gexec

-- Automatically grant access to future tables.
SELECT format(
    'ALTER DEFAULT PRIVILEGES IN SCHEMA public
     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
    :'rw_user'
)\gexec

-- Automatically grant access to future sequences.
SELECT format(
    'ALTER DEFAULT PRIVILEGES IN SCHEMA public
     GRANT USAGE, SELECT ON SEQUENCES TO %I',
    :'rw_user'
)\gexec

EOSQL

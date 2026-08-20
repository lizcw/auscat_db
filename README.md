# PostgreSQL Audit and Read-Only Access

This PostgreSQL deployment is configured with:

* **pgAudit** for database auditing
* A dedicated **read-only database user**
* Docker secrets for database passwords
* Persistent PostgreSQL audit logs
* Optional pgAdmin access
* PostgreSQL configuration managed through a version-controlled `postgresql.conf`

## Directory Structure

```text
.
├── docker-compose.yml
├── .env
├── postgres/
│   ├── Dockerfile
│   ├── config/
│   │   └── postgresql.conf
│   └── init/
│       └── 01-init.sh
├── pgadmin/
│   └── servers.json
└── secrets/
    ├── postgres_admin_password.txt
    ├── postgres_readonly_password.txt
    └── pgadmin_password.txt
```

The contents of the `secrets/` directory must not be committed to source control.

For example:

```gitignore
secrets/*
!secrets/.gitkeep
```

## PostgreSQL Image

pgAudit must be installed in the PostgreSQL container image.

For PostgreSQL 13:

```dockerfile
FROM postgres:13

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       postgresql-13-pgaudit \
    && rm -rf /var/lib/apt/lists/*
```

The pgAudit package version must be compatible with the PostgreSQL version used by the project.

## PostgreSQL Configuration

PostgreSQL is configured using:

```text
postgres/config/postgresql.conf
```

rather than passing multiple `-c` arguments through Docker Compose.

Example:

```conf
# ---------------------------------------------------------------------------
# Extensions
# ---------------------------------------------------------------------------

shared_preload_libraries = 'pgaudit'

# ---------------------------------------------------------------------------
# pgAudit
# ---------------------------------------------------------------------------

pgaudit.log = 'write,ddl,role'
pgaudit.role = 'pgaudit_auditor'
pgaudit.log_relation = on
pgaudit.log_parameter = off

# ---------------------------------------------------------------------------
# Connection logging
# ---------------------------------------------------------------------------

log_connections = on
log_disconnections = on

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging_collector = on
log_destination = 'stderr'
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d.log'

log_rotation_age = '1d'
log_truncate_on_rotation = on
```

The configuration file is mounted into the container and supplied to PostgreSQL using:

```yaml
command:
  - postgres
  - -c
  - config_file=/etc/postgresql/postgresql.conf
```

and:

```yaml
volumes:
  - ./postgres/config/postgresql.conf:/etc/postgresql/postgresql.conf:ro
```

## pgAudit Configuration

pgAudit is loaded when PostgreSQL starts using:

```conf
shared_preload_libraries = 'pgaudit'
```

The extension must also be created within the database:

```sql
CREATE EXTENSION IF NOT EXISTS pgaudit;
```

### Session Auditing

The following configuration:

```conf
pgaudit.log = 'write,ddl,role'
```

logs:

* `INSERT`
* `UPDATE`
* `DELETE`
* schema changes such as `CREATE`, `ALTER` and `DROP`
* role and privilege changes

General `SELECT` statements are deliberately not enabled because read auditing across the entire database can produce a very large number of audit records.

## Object-Level Read Auditing

Where read access to a specific sensitive table must be audited, pgAudit object auditing is used.

A dedicated audit role is created:

```sql
CREATE ROLE pgaudit_auditor NOLOGIN;
```

and configured in PostgreSQL:

```conf
pgaudit.role = 'pgaudit_auditor'
```

The role is not used to connect to the database. Its privileges define which database objects should receive additional pgAudit object auditing.

For example, to audit reads of a specific table:

```sql
GRANT SELECT
ON TABLE public.sensitive_data
TO pgaudit_auditor;
```

`SELECT` operations on `public.sensitive_data` will therefore be audited, while reads from other tables will not.

Additional operations can also be audited for a specific object if required:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE public.sensitive_data
TO pgaudit_auditor;
```

If `write` auditing is already enabled globally through:

```conf
pgaudit.log = 'write,ddl,role'
```

only the additional `SELECT` privilege is normally required for object-level read auditing.

## Read-Only Database User

A separate PostgreSQL login is created for users who require access to view database contents without modifying them.

For example:

```sql
CREATE ROLE read_only
LOGIN
NOSUPERUSER
NOCREATEDB
NOCREATEROLE
NOREPLICATION;
```

The password is supplied from a Docker secret rather than being stored in source control.

The user is granted access to the database and schema:

```sql
GRANT CONNECT ON DATABASE project TO read_only;

GRANT USAGE ON SCHEMA public TO read_only;
```

Read access is then granted to all existing tables:

```sql
GRANT SELECT
ON ALL TABLES IN SCHEMA public
TO read_only;
```

If access to sequences is required:

```sql
GRANT SELECT
ON ALL SEQUENCES IN SCHEMA public
TO read_only;
```

### Future Tables

Permissions granted using `ALL TABLES IN SCHEMA` only affect tables that already exist.

Default privileges should therefore also be configured so that newly created tables are automatically available to the read-only role:

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT
ON TABLES
TO read_only;
```

If tables are created by a specific application or migration role, the default privileges should be configured for that role:

```sql
ALTER DEFAULT PRIVILEGES
FOR ROLE application_user
IN SCHEMA public
GRANT SELECT
ON TABLES
TO read_only;
```

This is important because PostgreSQL default privileges apply to objects created by the specified role.

## Docker Secrets

Database passwords are stored as Docker Compose secrets.

For example:

```yaml
secrets:
  postgres_admin_password:
    file: ./secrets/postgres_admin_password.txt

  postgres_readonly_password:
    file: ./secrets/postgres_readonly_password.txt

  pgadmin_password:
    file: ./secrets/pgadmin_password.txt
```

The PostgreSQL service receives the secrets as files:

```yaml
secrets:
  - postgres_admin_password
  - postgres_readonly_password
```

The PostgreSQL administrator password uses the `_FILE` mechanism supported by the official PostgreSQL image:

```yaml
environment:
  POSTGRES_PASSWORD_FILE: /run/secrets/postgres_admin_password
```

The read-only user password can be read by the database initialisation script from:

```text
/run/secrets/postgres_readonly_password
```

For example:

```bash
POSTGRES_READONLY_PASSWORD="$(cat "$POSTGRES_READONLY_PASSWORD_FILE")"
```

Passwords should never be committed to the repository.

## Database Initialisation

Database setup scripts are mounted into:

```text
/docker-entrypoint-initdb.d
```

For example:

```yaml
volumes:
  - ./postgres/init:/docker-entrypoint-initdb.d:ro
```

The initialisation script can create:

* the `pgaudit` extension
* the `pgaudit_auditor` role
* the `read_only` login
* required database privileges
* default privileges for future tables

An important limitation is that scripts under `/docker-entrypoint-initdb.d` are only executed when PostgreSQL initialises a **new, empty data directory**.

If the `postgres_data` volume already exists, changing an initialisation script will not automatically apply those changes to the existing database.

Database role or privilege changes must then be applied manually or through the project's database migration process.

## Audit Logs

pgAudit does not maintain a separate audit file. Audit records are written through PostgreSQL's normal logging system and can be identified by entries containing:

```text
AUDIT:
```

Logging is configured to write to:

```text
/var/log/postgresql
```

A persistent Docker volume should be used:

```yaml
volumes:
  - postgres_logs:/var/log/postgresql
```

with:

```yaml
volumes:
  postgres_data:
  postgres_logs:
```

Log files are generated daily using:

```conf
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = '1d'
```

For example:

```text
postgresql-2026-08-20.log
postgresql-2026-08-21.log
postgresql-2026-08-22.log
```

The log files can be inspected from the container using:

```bash
docker compose exec postgres ls -l /var/log/postgresql
```

or:

```bash
docker compose exec postgres \
  cat /var/log/postgresql/postgresql-2026-08-20.log
```

PostgreSQL log rotation does not provide log retention. A separate retention or archival mechanism should therefore be configured according to project security and audit requirements.

## Network Access

PostgreSQL does not need to publish its database port to the host if it is accessed only by other Docker Compose services.

For example:

```yaml
expose:
  - "5432"
```

or the `expose` declaration may be omitted entirely because Compose services on the same Docker network can communicate directly.

pgAdmin connects internally using:

```text
Host: postgres
Port: 5432
```

There is therefore normally no need for:

```yaml
ports:
  - "5432:5432"
```

unless applications outside the Docker environment require direct database access.

## Summary

The configuration provides two complementary security controls:

1. **pgAudit** records database modification, administrative activity and selected access to sensitive tables.
2. The **read-only user** allows authorised users to inspect database data without being able to modify the database.

General database reads are not audited by default. Where read access to particularly sensitive information must be recorded, `SELECT` auditing can be enabled selectively using the `pgaudit_auditor` object-audit role.

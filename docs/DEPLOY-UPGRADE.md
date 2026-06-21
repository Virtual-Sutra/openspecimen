# Deploy and Upgrade

Day-1 fresh install, Day-2 upgrade, and rollback procedures for OpenSpecimen.

---

## How version detection works

The playbooks use the marker file `/usr/local/openspecimen/.release` on the
target node to determine what is currently installed, then compare against the
requested `openspecimen_release` using natural version sort (`sort -V`):

- **Marker absent** → fresh install (all five roles run in order)
- **Marker present, same version** → re-deploy (idempotent run)
- **Marker present, requested > installed** → upgrade (backup → deploy → restart)
- **Marker present, requested < installed** → automatic rollback (see "Rollback" below) —
  the requested version's backup is restored and the play ends. No separate job needed.

`openspecimen_release` is always supplied at run time via
`-e openspecimen_release=<name>`. It is **not** stored in inventory `group_vars`.

Direction detection runs as the **first** pre_task in both `site.yml` and
`deploy.yml` — `roles/openspecimen/tasks/direction.yml`. When a downgrade is
detected, the play dispatches to `tasks_from: rollback` (target_version =
requested release) and ends; the remaining roles never run.

---

## Prerequisites

Before deploying:
- Customer inventory exists under `inventory/customers/<name>/`
- The release zip is accessible on the Ansible controller
- The database password is available to pass via `-e` or your CI/CD secrets manager
- Any paid or customer plugin zips referenced in inventory are placed alongside the release zip

---

## Pre-flight checks

Every play (`site.yml` or `deploy.yml`) runs a pre_task block that fails fast — **before any
target modification** — if the operator's inputs are wrong. Checks include:

- `openspecimen_release` is set and matches the expected `openspecimen_<version>` format
- `openspecimen_builds_dir` is set
- `mysql_db_password` is set when `db_managed=true`
- The release zip exists at `openspecimen_zip_path` on the control node
- Every plugin name in `openspecimen_paid_plugins` and `openspecimen_customer_plugins`
  has a matching `<name>-<version>.zip` file under `openspecimen_builds_dir`

When a check fails, the operator gets a structured message with the exact path/value that
was wrong, what to check, and how to fix it — for example:

```
✗ Paid plugin zip not found anywhere under /var/lib/jenkins/jobs.

Plugin name:    os-automated-freezers
Expected file:  os-automated-freezers-v12.2.RC12.zip
Customer:       k-testvm

What to check:
  1. Is the plugin zip uploaded to the same directory as the release zip on Jenkins?
     Run on Jenkins VM:
       find /var/lib/jenkins/jobs -name 'os-automated-freezers*'
  ...
```

---

## Day-1: Fresh Install

```bash
ansible-galaxy collection install -r requirements.yml

ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e mysql_db_password=<password>
```

`openspecimen_zip_path` defaults to
`{{ openspecimen_builds_dir }}/{{ openspecimen_release }}.zip`
(`/opt/openspecimen/builds/<release>.zip` on the target node) if not passed.

---

## Day-2: Upgrade

Use `deploy.yml` when only the WAR and plugins need updating and the
infrastructure (MySQL, Tomcat config) is already correct. Skips infra roles.

```bash
ansible-playbook -i inventory/customers/<name>/ deploy.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e mysql_db_password=<password>
```

The playbook:
1. Runs the pre-flight check (release zip + every plugin zip present on the controller)
2. Reads the marker file on the target node to detect the current version
3. Stops the service
4. Backs up WAR and plugins to `openspecimen_backup_dir/<timestamp>/`
5. Deploys the new WAR and plugins (default from release zip; paid + customer from separate zips)
6. Prunes old backups beyond `openspecimen_backup_retention` (default 3)
7. Starts the service and polls the health check

### Dry-run

```bash
ansible-playbook ... --check
```

---

## Plugin deployment

OpenSpecimen ships with **default plugins** bundled in the release zip
(`os-distribution-invoicing`, `os-task-manager`, `os-edc`, `os-extras`). These are extracted
to `plugins/default/` automatically — no inventory configuration is needed.

Two additional tiers are supported for plugins delivered as separate zips alongside the release zip:

| Tier | Inventory variable | Deployed to | Use case |
|------|--------------------|-----------------|---------|
| Paid | `openspecimen_paid_plugins` | `plugins/paid/` | Licensed enterprise plugins |
| Customer | `openspecimen_customer_plugins` | `plugins/zustomer/` | Customer-specific plugins |

### Naming convention

Inventory lists **plugin names only** — no version, no extension. The role derives the zip
filename at runtime:

```
<plugin-name>-<version>.zip
```

`<version>` is derived from `openspecimen_release` by stripping the `openspecimen_` prefix.
Example: with `openspecimen_release=openspecimen_v12.2.RC12` and inventory entry
`os-automated-freezers`, the role looks for `os-automated-freezers-v12.2.RC12.zip`.

This means **inventory does not need to be updated on every OpenSpecimen upgrade** — only the
plugin zip on disk needs to be replaced with the new version.

### Where to place the plugin zip

The plugin zip must live in the same directory as the release zip on the Ansible control node
(or in any subdirectory of `openspecimen_builds_dir`). Each zip must contain at least one `.jar`
file — `unzip -jo` extracts JARs from any path inside the zip.

### Inventory example

```yaml
# inventory/host_vars/<customer>.yml
openspecimen_paid_plugins:
  - os-automated-freezers
  - enterprise-billing

openspecimen_customer_plugins:
  - acme-custom-workflow
```

> **Important:** put these in `inventory/host_vars/<customer>.yml`, **not** in
> `inventory/customers/<customer>/group_vars/openspecimen.yml`. Per-customer `group_vars/`
> subdirectories are skipped when Ansible runs with `-i inventory/` (as the Jenkins pipeline does).

---

## Backup retention

At the end of every deploy, the openspecimen role lists all timestamped backup subdirectories
under `openspecimen_backup_dir` (excluding `config-changes/`), sorts them by modification time
descending, and removes everything beyond `openspecimen_backup_retention`.

Default: **3**. Override per customer in `inventory/host_vars/<customer>.yml`:

```yaml
openspecimen_backup_retention: 10   # keep more for prod customer
```

Or at run time:

```bash
-e openspecimen_backup_retention=5
```

Each timestamped directory holds a complete snapshot:

```
{{ openspecimen_backup_dir }}/<DDMMYYYY_HHMMSS>/
  ├─ openspecimen.war
  ├─ plugins/{default,paid,zustomer}/*.jar
  └─ lib/mysql-connector-*.jar
```

---

## Day-2: Rollback

Rollback has two paths — both backed by the same `roles/openspecimen/tasks/rollback.yml`:

### A. Automatic (via deploy job — recommended)

Just pick a lower release in `site.yml` / `deploy.yml` (or in the Jenkins
deploy job). Direction detection notices the requested version is older than
what's installed, finds the backup whose `.release` matches the request,
runs the rollback, and ends the play. **No separate rollback job or playbook
invocation required.**

```bash
# Installed: openspecimen_v12.2.RC12, want to go back to RC8
ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e openspecimen_release=openspecimen_v12.2.RC8 \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

If no backup of the requested version exists, the play fails with a list of
available backups and the operator can either pick a version that does have
one or override with `-e allow_downgrade=true`.

### B. Explicit — direct rollback.yml invocation

Use this when you want to roll back to a specific backup directory (or the
most recent one) rather than a specific version.

**Most recent backup (default):**

```bash
ansible-playbook -i inventory/customers/<name>/ rollback.yml \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

**Specific timestamped backup** (list first, then pass):

```bash
ansible -i inventory/customers/<name>/ openspecimen -b \
  -a "ls /usr/local/openspecimen/backup/"
# example output: 17052026_093247  18052026_104530  19052026_110042

ansible-playbook -i inventory/customers/<name>/ rollback.yml \
  -e backup_timestamp=17052026_093247 \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

**Specific OpenSpecimen version** (let the playbook locate the matching backup):

```bash
ansible-playbook -i inventory/customers/<name>/ rollback.yml \
  -e target_version=openspecimen_v12.1.RC8 \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

### Dry run

```bash
ansible-playbook -i inventory/customers/<name>/ rollback.yml --check
```

Confirms the requested backup exists and contains a WAR without stopping the
service or moving any files.

### What gets restored

| Item | Restored from backup |
|------|---------------------|
| `openspecimen.war` | Yes — required, playbook fails if missing |
| `plugins/default/*.jar` | Yes (if present in backup) |
| `plugins/paid/*.jar` | Yes (if present in backup) |
| `plugins/zustomer/*.jar` | Yes (if present in backup) |
| `lib/mysql-connector-*.jar` | Yes (if present in backup) |
| `conf/openspecimen.properties` | Yes (if present in backup) — restores the exact config the old WAR ran with |
| `bin/setenv.sh` (JVM heap) | Yes (if present in backup) |
| `conf/context.xml` (JDBC pool) | Yes (if present in backup) |
| `/usr/local/openspecimen/.release` | Yes (if present in backup) — keeps the marker consistent with the live version |
| Database schema | **No** — Liquibase rollback is not modelled. See "Schema-downgrade safeguard" below. |

No separate `site.yml` run is needed for config — `rollback.yml` restores the
exact config snapshot taken at the time of the previous deploy.

### Schema-downgrade safeguard

Before stopping the service, the playbook queries Liquibase's
`DATABASECHANGELOG` table for changesets applied after the backup's mtime.
If any new migrations exist, the rollback **halts** with diagnostics:

```
✗ Schema-incompatible downgrade detected.

  Customer:        <name>
  Live release:    openspecimen_v12.2.RC12
  Backup release:  openspecimen_v12.1.RC8
  Backup mtime:    2026-05-04 09:42:12
  New migrations:  47 row(s) in DATABASECHANGELOG since backup

  What to check (list the offending changesets):
    mysql ... -e "SELECT ID, AUTHOR, FILENAME, DATEEXECUTED
                  FROM DATABASECHANGELOG
                  WHERE DATEEXECUTED > FROM_UNIXTIME(<backup_mtime>)
                  ORDER BY DATEEXECUTED ASC;"

  How to fix (pick one):
    1. Use a MORE RECENT backup that postdates the new migrations.
    2. Restore the database from an RDS snapshot before the backup time,
       then re-run rollback.
    3. Override (only if schema is known safe): -e allow_downgrade=true
```

This protects against rolling the WAR back to a version that doesn't know
about columns/tables the newer Liquibase migrations added — a class of failure
that's silent at startup but blows up at first user request.

To override after manual schema fix or a confirmed-safe downgrade:

```bash
ansible-playbook -i inventory/customers/<name>/ rollback.yml \
  -e allow_downgrade=true \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

### When no backup exists

The playbook fails fast with operator guidance and lists the available
backups. If all backups have been pruned (`openspecimen_backup_retention`
reached), use `deploy.yml` with the older release zip instead — there is
nothing to restore from.

---

## Variable reference

All defaults in `inventory/group_vars/all.yml`. Override per-customer in
`inventory/customers/<name>/group_vars/openspecimen.yml`. Pass credentials
via `-e mysql_db_password=<password>` (or your CI/CD secrets manager).

| Variable | Default | Notes |
|----------|---------|-------|
| `openspecimen_release` | _(required at run time)_ | Zip filename without `.zip` — e.g. `openspecimen_v12.3` |
| `openspecimen_zip_path` | `{{ openspecimen_builds_dir }}/{{ openspecimen_release }}.zip` | Path to the release zip on the controller or target |
| `openspecimen_builds_dir` | `/opt/openspecimen/builds` | Default location for release zips on the target node |
| `openspecimen_port` | `8080` | Tomcat HTTP port |
| `openspecimen_app_url` | _(unset)_ | Required for ALB / reverse proxy setup |
| `openspecimen_node_name` | _(unset)_ | Required for multi-node HA |
| `db_type` | `mysql` | `mysql` or `oracle` |
| `db_managed` | `true` | `false` skips MySQL role (RDS / external Oracle) |
| `mysql_db_host` | `127.0.0.1` | Set to RDS endpoint for external database |
| `tomcat_heap_min` | `512m` | JVM `-Xms` |
| `tomcat_heap_max` | auto (RAM × 0.5, min 2048 MB) | Override with `tomcat_heap_max_override` (integer MB) |
| `tomcat_pool_max_active` | `100` | JDBC connection pool size |
| `openspecimen_backup_dir` | `/usr/local/openspecimen/backup` | Timestamped backup location on upgrade |
| `openspecimen_backup_retention` | `3` | Number of timestamped backups to keep; older ones are pruned at end of deploy |
| `openspecimen_paid_plugins` | `[]` | List of paid plugin names (no version, no extension) — see [Plugin deployment](#plugin-deployment) |
| `openspecimen_customer_plugins` | `[]` | List of customer plugin names |
| `openspecimen_release_file` | _(unset)_ | Set by the Jenkins pipeline. When set, plugin search dir = `dirname(openspecimen_release_file)`. Otherwise the role searches recursively under `openspecimen_builds_dir`. |

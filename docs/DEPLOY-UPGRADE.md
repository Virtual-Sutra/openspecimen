# Deploy and Upgrade

Day-1 fresh install, Day-2 upgrade, and rollback procedures for OpenSpecimen.

---

## How a deploy is structured (host base + per-instance app)

`site.yml` deploys in two layers (ADR-006):

1. **Host-level base roles** (`common`, `java`, `mysql`, `tomcat`) install the
   shared OS prerequisites + the shared Tomcat binary. They run **once per host**,
   and only when at least one instance is a fresh install (missing/empty `.release`
   marker) or when `-e force_deploy=true`. On a normal upgrade they are skipped.
2. **Per-instance app roles** then loop over `openspecimen_instances`
   (`tasks/deploy-instance.yml`). Each instance gets its own direction detection,
   per-instance Tomcat runtime (`CATALINA_BASE`, ports, systemd unit), WAR + config
   + plugin deploy, Apache vhost, and public-URL verify.

A single-instance host (the default) has exactly one instance, so the loop runs
once (service `openspecimen`, `CATALINA_BASE` == `CATALINA_HOME`). Target one
instance with `-e instance=<name>`.

## How version detection works

Direction is detected **per instance** (not once for the whole host). For each
instance the playbook reads its `.release` marker on the target node to determine
what is currently installed, then compares against the requested release (the
instance's `release`, defaulting to `openspecimen_release`) using natural version
sort (`sort -V`):

- **Marker absent** → fresh install for that instance.
- **Marker present, same version** AND `.deploy_success` shows the prior deploy
  reached its last task AND every paid + customer plugin JAR matches the requested
  version AND `openspecimen.properties` is unchanged → **no-op** (that instance is
  skipped). Override with `-e force_deploy=true` (or the `FORCE_DEPLOY` checkbox in
  the Jenkins deploy job).
- **Marker present, same version** but `.deploy_success` is stale (last deploy failed
  before completing) → deploy re-runs; no operator flag needed.
- **Marker present, same version, only plugins drifted** (a plugin in inventory has
  no matching JAR, or an orphan JAR is on disk) → **plugins-only fast path**: skips
  the zip upload, WAR backup/extraction, and default-plugin extraction; runs only
  the plugin backup + orphan cleanup + paid/customer plugin install + restart.
- **Marker present, same version, only `openspecimen.properties` drifted** →
  **config-only fast path**: re-templates `openspecimen.properties` and restarts;
  skips all WAR and plugin steps.
- **Marker present, requested > installed** → upgrade (pre-upgrade backup → deploy
  → restart).
- **Marker present, requested is a downgrade** → automatic rollback for that instance
  (see "Rollback" below) - the requested version's backup is restored. A downgrade is
  any of: an older tagged release (`sort -V`), **`master` → any tagged release** (leaving
  the development HEAD for a tag), or **`master` → an older `master` snapshot** (compared
  by the `openspecimen_master-DD-MM-YYYY` date, since day-first dates misrank under
  `sort -V`). Moving from a `master` build to an older release therefore requires a
  matching backup. A tagged release → `master`, or `master` → a newer `master`, deploys
  forward.

Because direction is per instance, one instance rolling back or being already-current
does **not** stop the others - each instance's outcome is independent.

`openspecimen_release` is always supplied at run time via
`-e openspecimen_release=<name>`. It is **not** stored in inventory `group_vars`.

Direction detection runs first inside the per-instance loop
(`roles/openspecimen/tasks/direction.yml`, included from
`tasks/deploy-instance.yml`). When a downgrade is detected for an instance, that
instance dispatches to `tasks_from: rollback` (target_version = requested release)
and its own deploy steps are skipped - the loop continues with the next instance.

---

## Prerequisites

Before deploying:
- Customer inventory exists under `inventory/customers/<name>/` (or use
  `inventory/hosts-ec2.sample` / `inventory/hosts-local.sample`)
- The release zip is accessible on the Ansible controller
- The database password is available to pass via `-e` or your CI/CD secrets manager
- Any paid or customer plugin zips referenced in inventory are placed alongside the release zip

**Host / package prerequisites:**
- Ansible ≥ 2.15 + collections (`ansible-galaxy collection install -r requirements.yml`)
  and Python 3 ≥ 3.9 on the target
- **sudo/root** on the target - the roles use `become` to install packages and write system config
- **Outbound internet** (or a local mirror) so the roles can install Java, MySQL and
  Tomcat. On RHEL the `common` role enables **EPEL**; the `mysql` role adds the MySQL
  community repo
- Connectivity: SSH key from a controller, **or** run on the box itself with a localhost
  inventory (`ansible_connection=local`, no SSH) - see `inventory/hosts-local.sample`

---

## Pre-flight checks

Every play (`site.yml`) runs a pre_task block that fails fast - **before any
target modification** - if the operator's inputs are wrong. Checks include:

- `openspecimen_release` is set and matches the expected `openspecimen_<version>` format
- `openspecimen_builds_dir` is set
- `mysql_db_password` is set when the DB config is rendered this run (`db_managed=true`, or `db_managed=false` on a fresh host with no existing datasource)
- The release zip exists at `openspecimen_zip_path` on the control node
- Every plugin name in `openspecimen_paid_plugins` and `openspecimen_customer_plugins`
  has a matching `<name>-<version>.zip` file under `openspecimen_builds_dir`

When a check fails, the operator gets a structured message with the exact path/value that
was wrong, what to check, and how to fix it - for example:

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

A normal `site.yml` run on an existing install upgrades app-only (WAR + plugins);
`-e force_deploy=true` also re-runs the base roles. When only the WAR and plugins
need updating and the infrastructure (MySQL, Tomcat config) is already correct,
the base roles are skipped automatically.

```bash
ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e mysql_db_password=<password>
```

Per upgraded instance the playbook:
1. Runs the pre-flight check (release zip + every plugin zip present on the controller)
2. Reads the instance's marker file on the target node to detect the current version
3. Gates on database size, then (small DBs) backs up the database with `mysqldump`
   - see [Pre-upgrade database backup](#pre-upgrade-database-backup) below
4. Stops the service
5. Backs up WAR, plugins, config (`openspecimen.properties`, `setenv.sh`,
   `context.xml`) and the `.release` marker to
   `<instance backup_dir>/<timestamp>/`
6. Deploys the new WAR and plugins (default from release zip; paid + customer from separate zips)
7. Prunes old backups beyond `openspecimen_backup_retention` (default 3)
8. Starts the service and polls the health check

### Dry-run

```bash
ansible-playbook ... --check
```

---

## Pre-upgrade database backup

On a WAR-changing upgrade of a local MySQL database (`db_managed: true`,
`db_type: mysql`), the openspecimen role takes a `mysqldump` into the same
timestamped backup directory **before stopping the service**, so a later rollback
can restore WAR + schema + data together (`-e restore_db=true`). It runs while the
app is still serving (`--single-transaction`, no outage), and is skipped on the
plugins-only / config-only fast paths.

To protect the deploy SLA, large databases are **gated**: when the database
exceeds `db_backup_auto_max_mb` (default 2048 MB), the deploy halts and asks you to
back up manually first, then re-run with confirmation:

```bash
# 1. Take a consistent backup (no outage)
ansible-playbook -i inventory/customers/<name>/ db-backup.yml \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
#    (RDS: take an AWS snapshot instead)

# 2. Re-run the upgrade, confirming the backup is taken
ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e db_backup_confirmed=true \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

In Jenkins, tick `DB_BACKUP_CONFIRMED` instead of `-e db_backup_confirmed=true`.
To skip the auto-dump entirely (rollback will be artifact-only; the schema-drift
halt remains the safety net), pass `-e db_backup_enabled=false`.

### Standalone DB backup / restore

| Playbook | Purpose | Key `-e` flags |
|----------|---------|----------------|
| `db-backup.yml` | On-demand consistent dump (local MySQL). Output: `<db_backup_dir>/<timestamp>_<db>.sql.gz` (default `db_backup_dir`: `/usr/local/openspecimen/db-backups`). | `-e db_backup_dir=<path>` (optional) |
| `db-restore.yml` | Restore a dump produced by `db-backup.yml`. **DESTRUCTIVE** - overwrites the live DB. Stops the service and leaves it stopped (deploy the matching WAR before starting). | `-e db_restore_confirm=true` (required); `-e db_backup_file=<path>` (else newest dump) |

```bash
# restore the newest dump under db_backup_dir
ansible-playbook -i inventory/customers/<name>/ db-restore.yml \
  -e db_restore_confirm=true \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

Both are local-MySQL only. For RDS take/restore an AWS snapshot; for Oracle use
the DBA's tools.

---

## Day-2 config-change playbooks

Three small playbooks change one setting and restart, without a full `site.yml`
run. Each loops over `openspecimen_instances` (acting on every instance's
`catalina_base` / `service_name` / `http_port`); target one with
`-e instance=<name>`. Each backs up the file it edits before changing it.

| Playbook | What it changes | Required `-e` args |
|----------|-----------------|--------------------|
| `update-heap.yml` | `-Xms` / `-Xmx` in `setenv.sh` | `-e heap_min_mb=<int> -e heap_max_mb=<int>` |
| `update-app-url.yml` | `app.url` in `openspecimen.properties` | `-e app_url=https://...` |
| `update-db-pool.yml` | JDBC pool `maxActive` (and `minIdle`) in `context.xml` | `-e pool_max_active=<int>` (optional `-e pool_min_idle=<int>`) |
| `status.yml` | Read-only: shows release, service state, HTTP health, heap, pool, app.url per instance | _(none)_ |

```bash
ansible-playbook -i inventory/customers/<name>/ update-heap.yml \
  -e heap_min_mb=512 -e heap_max_mb=4096

ansible-playbook -i inventory/customers/<name>/ update-app-url.yml \
  -e app_url=https://openspecimen.example.com
#   then also set Settings → Common → Allowed Request Origins in the app UI

ansible-playbook -i inventory/customers/<name>/ update-db-pool.yml \
  -e pool_max_active=150

ansible-playbook -i inventory/customers/<name>/ status.yml
```

> The on-box `update-config.sh` script (see CONFIG-REFERENCE.md) does the same
> three changes for the single default instance. The playbooks above are the
> instance-aware, inventory-driven equivalents.

---

## Tear down a host or instance

`cleanup.yml` removes OpenSpecimen so a (test) VM can be reused. **DESTRUCTIVE** -
requires `-e cleanup_confirm=true`.

- **Default:** per-instance teardown (service, webapp, data/plugins/backups/markers,
  and local-MySQL DB + user). Leaves the shared Tomcat binary / MySQL server / Java
  in place for a fast re-deploy.
- `-e instance=<name>` limits the teardown to one instance.
- `-e full_wipe=true` **also** removes the shared bits: the whole
  `/usr/local/openspecimen` tree (Tomcat binary + all instances), the MySQL server
  + its data, and OpenJDK.

```bash
# per-instance teardown (all instances)
ansible-playbook -i inventory/customers/<name>/ cleanup.yml \
  -e cleanup_confirm=true -e @secrets/<name>.yml --vault-password-file .vault-pass

# one instance
ansible-playbook ... cleanup.yml -e cleanup_confirm=true -e instance=test ...

# full host reset
ansible-playbook ... cleanup.yml -e cleanup_confirm=true -e full_wipe=true ...
```

---

## Plugin deployment

OpenSpecimen ships with **default plugins** bundled in the release zip
(`os-distribution-invoicing`, `os-task-manager`, `os-edc`, `os-extras`). These are extracted
to `plugins/default/` automatically - no inventory configuration is needed.

Two additional tiers are supported for plugins delivered as separate zips alongside the release zip:

| Tier | Inventory variable | Deployed to | Use case |
|------|--------------------|-----------------|---------|
| Paid | `openspecimen_paid_plugins` | `plugins/paid/` | Licensed enterprise plugins |
| Customer | `openspecimen_customer_plugins` | `plugins/zustomer/` | Customer-specific plugins |

### Naming convention

Inventory lists **plugin names only** - no version, no extension. The role derives the zip
filename at runtime:

```
<plugin-name>-<version>.zip
```

`<version>` is derived from `openspecimen_release` by stripping the `openspecimen_` prefix.
Example: with `openspecimen_release=openspecimen_v12.2.RC12` and inventory entry
`os-automated-freezers`, the role looks for `os-automated-freezers-v12.2.RC12.zip`.

This means **inventory does not need to be updated on every OpenSpecimen upgrade** - only the
plugin zip on disk needs to be replaced with the new version.

### Where to place the plugin zip

The plugin zip must live in the same directory as the release zip on the Ansible control node
(or in any subdirectory of `openspecimen_builds_dir`). Each zip must contain at least one `.jar`
file - `unzip -jo` extracts JARs from any path inside the zip.

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

Rollback has three paths - all backed by the same `roles/openspecimen/tasks/rollback.yml`:

### A0. On a failed upgrade (automatic, default on)

If an **upgrade** deploy fails for any reason *after* the pre-upgrade backup was taken
(WAR/plugin extract, startup gate, readiness, or the public-URL verify), the instance is
automatically restored to the prior version from that backup (WAR + config + plugins,
plus the DB dump for managed MySQL; RDS/Oracle restore artifacts and warn you to restore a
snapshot), and the deploy still reports **FAILED** - so a broken upgrade leaves you on the
previous working version instead of a wedged instance. Controlled by
`openspecimen_rollback_on_failure` (default `true`); set `-e openspecimen_rollback_on_failure=false`
to leave a failed deploy in place for debugging. Fresh installs have no prior backup, so
nothing is rolled back there.

### A. Automatic downgrade (via deploy job - recommended)

Just pick a lower release in `site.yml` (or in the Jenkins
deploy job). Per-instance direction detection notices the requested version is
older than what's installed, finds the backup whose `.release` matches the request,
and runs the rollback for that instance (the other instances continue normally).
**No separate rollback job or playbook invocation required.**

```bash
# Installed: openspecimen_v12.2.RC12, want to go back to RC8
ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e openspecimen_release=openspecimen_v12.2.RC8 \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

Downgrade detection also covers `master` builds: `master` → any tagged release, and
`master` → an older `master` snapshot (by its `-DD-MM-YYYY` date), both route to
rollback, so you cannot move off a `master` build to an older release without a
matching backup.

If no backup of the requested version exists, the play fails with a list of
available backups and the operator can either pick a version that does have
one or override with `-e allow_downgrade=true`.

### B. Explicit - direct rollback.yml invocation

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
| `openspecimen.war` | Yes - required, playbook fails if missing |
| `plugins/default/*.jar` | Yes (if present in backup) |
| `plugins/paid/*.jar` | Yes (if present in backup) |
| `plugins/zustomer/*.jar` | Yes (if present in backup) |
| `lib/mysql-connector-*.jar` | Yes (if present in backup) |
| `conf/openspecimen.properties` | Yes (if present in backup) - restores the exact config the old WAR ran with |
| `bin/setenv.sh` (JVM heap) | Yes (if present in backup) |
| `conf/context.xml` (JDBC pool) | Yes (if present in backup) |
| `/usr/local/openspecimen/.release` | Yes (if present in backup) - keeps the marker consistent with the live version |
| Database schema + data | **Opt-in** with `-e restore_db=true` - restores the `db/<db>.sql.gz` dump taken at the matching upgrade (local MySQL only). Off by default; see below. |

No separate `site.yml` run is needed for config - `rollback.yml` restores the
exact config snapshot taken at the time of the previous deploy.

### Rolling the database back too (`-e restore_db=true`)

By default rollback restores the **artifacts only** (WAR/plugins/config) and the
schema-downgrade safeguard halts if the schema has moved forward. Pass
`-e restore_db=true` to also restore the matching `mysqldump` captured during the
pre-upgrade backup - this brings WAR + schema + data back to the backup point as a
unit, so the safeguard is skipped (a restore makes the schema match the older WAR).

```bash
ansible-playbook -i inventory/customers/<name>/ rollback.yml \
  -e restore_db=true \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

**This discards all data written since the backup** - a deliberate operator choice.
Local MySQL only; if the backup has no `db/*.sql.gz` (it predates DB snapshots, or
was a large-DB manual-backup upgrade), the artifacts are still rolled back and a
warning is printed. For RDS, restore the AWS snapshot instead.

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
about columns/tables the newer Liquibase migrations added - a class of failure
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
reached), use `site.yml` with the older release zip instead - there is
nothing to restore from.

---

## Variable reference

All defaults in `inventory/group_vars/all.yml`. Override per-customer in
`inventory/customers/<name>/group_vars/openspecimen.yml`. Pass credentials
via `-e mysql_db_password=<password>` (or your CI/CD secrets manager).

| Variable | Default | Notes |
|----------|---------|-------|
| `openspecimen_release` | _(required at run time)_ | Zip filename without `.zip` - e.g. `openspecimen_v12.3` |
| `openspecimen_zip_path` | `{{ openspecimen_builds_dir }}/{{ openspecimen_release }}.zip` | Path to the release zip on the controller or target |
| `openspecimen_builds_dir` | `/opt/openspecimen/builds` | Default location for release zips on the target node |
| `openspecimen_port` | `8080` | Tomcat HTTP port |
| `openspecimen_app_url` | _(unset)_ | Required for ALB / reverse proxy setup |
| `openspecimen_node_name` | _(unset)_ | Required for multi-node HA |
| `db_type` | `mysql` | `mysql` or `oracle` |
| `db_managed` | `true` | `false` = external DB (RDS / Oracle): never manages the DB server (skips the MySQL role, connectivity/schema probe, backups, Liquibase lock clear). Config behaviour depends on whether the DB config already exists on the host (probed via `context.xml`'s `jdbc/openspecimen` datasource, **not** the `.release` marker): **existing** → app-only upgrade that **reuses** all on-host config (`context.xml`, `server.xml`, `setenv.sh`, `openspecimen.properties`) and needs no `mysql_db_password`; **fresh** (no datasource) → **renders** config from the inventory db_config like a managed install (preflight fails if `mysql_db_password`/db_config is missing; the external DB + user must already exist, the app creates its schema). See the note in `site.yml`. |
| `mysql_db_host` | `127.0.0.1` | Set to RDS endpoint for external database |
| `tomcat_heap_min` | `512m` | JVM `-Xms` |
| `tomcat_heap_max` | auto (RAM × 0.5, min 2048 MB) | Override with `tomcat_heap_max_override` (integer MB) |
| `tomcat_pool_max_active` | `100` | JDBC connection pool size |
| `openspecimen_backup_dir` | `/usr/local/openspecimen/backup` | Timestamped backup location on upgrade |
| `openspecimen_backup_retention` | `3` | Number of timestamped backups to keep; older ones are pruned at end of deploy |
| `openspecimen_paid_plugins` | `[]` | List of paid plugin names (no version, no extension) - see [Plugin deployment](#plugin-deployment) |
| `openspecimen_customer_plugins` | `[]` | List of customer plugin names |
| `openspecimen_release_file` | _(unset)_ | Set by the Jenkins pipeline. When set, plugin search dir = `dirname(openspecimen_release_file)`. Otherwise the role searches recursively under `openspecimen_builds_dir`. |
| `deploy_report_dir` | _(unset)_ | Set by the Jenkins deploy job to `WORKSPACE`. When set, each instance writes `.prior-release-<instance>` (the version installed before this run, any direction) and `.component-versions-<instance>.json` (resolved tomcat/java/mysql/apache versions, deploy path only) on the control node for the completion email. A no-op for plain CLI runs. |

# OpenSpecimen Ansible Deployment

Ansible automation for deploying and upgrading [OpenSpecimen](https://github.com/krishagni/openspecimen) on Linux servers.

## What this does

- **Fresh install** (`site.yml`) - installs Java, MySQL (optional), Tomcat, and OpenSpecimen from a release zip
- **Upgrade** (`site.yml`) - a normal run on an existing install upgrades app-only (WAR + plugins) with automatic WAR/config and pre-upgrade database backup; a fresh host (no `.release` marker) runs the full stack automatically
- **One instance per customer folder** (ADR-009) - each `inventory/customers/<name>/` deploys a single OpenSpecimen instance from flat vars. Two environments on one VM (e.g. prod + test) are two customer folders pointing at the same host, each overriding the colliding values (`openspecimen_port`, `openspecimen_context_path`, `openspecimen_service_name`, `catalina_base`, DB) explicitly
- **Plugin tiers** - `openspecimen_paid_plugins` (→ `plugins/paid/`) and `openspecimen_customer_plugins` (→ `plugins/zustomer/`) extract JARs from named zips alongside the release zip
- **Rollback** - downgrade detection auto-restores the matching backup; `rollback.yml` restores the prior deploy end-to-end (WAR + config + plugins + database) so the schema is always brought back with the app
- **Day-2 playbooks** - `update-heap.yml`, `update-app-url.yml`, `update-db-pool.yml`, `status.yml`, `db-backup.yml`, `db-restore.yml`, `cleanup.yml`
- **Component version pinning** - per-release `component-specs/<release>.yml` pins Tomcat/Java/MySQL/Apache versions (see [`component-specs/README.md`](component-specs/README.md))
- **Pre-flight validation** - fails fast before touching the target if the release zip or any plugin zip is missing
- **Bounded backup history** - keeps `openspecimen_backup_retention` snapshots (default 3); older backups are pruned automatically

Supports Ubuntu 22.04, Ubuntu 24.04, and RHEL 9. Works with local MySQL, Amazon RDS, and Oracle databases.

## Prerequisites

This automation runs in two modes - from a **separate Ansible controller** over
SSH, or **directly on the OpenSpecimen host** (`ansible_connection=local`, no SSH;
see [Run on the same host](#run-on-the-same-host-no-separate-controller)).

| Requirement | Version / Notes |
|-------------|-----------------|
| Ansible | ≥ 2.15 - `pip3 install 'ansible>=2.15'` (on the controller, or on the box itself for a same-host run) |
| Ansible collections | `ansible-galaxy collection install -r requirements.yml` (ansible.posix, community.general, community.mysql) |
| Python 3 | ≥ 3.9 on the **target** host |
| Target OS | Ubuntu 22.04 / 24.04 or RHEL 9 (x86_64 / arm64) |
| Privilege | **sudo / root** on the target - the roles use `become` to install packages and write system config |
| Package install network | Outbound internet (or a local mirror) so the target can install **Java, MySQL, Tomcat**. The `common` role runs `apt update` / enables **EPEL** on RHEL; the `mysql` role adds the MySQL community repo |
| Connectivity | Key-based **SSH** controller → target, **or** run on the box with `ansible_connection=local` (no SSH) |

## Repository layout

```
site.yml                - unified install + upgrade; a normal upgrade is app-only, a fresh host runs the full stack automatically
rollback.yml            - roll back to a previous timestamped backup, end-to-end (WAR + config + plugins + database)
db-backup.yml           - on-demand consistent MySQL dump
db-restore.yml          - restore a db-backup.yml dump (destructive)
update-heap.yml         - day-2: change JVM heap and restart (per instance)
update-app-url.yml      - day-2: change app.url and restart (per instance)
update-db-pool.yml      - day-2: change JDBC pool size and restart (per instance)
status.yml              - day-2: report release/service/health/heap/pool per instance
cleanup.yml             - tear down instance(s) or the whole host (-e cleanup_confirm=true)
verify-customer.yml     - pre-deploy readiness check (SSH, disk, version)
roles/
  common/               - OS prerequisites, system user/group
  java/                 - OpenJDK 17
  mysql/                - MySQL install and config (skipped when db_managed: false)
  tomcat/               - shared Tomcat binary + per-instance CATALINA_BASE (ports, datasource, heap, unit)
  openspecimen/         - WAR deploy, properties, health check, backup/rollback/cleanup tasks
  plugins/              - customer-specific plugin injection
  apache/               - optional TLS-terminating reverse proxy (skipped unless apache_enabled)
component-specs/        - per-release pinned component versions (Tomcat/Java/MySQL/Apache)
inventory/
  group_vars/all.yml    - default variable values (flat single-instance layout)
  customers/_template/  - copy this for each new customer
  hosts-ec2.sample      - example hosts file for EC2 (controller → target over SSH)
  hosts-local.sample    - same-host inventory (run on the box, ansible_connection=local)
secrets/_template.yml   - example credential variables (never commit with real values)
docs/
  DEPLOY-UPGRADE.md     - fresh install, upgrade, rollback, day-2, cleanup procedures
  MULTI-INSTANCE.md     - running multiple OpenSpecimen instances on one host
  TROUBLESHOOTING.md    - common errors and fixes
CONFIG-REFERENCE.md     - every config file the roles write and what controls it
```

## Quick start (self-hosted)

```bash
# 1. Check out this branch
git clone https://github.com/krishagni/openspecimen.git --branch ansible-deploy
cd openspecimen
ansible-galaxy collection install -r requirements.yml

# 2. Create a customer inventory
cp -r inventory/customers/_template/ inventory/customers/my-hospital/
vi inventory/customers/my-hospital/hosts          # set ansible_host, ansible_user, key path
vi inventory/customers/my-hospital/group_vars/openspecimen.yml  # db_type, db_managed, etc.

# 3. (Optional) Verify the target VM is reachable
ansible-playbook -i inventory/customers/my-hospital/ verify-customer.yml \
  -e customer=my-hospital

# 4. Deploy (pass the DB password via -e or your CI/CD secrets manager)
ansible-playbook -i inventory/customers/my-hospital/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e mysql_db_password=<password>
```

## Run on the same host (no separate controller)

You can run the deploy **directly on the OpenSpecimen server** - the box is both
the Ansible controller and the target, so no SSH is involved
(`ansible_connection=local`).

```bash
# On the OpenSpecimen server, as a sudo-capable user:

# 1. Install Ansible + collections on the box
sudo pip3 install 'ansible>=2.15'
git clone https://github.com/krishagni/openspecimen.git --branch ansible-deploy
cd openspecimen
ansible-galaxy collection install -r requirements.yml

# 2. Deploy against localhost (no SSH). Add -K if sudo needs a password.
ansible-playbook -i inventory/hosts-local.sample site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e mysql_db_password=<password>
```

`inventory/hosts-local.sample` points `localhost` at `ansible_connection=local`.
The roles install all OS packages (Java, MySQL, Tomcat) themselves, so the box
needs **sudo/root** and **outbound internet** (or a local package mirror); on
RHEL the `common` role enables **EPEL** automatically. Set `db_managed: false`
(and the relevant `db_*` vars) in `inventory/group_vars/` for RDS/Oracle.

## Upgrade

```bash
ansible-playbook -i inventory/customers/my-hospital/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e mysql_db_password=<password>
```

## Database topologies

Set `db_type` and `db_managed` in your customer's `group_vars/openspecimen.yml`:

| Topology | `db_type` | `db_managed` | Notes |
|----------|-----------|--------------|-------|
| Local MySQL (same VM) | `mysql` | `true` | Role installs and manages MySQL |
| Amazon RDS for MySQL | `mysql` | `false` | Set `mysql_db_host` to the RDS endpoint |
| Oracle | `oracle` | `false` | Set `oracle_db_host`, `oracle_db_service`, `oracle_db_user` |

For RDS and Oracle, the `mysql` role is skipped - only the JDBC connection is configured.

## Customer-specific plugins

List plugins by **name only** (no version, no extension). The role derives the zip
filename at runtime as `<name>-<version>.zip`, where `<version>` is
`openspecimen_release` with the `openspecimen_` prefix stripped - so inventory does
not change on every upgrade, only the on-disk zip does.

```yaml
# inventory/host_vars/my-hospital.yml
openspecimen_paid_plugins:        # JARs extracted to plugins/paid/
  - os-automated-freezers
openspecimen_customer_plugins:    # JARs extracted to plugins/zustomer/
  - acme-custom-workflow
```

Each `<name>-<version>.zip` must exist (alongside the release zip, or anywhere
under `openspecimen_builds_dir`) on the Ansible controller at deploy time and
contain at least one `.jar`. See [`docs/DEPLOY-UPGRADE.md`](docs/DEPLOY-UPGRADE.md#plugin-deployment)
for details and the `host_vars` vs `group_vars` loading caveat.

## Roles

| Role | Purpose |
|------|---------|
| `common` | OS prerequisites, system user/group |
| `java` | OpenJDK 17 installation |
| `mysql` | MySQL install and configuration (skipped when `db_managed: false`) |
| `tomcat` | Shared Tomcat binary + JDBC drivers; per-instance `CATALINA_BASE` (ports, datasource, heap, systemd unit) |
| `openspecimen` | WAR deploy, properties config, health check, backup / rollback / cleanup |
| `plugins` | Customer-specific plugin injection (optional) |
| `apache` | Optional TLS-terminating reverse proxy (skipped unless `apache_enabled`) |

See [`CONFIG-REFERENCE.md`](CONFIG-REFERENCE.md) for all variables, and
[`docs/DEPLOY-UPGRADE.md`](docs/DEPLOY-UPGRADE.md) for upgrade and rollback procedures.

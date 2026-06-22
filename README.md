# OpenSpecimen Ansible Deployment

Ansible automation for deploying and upgrading [OpenSpecimen](https://github.com/krishagni/openspecimen) on Linux servers.

## What this does

- **Fresh install** (`site.yml`) — installs Java, MySQL (optional), Tomcat, and OpenSpecimen from a release zip
- **Upgrade** (`site.yml`) — a normal run on an existing install upgrades app-only (WAR + plugins) with automatic backup; `-e force_deploy=true` also re-runs the base roles
- **Plugin tiers** — `openspecimen_paid_plugins` (→ `plugins/paid/`) and `openspecimen_customer_plugins` (→ `plugins/zustomer/`) extract JARs from named zips alongside the release zip
- **Pre-flight validation** — fails fast before touching the target if the release zip or any plugin zip is missing
- **Bounded backup history** — keeps `openspecimen_backup_retention` snapshots (default 3); older backups are pruned automatically

Supports Ubuntu 22.04, Ubuntu 24.04, and RHEL 9. Works with local MySQL, Amazon RDS, and Oracle databases.

## Prerequisites

This automation runs in two modes — from a **separate Ansible controller** over
SSH, or **directly on the OpenSpecimen host** (`ansible_connection=local`, no SSH;
see [Run on the same host](#run-on-the-same-host-no-separate-controller)).

| Requirement | Version / Notes |
|-------------|-----------------|
| Ansible | ≥ 2.15 — `pip3 install 'ansible>=2.15'` (on the controller, or on the box itself for a same-host run) |
| Ansible collections | `ansible-galaxy collection install -r requirements.yml` (ansible.posix, community.general, community.mysql) |
| Python 3 | ≥ 3.9 on the **target** host |
| Target OS | Ubuntu 22.04 / 24.04 or RHEL 9 (x86_64 / arm64) |
| Privilege | **sudo / root** on the target — the roles use `become` to install packages and write system config |
| Package install network | Outbound internet (or a local mirror) so the target can install **Java, MySQL, Tomcat**. The `common` role runs `apt update` / enables **EPEL** on RHEL; the `mysql` role adds the MySQL community repo |
| Connectivity | Key-based **SSH** controller → target, **or** run on the box with `ansible_connection=local` (no SSH) |

## Repository layout

```
site.yml                — unified install + upgrade; a normal upgrade is app-only, `-e force_deploy=true` re-runs the base roles
verify-customer.yml     — pre-deploy readiness check (SSH, disk, version)
roles/
  common/               — OS prerequisites, system user/group
  java/                 — OpenJDK 17
  mysql/                — MySQL install and config (skipped when db_managed: false)
  tomcat/               — Tomcat, JDBC drivers, JVM tuning
  openspecimen/         — WAR deploy, properties, health check
  plugins/              — customer-specific plugin injection
inventory/
  group_vars/all.yml    — default variable values (all roles)
  customers/_template/  — copy this for each new customer
  hosts-ec2.sample      — example hosts file for EC2 (controller → target over SSH)
  hosts-local.sample    — same-host inventory (run on the box, ansible_connection=local)
secrets/_template.yml   — example credential variables (never commit with real values)
docs/
  DEPLOY-UPGRADE.md     — fresh install, upgrade, rollback procedures
  TROUBLESHOOTING.md    — common errors and fixes
CONFIG-REFERENCE.md     — every config file the roles write and what controls it
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

You can run the deploy **directly on the OpenSpecimen server** — the box is both
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

For RDS and Oracle, the `mysql` role is skipped — only the JDBC connection is configured.

## Customer-specific plugins

For **self-hosted** deployments, define the plugin list in your customer inventory:

```yaml
# inventory/customers/my-hospital/group_vars/plugins.yml
customer_plugins:
  - src: "/path/to/enterprise.jar"
    dest_subdir: paid
  - src: "/path/to/custom.jar"
    dest_subdir: customer
```

Plugin files referenced by `src` must be accessible on the Ansible controller at deploy time.

## Roles

| Role | Purpose |
|------|---------|
| `common` | OS prerequisites, system user/group |
| `java` | OpenJDK 17 installation |
| `mysql` | MySQL install and configuration (skipped when `db_managed: false`) |
| `tomcat` | Tomcat, JDBC drivers, JVM tuning |
| `openspecimen` | WAR deploy, properties config, health check |
| `plugins` | Customer-specific plugin injection (optional) |

See [`CONFIG-REFERENCE.md`](CONFIG-REFERENCE.md) for all variables, and
[`docs/DEPLOY-UPGRADE.md`](docs/DEPLOY-UPGRADE.md) for upgrade and rollback procedures.

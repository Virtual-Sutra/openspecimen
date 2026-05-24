# OpenSpecimen Ansible Deployment

Ansible automation for deploying and upgrading [OpenSpecimen](https://github.com/krishagni/openspecimen) on Linux servers.

## What this does

- **Fresh install** (`site.yml`) — installs Java, MySQL (optional), Tomcat, and OpenSpecimen from a release zip
- **Upgrade** (`deploy.yml`) — deploys a new version over an existing install with automatic WAR + plugin backup
- **Customer-specific plugins** — optional `plugins` role installs additional `.jar`/`.zip` plugins alongside the standard release

Supports Ubuntu 22.04, Ubuntu 24.04, and RHEL 9. Works with local MySQL, Amazon RDS, and Oracle databases.

## Prerequisites

| Requirement | Version | Install |
|-------------|---------|---------|
| Ansible | ≥ 2.15 | `pip3 install 'ansible>=2.15'` |
| Ansible collections | — | `ansible-galaxy collection install -r requirements.yml` |
| Python 3 | ≥ 3.9 | Must be present on the **target** host |
| Target OS | Ubuntu 22.04/24.04 or RHEL 9 | x86_64 and arm64 |
| SSH access | — | Key-based auth from the Ansible controller to the target |

## Repository layout

```
site.yml                — full fresh deployment (all roles in order)
deploy.yml              — upgrade-only re-deploy (skips infra setup)
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
  hosts-ec2.sample      — example hosts file for EC2
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

## Upgrade

```bash
ansible-playbook -i inventory/customers/my-hospital/ deploy.yml \
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

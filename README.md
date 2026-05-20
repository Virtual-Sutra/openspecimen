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

## Quick start (self-hosted)

**Option A — from the release zip (recommended — version-matched playbooks)**

```bash
unzip openspecimen_v12.3.zip 'ansible/*' -d deploy/
cd deploy/ansible

# Copy and fill in your inventory
cp -r inventory/customers/_template/ inventory/customers/my-hospital/
vi inventory/customers/my-hospital/hosts
vi inventory/customers/my-hospital/group_vars/openspecimen.yml

# Create vault-encrypted secrets (DB password)
cp secrets/_template.yml secrets/my-hospital.yml
vi secrets/my-hospital.yml          # set mysql_db_password (or oracle_db_password)
ansible-vault encrypt secrets/my-hospital.yml
echo "your-vault-password" > .vault-pass && chmod 600 .vault-pass

# Deploy
ansible-playbook -i inventory/customers/my-hospital/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e @secrets/my-hospital.yml --vault-password-file .vault-pass
```

**Option B — from git (latest playbooks)**

```bash
git clone https://github.com/Virtual-Sutra/openspecimen.git --branch ansible-deploy
cd openspecimen
# then follow inventory setup above
```

## Upgrade

```bash
ansible-playbook -i inventory/customers/my-hospital/ deploy.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e @secrets/my-hospital.yml --vault-password-file .vault-pass
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
    dest_subdir: paid      # default | paid | zustomer
  - src: "/path/to/custom.jar"
    dest_subdir: zustomer
```

Plugin files referenced by `src` must be accessible on the Ansible controller at deploy time.

For **Jenkins-managed** deployments, plugin binaries are stored on the Jenkins VM and staged automatically by the pipeline. See the ops repository documentation.

## Roles

| Role | Purpose |
|------|---------|
| `common` | OS prerequisites, system user/group |
| `java` | OpenJDK 17 installation |
| `mysql` | MySQL install and configuration (skipped when `db_managed: false`) |
| `tomcat` | Tomcat, JDBC drivers, JVM tuning |
| `openspecimen` | WAR deploy, properties config, health check |
| `plugins` | Customer-specific plugin injection (optional) |

See [`CONFIG-REFERENCE.md`](CONFIG-REFERENCE.md) for all variables.

## Jenkins integration

For Jenkins-managed deployments, the `ansible/` directory from this branch is
injected into each release zip before upload using `scripts/package-release.sh`
(in the ops repository). The Jenkins deploy pipeline then:

1. Fetches the packaged release zip via `copyArtifacts`
2. Extracts `ansible/` to get version-matched playbooks
3. Stages customer-specific plugins from the Jenkins VM
4. Runs `ansible-playbook ansible/site.yml` with customer inventory from the ops repo

Customer inventory and Jenkins pipeline configuration are managed in the private
`Virtual-Sutra/openspecimen-ops` repository. See its `docs/JENKINS-SETUP.md` for
the full ops setup guide.

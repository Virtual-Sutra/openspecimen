# OpenSpecimen Ansible Deployment

Ansible automation for deploying and upgrading [OpenSpecimen](https://github.com/krishagni/openspecimen) on Linux servers.

## What this does

- **Fresh install** (`site.yml`) — installs Java, MySQL (optional), Tomcat, and OpenSpecimen from a release zip
- **Upgrade** (`deploy.yml`) — deploys a new version over an existing install with automatic WAR + plugin backup
- **Customer-specific plugins** — optional `plugins` role installs additional `.jar`/`.zip` plugins alongside the standard release

Supports Ubuntu 22.04, Ubuntu 24.04, and RHEL 9. Works with local MySQL, Amazon RDS, and Oracle databases.

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
# edit secrets/my-hospital.yml, then:
ansible-vault encrypt secrets/my-hospital.yml

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

## Customer-specific plugins

Define additional plugins in `inventory/customers/<name>/group_vars/plugins.yml`:

```yaml
customer_plugins:
  - src: "/path/to/enterprise.jar"
    dest_subdir: paid      # default | paid | zustomer
  - src: "/path/to/custom.jar"
    dest_subdir: zustomer
```

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

When OpenSpecimen release zips include an `ansible/` directory, the Jenkins
deploy pipeline extracts playbooks from the zip and runs them automatically.
Customer inventory is managed separately in a private ops repository.

## Requirements

- Ansible >= 2.15
- Target: Ubuntu 22.04/24.04 or RHEL 9
- Python 3 on the target host
- SSH key access to target

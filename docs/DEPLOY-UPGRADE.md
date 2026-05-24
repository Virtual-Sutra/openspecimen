# Deploy and Upgrade

Day-1 fresh install, Day-2 upgrade, and rollback procedures for OpenSpecimen.

---

## How version detection works

The roles use the marker file `/usr/local/openspecimen/.release` on the target
node to determine what is currently installed:

- **File absent** → fresh install (all five roles run in order)
- **File present, same version** → no-op (idempotent run)
- **File present, lower version** → upgrade (backup → deploy → restart)
- **File present, higher version** → downgrade — **blocked** with a clear error

`openspecimen_release` is always supplied at run time via `-e openspecimen_release=<name>`.
It is **not** stored in inventory `group_vars`.

---

## Prerequisites

Before deploying:
- Customer inventory exists under `inventory/customers/<name>/`
- Secrets file is Vault-encrypted at `secrets/<name>.yml`
- The release zip is accessible on the Ansible controller

---

## Day-1: Fresh Install

```bash
ansible-galaxy collection install -r requirements.yml

ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e openspecimen_release=openspecimen_v12.3 \
  -e openspecimen_zip_path=/path/to/openspecimen_v12.3.zip \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
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
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

The playbook:
1. Reads the marker file on the target node to detect the current version
2. Stops the service
3. Backs up WAR and plugins to `openspecimen_backup_dir/<timestamp>/`
4. Deploys the new WAR and plugins
5. Starts the service and polls the health check

### Dry-run

```bash
ansible-playbook ... --check
```

---

## Day-2: Rollback

Rollback restores from the timestamped backup created during the last upgrade.
Target: ≤ 5 minutes.

### 1. SSH into the target node

```bash
ssh -i ~/.ssh/<deploy-key>.pem ubuntu@<host>
```

### 2. Identify the backup

```bash
ls /usr/local/openspecimen/backup/
# example output: 17052026_093247/
```

### 3. Stop → restore → start

```bash
sudo systemctl stop openspecimen

BACKUP=/usr/local/openspecimen/backup/<timestamp>
TOMCAT=/usr/local/openspecimen/tomcat-as
PLUGINS=/usr/local/openspecimen/plugins

# Restore WAR
sudo rm -f  $TOMCAT/webapps/openspecimen.war
sudo rm -rf $TOMCAT/webapps/openspecimen
sudo cp $BACKUP/openspecimen.war $TOMCAT/webapps/
sudo chown openspecimen:openspecimen $TOMCAT/webapps/openspecimen.war

# Restore plugins
sudo rm -f $PLUGINS/default/*.jar
sudo cp $BACKUP/plugins/default/*.jar $PLUGINS/default/
sudo chown openspecimen:openspecimen $PLUGINS/default/*.jar

sudo systemctl start openspecimen
sudo tail -f $TOMCAT/logs/catalina.out   # watch for "Server startup in"
```

---

## Variable reference

All defaults in `inventory/group_vars/all.yml`. Override per-customer in
`inventory/customers/<name>/group_vars/openspecimen.yml`. Credentials in
`secrets/<name>.yml` (Vault-encrypted).

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

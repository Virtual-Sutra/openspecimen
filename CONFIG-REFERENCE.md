# OpenSpecimen Configuration Reference

Every file the Ansible roles write to the target EC2 node, with the variables
that control it and what a change requires.

---

## common role

| File | What it does | Requires restart? |
|------|-------------|-------------------|
| _(no files written)_ | Installs packages and creates the `openspecimen` system user/group | — |

---

## java role

| File | Ansible variable(s) | What it sets | Requires restart? |
|------|---------------------|--------------|-------------------|
| `/etc/environment` | Derived from `ansible_facts['os_family']` + `ansible_facts['architecture']` | `JAVA_HOME` path | Shell re-login / service restart |

`JAVA_HOME` values by platform:

| Platform | Path |
|----------|------|
| Ubuntu/Debian x86_64 | `/usr/lib/jvm/java-17-openjdk-amd64` |
| Ubuntu/Debian arm64 | `/usr/lib/jvm/java-17-openjdk-arm64` |
| RHEL 9 | `/usr/lib/jvm/java-17-openjdk` |

---

## mysql role

| File | Ansible variable(s) | What it sets | Requires restart? |
|------|---------------------|--------------|-------------------|
| `/etc/mysql/mysql.conf.d/mysqld.cnf` (Debian) | See below | MySQL server config | Yes — `systemctl restart mysql` |
| `/etc/my.cnf.d/mysqld.cnf` (RHEL) | See below | MySQL server config | Yes — `systemctl restart mysqld` |

**⚠️ Written before MySQL is installed** — `lower_case_table_names` and `character-set-server`
cannot be changed after the data directory is initialised. Changing them on a running instance
requires recreating the data directory (and on RDS, recreating the instance).

Key settings in `mysqld.cnf`:

| Setting | Variable | Default | Notes |
|---------|----------|---------|-------|
| `bind-address` | `mysql_bind_address` | `127.0.0.1` | |
| `character-set-server` | hardcoded | `utf8` | Must be `utf8`, NOT `utf8mb4` — Liquibase index size constraint |
| `lower_case_table_names` | hardcoded | `1` | Required for Liquibase schema migration |
| `log_bin_trust_function_creators` | hardcoded | `1` | Required for trigger creation without SUPER |
| `innodb_buffer_pool_size` | `mysql_innodb_buffer_pool_size` | auto-sized (RAM × 0.25) | Override: `mysql_innodb_buffer_pool_size_override` (MB) |
| `max_allowed_packet` | `mysql_max_allowed_packet` | `64M` | |

---

## tomcat role

| File | Ansible variable(s) | What it sets | Requires restart? |
|------|---------------------|--------------|-------------------|
| `$TOMCAT_HOME/bin/setenv.sh` | `tomcat_heap_min`, `tomcat_heap_max` | JVM `-Xms` / `-Xmx` | Yes |
| `$TOMCAT_HOME/conf/context.xml` | `db_type`, `mysql_db_*`, `oracle_db_*`, `tomcat_pool_*` | JDBC connection pool | Yes |
| `$TOMCAT_HOME/lib/mysql-connector*.jar` | _(from release zip)_ | MySQL JDBC driver | Yes (redeploy) |
| `$TOMCAT_HOME/lib/ojdbc*.jar` | _(from release zip)_ | Oracle JDBC driver | Yes (redeploy) |
| `/etc/systemd/system/openspecimen.service` | `tomcat_user`, `tomcat_home`, `db_managed` | systemd service unit | Yes — `systemctl daemon-reload` |

`$TOMCAT_HOME` = `tomcat_home` = `/usr/local/openspecimen/tomcat-as`

**Heap sizing** (`setenv.sh`):

| Variable | Default | Formula |
|----------|---------|---------|
| `tomcat_heap_max` | auto-sized | `max(2048, RAM_MB × 0.5)` then `+ "m"` |
| `tomcat_heap_min` | auto-sized | `512m` |
| `tomcat_heap_max_override` | _(unset)_ | Integer MB, no suffix — set in customer `group_vars` |
| `tomcat_heap_min_override` | _(unset)_ | Integer MB, no suffix |

**JDBC connection pool** (`context.xml`):

| Variable | Default |
|----------|---------|
| `tomcat_pool_max_active` | `100` |
| `tomcat_pool_min_idle` | `10` |
| `tomcat_pool_initial_size` | `10` |
| `tomcat_pool_max_wait_ms` | `10000` |
| `tomcat_pool_validation_interval_ms` | `60000` |
| `tomcat_pool_eviction_interval_ms` | `60000` |
| `tomcat_pool_min_evictable_idle_ms` | `60000` |
| `tomcat_pool_abandoned_timeout_s` | `300` |
| `tomcat_pool_abandon_pct` | `60` |

---

## openspecimen role

| File | Ansible variable(s) | What it sets | Requires restart? |
|------|---------------------|--------------|-------------------|
| `$TOMCAT_HOME/conf/openspecimen.properties` | `db_type`, `openspecimen_data_dir`, `openspecimen_plugin_dir`, `openspecimen_backup_dir`, `openspecimen_app_url`, `openspecimen_node_name` | Application behaviour, paths, public URL | Yes |
| `$TOMCAT_HOME/webapps/openspecimen.war` | _(from release zip)_ | The application WAR | Yes (via Tomcat hot-deploy) |
| `$PLUGIN_DIR/default/*.jar` | _(from release zip)_ | Common plugin JARs | Yes (Tomcat re-scans on startup) |
| `/usr/local/openspecimen/.release` | `openspecimen_release` | Deployed version marker for downgrade guard | No |

`$PLUGIN_DIR` = `openspecimen_plugin_dir` = `/usr/local/openspecimen/plugins`

**Key properties** (`openspecimen.properties`):

| Property | Variable | Notes |
|----------|----------|-------|
| `datasource.type` | hardcoded `fresh` | Always `fresh` — `upgrade` is for legacy caTissue migrations only |
| `database.type` | `db_type` | `mysql` or `oracle` |
| `app.url` | `openspecimen_app_url` | Required when behind ALB or reverse proxy |
| `node.name` | `openspecimen_node_name` | Required for multi-node HA cluster |
| `app.data_dir` | `openspecimen_data_dir` | |
| `plugin.dir` | `openspecimen_plugin_dir` | Tomcat scans all subdirectories |
| `app.backup_dir` | `openspecimen_backup_dir` | Upgrade backup location |

---

## Quick change guide

For the three most common post-deploy changes without a full Ansible re-run, use:

```bash
sudo /usr/local/openspecimen/scripts/update-config.sh <command>

# Show current values
sudo /usr/local/openspecimen/scripts/update-config.sh status

# Update JVM heap
sudo /usr/local/openspecimen/scripts/update-config.sh heap 512m 4096m

# Update JDBC pool size
sudo /usr/local/openspecimen/scripts/update-config.sh db-pool 150

# Update public URL (also set in app UI: Settings → Common → Allowed Request Origins)
sudo /usr/local/openspecimen/scripts/update-config.sh app-url https://openspecimen.example.com
```

See `scripts/update-config.sh` for full usage. The script creates a timestamped backup
before every change and restarts the service automatically.

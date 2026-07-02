# OpenSpecimen Configuration Reference

Every file the Ansible roles write to the target EC2 node, with the variables
that control it and what a change requires.

---

## common role

| File | What it does | Requires restart? |
|------|-------------|-------------------|
| _(no files written)_ | Installs packages and creates the `openspecimen` system user/group | - |

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
| `/etc/mysql/mysql.conf.d/mysqld.cnf` (Debian) | See below | MySQL server config | Yes - `systemctl restart mysql` |
| `/etc/my.cnf.d/mysqld.cnf` (RHEL) | See below | MySQL server config | Yes - `systemctl restart mysqld` |

**⚠️ Written before MySQL is installed** - `lower_case_table_names` and `character-set-server`
cannot be changed after the data directory is initialised. Changing them on a running instance
requires recreating the data directory (and on RDS, recreating the instance).

Key settings in `mysqld.cnf`:

| Setting | Variable | Default | Notes |
|---------|----------|---------|-------|
| `bind-address` | `mysql_bind_address` | `127.0.0.1` | |
| `character-set-server` | hardcoded | `utf8` | Must be `utf8`, NOT `utf8mb4` - Liquibase index size constraint |
| `lower_case_table_names` | hardcoded | `1` | Required for Liquibase schema migration |
| `log_bin_trust_function_creators` | hardcoded | `1` | Required for trigger creation without SUPER |
| `innodb_buffer_pool_size` | `mysql_innodb_buffer_pool_size` | auto-sized (RAM × 0.25) | Override: `mysql_innodb_buffer_pool_size_override` (MB) |
| `max_allowed_packet` | `mysql_max_allowed_packet` | `64M` | |

---

## tomcat role

The tomcat role installs one **shared Tomcat binary** at `$CATALINA_HOME`
(`tomcat_home`) host-level, then writes a **per-instance** runtime under each
instance's `$CATALINA_BASE` (`tasks/instance.yml`). For the single default
instance `$CATALINA_BASE == $CATALINA_HOME`, so the paths below collapse onto the
shared Tomcat; with multiple instances each has its own copy.

| File | Ansible variable(s) | What it sets | Requires restart? |
|------|---------------------|--------------|-------------------|
| `$CATALINA_BASE/bin/setenv.sh` | `tomcat_heap_min`, `tomcat_heap_max` (or per-instance `heap_min`/`heap_max`) | JVM `-Xms` / `-Xmx` | Yes |
| `$CATALINA_BASE/conf/context.xml` | `db_type`, `mysql_db_*`, `oracle_db_*`, `tomcat_pool_*` | JDBC connection pool (JNDI datasource) | Yes |
| `$CATALINA_BASE/conf/server.xml` | `openspecimen_port`, `openspecimen_ajp_port`, `openspecimen_shutdown_port` (per instance) | HTTP / AJP / shutdown ports; AJP `secretRequired=false`, bound to `127.0.0.1`. **Patched in place** (seeded from the golden conf), not templated. | Yes |
| `$CATALINA_HOME/lib/mysql-connector*.jar` | _(from release zip)_ | MySQL JDBC driver (shared, host-level) | Yes (redeploy) |
| `$CATALINA_HOME/lib/ojdbc*.jar` | _(from release zip)_ | Oracle JDBC driver (shared, host-level) | Yes (redeploy) |
| `/etc/systemd/system/<service_name>.service` | `tomcat_user`, `catalina_home`, `catalina_base`, `db_managed`, `openspecimen_service_name` | systemd unit (one per instance; `openspecimen` for the default) | Yes - `systemctl daemon-reload` |

`$CATALINA_HOME` = `tomcat_home` = `/usr/local/openspecimen/tomcat-as`.
A co-located 2nd customer sets its own `catalina_base` explicitly (ADR-009).

**Tomcat install source** (#90/#91): the binary comes from a pinned Apache download
(`tomcat_version` from the component spec, default `9.0.59`), not an OS package;
the OpenSpecimen-tuned `conf/` and the DB connectors come from the release zip. The
role asserts the major version is 9.

**Heap sizing** (`setenv.sh`):

| Variable | Default | Formula |
|----------|---------|---------|
| `tomcat_heap_max` | auto-sized | `max(2048, RAM_MB × 0.5)` then `+ "m"` |
| `tomcat_heap_min` | auto-sized | `512m` |
| `tomcat_heap_max_override` | _(unset)_ | Integer MB, no suffix - set in customer `group_vars` |
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

Paths below are shown for the single default instance; with multiple instances
each resolves under that instance's `$CATALINA_BASE` and per-instance dirs.

| File | Ansible variable(s) | What it sets | Requires restart? |
|------|---------------------|--------------|-------------------|
| `$CATALINA_BASE/conf/openspecimen.properties` | `db_type`, `openspecimen_data_dir`, `openspecimen_plugin_dir`, `openspecimen_backup_dir`, `openspecimen_app_url`, `openspecimen_node_name` | Application behaviour, paths, public URL | Yes |
| `$CATALINA_BASE/webapps/openspecimen.war` | _(from release zip)_ | The application WAR | Yes (via Tomcat hot-deploy) |
| `$PLUGIN_DIR/default/*.jar` | _(from release zip)_ | Common plugin JARs | Yes (Tomcat re-scans on startup) |
| `$PLUGIN_DIR/paid/*.jar` | `openspecimen_paid_plugins` | Licensed enterprise plugin JARs | Yes (Tomcat re-scans on startup) |
| `$PLUGIN_DIR/zustomer/*.jar` | `openspecimen_customer_plugins` | Customer-specific plugin JARs | Yes (Tomcat re-scans on startup) |
| `/usr/local/openspecimen/.release` | `openspecimen_release` | Deployed version marker (per instance) - drives downgrade/no-op detection | No |
| `/usr/local/openspecimen/.deploy_success` | _(written by the role)_ | Records the last fully-successful deploy (release + plugins). The no-op fast path requires this to match the requested release. | No |
| `/usr/local/openspecimen/scripts/update-config.sh` | _(from the repo)_ | On-box helper for heap / db-pool / app-url changes | No |

`$PLUGIN_DIR` = `openspecimen_plugin_dir` = `/usr/local/openspecimen/plugins`

**Key properties** (`openspecimen.properties`):

| Property | Variable | Notes |
|----------|----------|-------|
| `datasource.type` | hardcoded `fresh` | Always `fresh` - `upgrade` is for legacy caTissue migrations only |
| `database.type` | `db_type` | `mysql` or `oracle` |
| `app.url` | `openspecimen_app_url` | Required when behind ALB or reverse proxy |
| `node.name` | `openspecimen_node_name` | Required for multi-node HA cluster |
| `app.data_dir` | `openspecimen_data_dir` | |
| `plugin.dir` | `openspecimen_plugin_dir` | Tomcat scans all subdirectories |
| `app.backup_dir` | `openspecimen_backup_dir` | Upgrade backup location |

**Plugin deployment** (additional plugins delivered alongside the release zip):

| Variable | Default | Notes |
|----------|---------|-------|
| `openspecimen_paid_plugins` | `[]` | Plugin names (no version, no extension). Role looks for `<name>-<version>.zip` in the release directory. JARs deployed to `$PLUGIN_DIR/paid/`. |
| `openspecimen_customer_plugins` | `[]` | Plugin names. Role looks for `<name>-<version>.zip`. JARs deployed to `$PLUGIN_DIR/zustomer/`. |
| `openspecimen_release_file` | _(unset)_ | When set (Jenkins pipeline passes this), used to derive the plugin search directory as `dirname(openspecimen_release_file)`. Otherwise the role searches recursively under `openspecimen_builds_dir`. |

The version is derived from `openspecimen_release` by stripping the `openspecimen_` prefix
(e.g. `openspecimen_v12.2.RC12` → plugin filename suffix `-v12.2.RC12.zip`). The same release
upgrade therefore picks up the matching plugin version automatically - no inventory edit needed
on every upgrade.

**Master builds (`openspecimen_master-*`) — bundled plugins:** a master release ships every
plugin *inside* the release zip, so there are no separate `<name>-<version>.zip` files. Because
those files only exist on the host after the zip is copied, the control-node pre-flight
`<name>-<version>.zip` validation cannot run and is **skipped for any `openspecimen_master*`
release** (deploy or upgrade). The named plugins are extracted from the master zip on the host
via the default-plugin path (`plugin_build/*.jar` → `$PLUGIN_DIR/default/`), which Tomcat scans
alongside `paid/` and `zustomer/`. Pinned releases (e.g. `v12.2.RC12`) still require the separate
plugin zips and are validated as before.

**Backup retention:**

| Variable | Default | Notes |
|----------|---------|-------|
| `openspecimen_backup_retention` | `3` | Number of timestamped backup directories under `openspecimen_backup_dir` to keep. Older ones are pruned at the end of every deploy. Override per customer in `inventory/host_vars/<customer>.yml`. |

The pre-upgrade backup snapshots the WAR, all three plugin tiers, the config files
the old WAR ran with, the `.release` marker, the MySQL connector JAR (tomcat role),
and - on a WAR-changing upgrade of a small local MySQL DB - a `mysqldump`:

```
{{ openspecimen_backup_dir }}/<DDMMYYYY_HHMMSS>/
  ├─ openspecimen.war
  ├─ .release
  ├─ config/
  │    ├─ openspecimen.properties
  │    ├─ setenv.sh
  │    └─ context.xml
  ├─ plugins/
  │    ├─ default/
  │    ├─ paid/
  │    └─ zustomer/
  ├─ db/
  │    └─ <db>.sql.gz        (small local MySQL only; gated by db_backup_auto_max_mb)
  └─ lib/
       └─ mysql-connector-*.jar
```

On the plugins-only / config-only fast paths only the relevant subset is captured
(config always; plugin tiers and `db/` only when the WAR changes). `rollback.yml`
restores the config + artifacts; `-e restore_db=true` also restores `db/<db>.sql.gz`.

The `config-changes/` subdirectory at the backup root is excluded from pruning - it's a flat log
directory written by the `update-config.sh` operator script, not a snapshot.

**Pre-upgrade DB backup gate:**

| Variable | Default | Notes |
|----------|---------|-------|
| `db_backup_enabled` | `true` | Auto-dump the DB into the upgrade backup (local MySQL, WAR-changing upgrades). `false` → artifact-only rollback. |
| `db_backup_auto_max_mb` | `2048` | DBs larger than this halt the deploy; back up manually (`db-backup.yml` / RDS snapshot) then re-run with `-e db_backup_confirmed=true`. |
| `db_backup_dir` | `/usr/local/openspecimen/db-backups` | Output dir for the standalone `db-backup.yml` / source for `db-restore.yml`. |

---

## apache role

Optional TLS-terminating reverse proxy in front of Tomcat. The role is **skipped unless
`apache_enabled` is true** (`site.yml` runs it only `when: apache_enabled`). On the AWS/ALB path
leave it disabled - the ALB terminates TLS instead.

| Variable | Default | What it sets |
|----------|---------|--------------|
| `apache_enabled` | `true` when `openspecimen_app_url` is set, else `false` | Whether the role runs. Override explicitly, or via `-e apache_enabled=...` (Jenkins job / playbook), which takes precedence over inventory. |
| `apache_proxy_protocol` | `http` | Backend to Tomcat: `http` (`http://localhost:<openspecimen_port>/openspecimen/`, avoids Ghostcat) or `ajp` (`ajp://127.0.0.1:<apache_ajp_port>/openspecimen/`). |
| `apache_ajp_port` | `8009` | Tomcat AJP connector port (used when `apache_proxy_protocol: ajp`). The tomcat role binds this connector to `127.0.0.1`. |
| `apache_enable_ssl` | `false` | Terminate TLS at Apache (adds an 80→443 redirect + HSTS). Requires the cert/key below. |
| `apache_ssl_self_signed` | `false` | When SSL is on and no cert exists, generate a self-signed cert at the paths below (internal/test only - browsers warn). |
| `apache_ssl_cert_file` / `apache_ssl_key_file` | `""` | Cert/key paths. Stage a CA-issued cert here, or let `apache_ssl_self_signed` create one. |
| `apache_server_name` | derived from `openspecimen_app_url` (scheme/path stripped), else host FQDN | VirtualHost `ServerName`. |
| `apache_http_port` / `apache_https_port` | `80` / `443` | Listen ports. |
| `apache_security_headers` | `true` | Emit X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy (and HSTS when SSL). |

> **RHEL note:** `mod_proxy*` / `mod_headers` are auto-loaded from the base `httpd` package, but
> `mod_ssl` is a separate package - the role installs it automatically when `apache_enable_ssl` is set.

> **ALB caveat:** because `apache_enabled` derives from `openspecimen_app_url`, setting the public
> URL (incl. via the Jenkins `APP_URL` parameter) auto-enables Apache. ALB-fronted hosts that do not
> want a local Apache must set `apache_enabled: false` in inventory.

---

## Instances — one per customer folder (ADR-009)

Each `inventory/customers/<name>/` deploys **one** OpenSpecimen instance,
described by the flat vars in this reference (service `openspecimen`,
`CATALINA_BASE == CATALINA_HOME`, ports 8080/8009/8005, context `/openspecimen`).
`tasks/resolve-instances.yml` assembles them into the single internal
`_instances` entry the roles consume. There is no instance list, no name/index
derivation, and no `-e instance=<name>` selection (ADR-009 supersedes ADR-006/007).

To run **two** environments on one VM (e.g. prod + test), create **two customer
folders** pointing `openspecimen_host` at the same VM and override the colliding
values explicitly in each:

| Variable | Default | Override in the 2nd folder |
|----------|---------|----------------------------|
| `openspecimen_port` | `8080` | e.g. `8090` |
| `openspecimen_context_path` | `/openspecimen` | e.g. `/openspecimen-test` |
| `openspecimen_service_name` | `openspecimen` | e.g. `openspecimen-test` |
| `catalina_base` | `{{ tomcat_home }}` | a separate path, e.g. `/usr/local/openspecimen/test/tomcat-as` |
| `openspecimen_data_dir` / `openspecimen_plugin_dir` / `openspecimen_backup_dir` | under `/usr/local/openspecimen` | separate paths |
| `mysql_db_name` / `mysql_db_user` | `openspecimen` | a separate schema |

---

## Component version specs (`os_versions`)

`site.yml` loads `component-specs/<release>.yml` (release with the
`openspecimen_` prefix stripped), merges any per-customer
`component_versions_override`, and exposes the result as `os_versions` to the
roles (used for `tomcat_version`, Java track, etc.). No spec file → built-in
defaults (Java 17) + a warning. See [`component-specs/README.md`](component-specs/README.md).

---

## Quick change guide

For the three most common post-deploy changes on the **single default instance**
without a full Ansible re-run, use the on-box helper script. (For multi-instance
hosts, or to keep the change inventory-driven, use the `update-heap.yml` /
`update-app-url.yml` / `update-db-pool.yml` playbooks instead - see
[`docs/DEPLOY-UPGRADE.md`](docs/DEPLOY-UPGRADE.md#day-2-config-change-playbooks).)

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

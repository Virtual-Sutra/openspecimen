# Multiple OpenSpecimen instances per host

> **⚠️ SUPERSEDED by ADR-009 (2026-07).** The `openspecimen_instances` list and
> its name/index derivation described below have been **removed**. Deploy **one
> instance per customer folder** instead: two environments on one VM (e.g. prod +
> test) are two customer folders pointing `openspecimen_host` at the same VM, each
> overriding the colliding values (`openspecimen_port`, `openspecimen_context_path`,
> `openspecimen_service_name`, `catalina_base`, data/plugin/backup dirs, DB)
> explicitly. See CONFIG-REFERENCE.md "Instances — one per customer folder". This
> document is retained only for historical context.

Run N independent OpenSpecimen instances on one VM (e.g. `prod` + `test`), each
fully isolated: its own `CATALINA_BASE` off a shared Tomcat binary
(`CATALINA_HOME`), ports, data/plugin/backup dirs, database + user, heap, and
systemd unit. This is the **per-instance Tomcat runtime** model
(ADR-003 / ADR-006, #72/#73).

`openspecimen_instances` (a list in `inventory/group_vars/all.yml`) is the
deployment model. `site.yml` runs the base roles host-level once, then loops the
app roles over each instance (`tasks/deploy-instance.yml`) - so direction
detection (deploy / rollback / no-op) and the fresh-vs-upgrade / fast-path logic
are all **per instance**. One instance rolling back or being already-current does
not stop the others.

## Single instance (the default — nothing to do)

`openspecimen_instances` ships in `group_vars/all.yml` with **one** entry using
the standard single-host layout (service `openspecimen`, `CATALINA_BASE` = the
shared Tomcat, ports 8080/8009/8005, context `/openspecimen`). That entry reads
the flat vars (`mysql_db_name`, `openspecimen_port`, the data/plugin/backup
dirs, …), so a single-instance host needs no extra configuration.

## Multiple instances (infrequent)

Running more than one instance on a host is uncommon. When you need it, **override
`openspecimen_instances`** with N entries.

> **Where to put the override:** the Jenkins/ops pipeline runs with `-i inventory/`,
> under which the top-level `inventory/group_vars/all.yml` loads but per-customer
> `inventory/customers/<name>/group_vars/` subdirectories do **not**. So a
> multi-instance `openspecimen_instances` override belongs in
> `inventory/host_vars/<customer>.yml` (always loaded by hostname), not in the
> per-customer `group_vars/`. (For a self-hosted run with
> `-i inventory/customers/<name>/`, the customer `group_vars/openspecimen.yml` is
> loaded and either location works.)

```yaml
openspecimen_instances:
  - name: prod                       # required; ^[a-z0-9][a-z0-9_-]*$
    db_name: os_prod                 # required - one DB + user per instance
    db_user: os_prod                 # required
    db_password: "{{ vault_os_prod_db_password }}"   # required (Vault)
    app_url: https://host.example.org/prod           # required
    heap_max: 6144                   # MB, per instance
    heap_min: 1024
    release: openspecimen_v12.3       # optional; defaults to openspecimen_release
  - name: test
    db_name: os_test
    db_user: os_test
    db_password: "{{ vault_os_test_db_password }}"
    app_url: https://host.example.org/test
    heap_max: 2048
    heap_min: 512
```

Only `name`, `db_name`, `db_user`, `db_password`, `app_url` are required. The rest
derive from `name` + list index:

| Field | Derivation |
|-------|------------|
| `service_name` | `openspecimen-<name>` |
| `catalina_base` | `<openspecimen_instances_base>/<name>/base` |
| `data_dir` / `plugin_dir` / `backup_dir` | `<openspecimen_instances_base>/<name>/{data,plugins,backup}` |
| `http_port` / `ajp_port` / `shutdown_port` | base (`8080`/`8009`/`8005`) + index×10 |
| `release` | falls back to `openspecimen_release` |
| `db_host` | falls back to `mysql_db_host` (shared local MySQL) |
| `context_path` | `/openspecimen` — deploys the WAR at that Tomcat context (`webapps/<context>.war`), so a distinct value serves the app under a distinct path |

Override any derived field by setting it explicitly on the instance. Ports are
asserted unique across the host at the start of the run (set explicit `*_port`
values or space the instances out if the derived ports would collide).

## Public routing: domain vs path (`apache_routing_mode`)

When the Apache front-end is enabled, two co-located instances can be published
either on **separate domains** or on **separate paths of one domain**. Both modes
mount each instance at its **context path** and proxy 1:1 to its Tomcat, so `app.url`
is the same in either mode and switching modes needs no app-side change. Pick per
deployment (default `domain`):

| | `apache_routing_mode: domain` (default) | `apache_routing_mode: path` |
|---|---|---|
| Domain | **different** per instance (`apache_server_name` from each `app.url`) | **one shared** (`apache_shared_server_name`) |
| Path | **common** context path across the domains | **distinct** context path per instance |
| Example | `https://prod.example.com/openspecimen`  ·  `https://test.example.com/openspecimen` | `https://example.com/openspecimen`  ·  `https://example.com/openspecimen-test` |
| Apache | one full vhost per instance | one shared base vhost that `Include`s one drop-in snippet per instance (`<dropin>/<service>.conf`) |

**Path mode setup:** give each instance a distinct `context_path` (e.g. `/openspecimen`
and `/openspecimen-test`) — this deploys its WAR at that Tomcat context (`openspecimen-test.war`
→ `/openspecimen-test`), so the app is genuinely served there and Apache proxies 1:1.
Set each `app.url` to `https://<shared-host><context_path>`, and set `apache_routing_mode: path`. The shared base vhost (`openspecimen-shared.conf`)
is instance-agnostic — every co-located deploy renders it identically — and each deploy
manages only its own path snippet. Trailing-slash mounts keep sibling paths from
overlapping, so Include order is irrelevant. In path mode all instances share one TLS
cert (same host).

**Switching modes** for an instance is clean: a `domain`-mode deploy removes that
instance's stale path snippet, and a `path`-mode deploy removes its stale domain vhost.

## Per-instance Tomcat runtime

One shared Tomcat binary (`CATALINA_HOME` = `tomcat_home`, installed host-level)
serves every instance. Each instance gets its own `CATALINA_BASE` containing its
own `conf/`, `logs/`, `temp/`, `work/`, `webapps/` and `bin/`:

| Per-instance file | Set from | What differs per instance |
|-------------------|----------|---------------------------|
| `conf/server.xml` | seeded from the golden `CATALINA_HOME/conf`, then port-patched | HTTP / AJP / shutdown ports (base + index×10) |
| `conf/context.xml` | `context.xml.j2` | JNDI datasource → the instance's `db_name` / `db_user` / `db_password` / `db_host` |
| `conf/openspecimen.properties` | `openspecimen.properties.j2` | `app.url`, data/plugin/backup dirs, node name |
| `bin/setenv.sh` | `setenv.sh.j2` | `-Xms`/`-Xmx` from the instance's `heap_min`/`heap_max` |
| `webapps/openspecimen.war` | release zip | the instance's `release` |
| `/etc/systemd/system/<service_name>.service` | `openspecimen.service.j2` | one unit per instance, `CATALINA_BASE`/`CATALINA_HOME` env |

The AJP connector is patched per `CATALINA_BASE` (`secretRequired="false"`, bound
to `127.0.0.1` - Ghostcat/CVE-2020-1938). For the **single default instance**
`CATALINA_BASE == CATALINA_HOME`, so the conf-seed is skipped and every templated
file lands directly on the shared Tomcat - behaviour is identical to a plain
single-host setup.

## Database

One shared MySQL server, **one database + one dedicated user per instance**.
Server settings (`lower_case_table_names=1`, charset, InnoDB buffer pool sized
for the whole host) are configured once; each instance's DB + user are created
per instance. Liquibase state is per-database, so upgrades, rollbacks and
downgrades are independent per instance. For RDS/Oracle (`db_managed: false`),
the DBA pre-creates one database/schema + user per instance.

## Resource sizing (memory)

Tomcat **heap is per-instance** and there is **no auto-split**: the default
`tomcat_heap_max` is `max(2048 MB, 50% of the whole host's RAM)`, computed
independently per instance. So **two instances left at the default each grab 50%
of total RAM → 100% for heap alone**, plus MySQL and the OS → over-commit / OOM.

**With more than one instance you must size each explicitly.** Under the
one-folder-per-instance model (ADR-009) the lever is per customer folder, in its
`group_vars/all/20-customer.yml`:

```yaml
tomcat_heap_max_override: "6144"   # -Xmx6144m for THIS instance (integer MB)
tomcat_heap_min_override: "1024"   # -Xms1024m
```

Budget the host RAM:

```
host RAM
  − OS + per-JVM off-heap    (~1 GB OS; each JVM uses ~0.5 GB beyond -Xmx for
                              metaspace / threads / direct buffers)
  − MySQL InnoDB buffer pool  (HOST-LEVEL, one mysqld for the box; default 25% of
                              RAM, via mysql_innodb_buffer_pool_size_override, MB)
  = split between the Tomcat heaps (each -Xmx ≥ 2048 — OpenSpecimen's floor)
```

Example — 16 GB host, prod + test co-located: MySQL ~4 GB (25%), OS + 2× off-heap
~3 GB, leaving ~9 GB → prod `tomcat_heap_max_override: "6144"`, test `"2048"`.

The **InnoDB buffer pool is host-level** (sized once; keep any
`mysql_innodb_buffer_pool_size_override` equal in both folders, since both
re-template `my.cnf`).

**Guardrail:** each deploy sums the `-Xmx` of every instance's `setenv.sh` on the
host + the MySQL buffer + an OS reserve + a per-JVM off-heap estimate, and **fails**
if the total exceeds RAM (so a mis-sized instance is caught before it OOMs — and,
inside the deploy, triggers auto-rollback). Tune with `openspecimen_memory_guardrail`
(`fail` | `warn` | `off`), `openspecimen_mem_os_reserve_mb`, `openspecimen_mem_jvm_offheap_mb`.

## Deploying / upgrading one instance

```bash
# all instances
ansible-playbook -i inventory/customers/<name>/ site.yml -e @secrets/<name>.yml ...

# just one
ansible-playbook -i inventory/customers/<name>/ site.yml -e instance=test -e @secrets/<name>.yml ...
```

`-e instance=<name>` limits the run to that instance; the others are untouched.

## `-e instance=<name>` support per playbook

`-e instance=<name>` works in any playbook that resolves
`openspecimen_instances` (it imports `tasks/resolve-instances.yml` and loops):

| Playbook | Loops instances? | `-e instance=<name>` |
|----------|------------------|----------------------|
| `site.yml` | Yes | Yes - deploy/upgrade/auto-rollback one instance |
| `cleanup.yml` | Yes | Yes - tear down one instance |
| `update-heap.yml`, `update-app-url.yml`, `update-db-pool.yml`, `status.yml` | Yes | Yes - act on one instance |
| `verify-customer.yml` | Yes | Yes |
| `rollback.yml`, `db-backup.yml`, `db-restore.yml` | **No** | **No** - these run once against the **flat** vars, i.e. the single default instance only |

For a **multi-instance** host, roll one instance back via the auto-rollback path -
request an older release for just that instance:

```bash
ansible-playbook -i inventory/customers/<name>/ site.yml \
  -e instance=test -e openspecimen_release=openspecimen_v12.2.RC8 \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

The standalone `rollback.yml` / `db-backup.yml` / `db-restore.yml` are intended
for single-instance hosts (they act on the flat `catalina_base` /
`openspecimen_backup_dir` / `openspecimen_service_name`, not per instance).

## Tearing down one instance

```bash
ansible-playbook -i inventory/customers/<name>/ cleanup.yml \
  -e cleanup_confirm=true -e instance=test \
  -e @secrets/<name>.yml --vault-password-file .vault-pass
```

Per-instance cleanup removes that instance's service, webapp, its isolated
`CATALINA_BASE`, data/plugins/backups/markers and (local MySQL) its DB + user,
leaving the shared Tomcat/MySQL/Java for the other instances. `-e full_wipe=true`
removes the shared bits too (whole-host reset).

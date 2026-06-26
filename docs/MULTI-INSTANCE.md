# Multiple OpenSpecimen instances per host

Run N independent OpenSpecimen instances on one VM (e.g. `prod` + `test`), each
fully isolated: its own Tomcat (a `CATALINA_BASE` off a shared `CATALINA_HOME`),
context, ports, data/plugin/backup dirs, database + user, heap, and systemd unit.
This is the **1:1 Tomcat-per-deployment** model (ADR-003 / ADR-006).

> **Status:** the instance model + per-instance database provisioning land in #72
> (this change). Per-instance Tomcat/ports (#73) and the Apache per-instance
> vhost (#74) follow. A single-instance host is unaffected today.

## Single instance (default — nothing to do)

Leave `openspecimen_instances` **unset**. The deploy synthesises one default
instance from the existing flat vars, pinned to today's exact values (unit name
`openspecimen`, `CATALINA_BASE == CATALINA_HOME == {{ tomcat_home }}`, ports
8080/8009/8005, context `/openspecimen`, the existing data/plugin/backup dirs).
Behaviour is byte-identical to before.

## Multiple instances

Declare them in the customer inventory:

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
| `context_path` | `/openspecimen` (constant — isolation is by base, not path) |

Override any derived field by setting it explicitly on the instance. Ports are
asserted unique across the host at the start of the run.

## Database

One shared MySQL server, **one database + one dedicated user per instance**.
Server settings (`lower_case_table_names=1`, charset, InnoDB buffer pool sized
for the whole host) are configured once; each instance's DB + user are created
per instance. Liquibase state is per-database, so upgrades, rollbacks and
downgrades are independent per instance. For RDS/Oracle (`db_managed: false`),
the DBA pre-creates one database/schema + user per instance.

## Resource sizing

Tomcat **heap is per-instance** (set `heap_max`/`heap_min`; do not rely on the
single-tenant 50%-of-RAM default with multiple instances). The InnoDB **buffer
pool is host-level** (sized once for the whole box). Together these keep N
instances from over-subscribing memory.

## Deploying / upgrading one instance

```bash
# all instances
ansible-playbook -i inventory/customers/<name>/ site.yml -e @secrets/<name>.yml ...

# just one
ansible-playbook -i inventory/customers/<name>/ site.yml -e instance=test -e @secrets/<name>.yml ...
```

`-e instance=<name>` limits the run to that instance; the others are untouched.
The same flag applies to rollback and the DB backup/restore playbooks.

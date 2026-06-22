# Multiple OpenSpecimen instances on one VM (multi-context)

Status: **in progress** - feature branch `feat/multi-instance-contexts`.
Epic: openspecimen-ansible#71. Deferred alternative (one Tomcat per instance):
openspecimen-ansible#83.

## Goal
Run several OpenSpecimen instances (e.g. `prod` and `test`) on a single VM,
fronted by one Apache VirtualHost with per-context proxying:

```
ProxyPass /prod ajp://127.0.0.1:8009/prod
ProxyPass /test ajp://127.0.0.1:8009/test
```

## Chosen approach: one Tomcat, multiple webapp contexts
A single Tomcat (one `CATALINA_BASE`, one JVM, one AJP connector on `:8009`)
serves each instance as its own webapp **context** (`/prod`, `/test`). Apache
routes by context path.

The deferred alternative - one Tomcat **per** instance (separate base, ports,
heap, systemd) for full isolation - is tracked in #83.

### Why this works for *different DBs / config per instance*
OpenSpecimen finds its DB and config via two JNDI entries that are in the
**global** `conf/context.xml` today:

```xml
<Resource name="jdbc/openspecimen" .../>                              <!-- the DB -->
<Environment name="config/openspecimen"
             value="<base>/conf/openspecimen.properties" .../>        <!-- properties path -->
```

Tomcat supports **per-context descriptors** at
`conf/Catalina/localhost/<context>.xml`. By giving each context its own
descriptor, each instance gets its **own** `jdbc/openspecimen` datasource and its
**own** `config/openspecimen` properties path - so `/prod` and `/test` can point
at different databases, data dirs, `node.name`, and `app.url`, all inside one
Tomcat.

### Trade-offs (vs one-Tomcat-per-instance, #83)
- One JVM ⇒ **shared heap**; an OOM/crash in one instance affects all.
- Restart/upgrade of the Tomcat restarts **all** contexts (no independent
  lifecycle).
- Heap cannot be tuned per instance.

These are acceptable for the initial multi-context support; #83 removes them.

## Inventory model (#72)
A host declares its instances with `openspecimen_instances`:

```yaml
openspecimen_instances:
  - name: prod                 # context path /prod; safe identifier
    db_managed: true
    mysql_db_name: os_prod
    mysql_db_user: os_prod
    app_url: https://host/prod
    node_name: prod
    # data/plugin/backup dirs default to /usr/local/openspecimen/<name>/...
  - name: test
    db_managed: true
    mysql_db_name: os_test
    mysql_db_user: os_test
    app_url: https://host/test
    node_name: test
```

Each instance carries its own DB target, paths, heap (informational only in
multi-context - heap is shared), `app_url`, and `node_name`. The AJP port is
shared (`apache_ajp_port`, default 8009).

**Backward compatible:** a host with **no** `openspecimen_instances` deploys
exactly as today - a single `/openspecimen` context built from the existing flat
vars (`mysql_db_name`, `openspecimen_data_dir`, `openspecimen_app_url`, …).
Internally the roles normalise that to a one-element instance list.

## Component work

| Area | Change | Issue | Status |
|------|--------|-------|--------|
| Inventory model | `openspecimen_instances` + single-instance normalisation | #72 | this branch |
| Apache vhost | one `ProxyPass`/`ProxyPassReverse`/`ProxyPassReverseCookiePath` block per context on the shared AJP port; single-context fallback unchanged | #74 | this branch (first) |
| Tomcat | per-context descriptor `conf/Catalina/localhost/<name>.xml` (per-instance datasource + config path) | #73 | next |
| openspecimen role | deploy WAR as `<name>.war` (context `/<name>`); per-instance `openspecimen-<name>.properties`, data/plugin/backup dirs; per-instance backup/upgrade/rollback | #73 | next |
| Database | per-instance DB/schema/user when `db_managed`; per-instance JDBC for RDS/Oracle | #73 (+ follow-up) | next |
| Deploy flow / Jenkins | iterate instances (or select one via a Jenkins `INSTANCE` param) | #71 follow-up | next |

## Capacity note
All instances share one JVM heap. Size `tomcat_heap_max` for the **combined**
working set of every instance on the box. (Per-instance heap is a reason to move
to #83.)

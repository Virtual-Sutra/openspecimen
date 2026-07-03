# Troubleshooting

Common errors and their fixes.

---

## Error message format

Every failure path in the role emits an operator-friendly message in this format:

```
✗ <one-line summary of what failed>

<context: customer, release, host, paths>

What likely happened: (when diagnosable)
What to check:
  1. <concrete check + command you can copy-paste>
  2. <concrete check + command>
  ...

How to fix:
  - <specific action or inventory edit>
```

If you see this format, the message itself usually contains everything you need - paths to
inspect, commands to run on the Jenkins VM or target, and the inventory file to edit.

If you see a plain Ansible failure (no `✗` prefix), it's likely a generic SSH, package, or
systemd issue - check the sections below or `journalctl` on the target.

---

## Enabling extra diagnostics

To print the inventory + variable resolution context at the top of a play (host,
inventory_dir, release, builds_dir, db settings, plugin lists), pass:

```bash
-e openspecimen_debug=true
```

Useful during customer onboarding or when troubleshooting "variable X has the
wrong value" issues. Off by default to keep healthy deploy logs clean.

---

## Pre-flight failures

Pre-flight runs as a `pre_task` in `site.yml` - **before any role executes**.
Most failures here mean inventory + on-disk state are out of sync.

| Error | Cause | Fix |
|-------|-------|-----|
| `openspecimen_release is not set` | Missing `-e openspecimen_release=...` | Pass it at run time. Never store in `group_vars`. |
| `openspecimen_release format is invalid` | Value doesn't match `openspecimen_<version>` | Use the exact zip filename minus `.zip` - e.g. `openspecimen_v12.2.RC12`. |
| `mysql_db_password is not set, but db_managed=true` | Vault secrets file not loaded, or `-e mysql_db_password` not passed | Pass via `-e @secrets/<customer>.yml` (Vault) or `-e mysql_db_password=<pwd>` |
| `Release zip not found on the Jenkins VM` | Zip not uploaded, or wrong filename | Upload to `openspecimen_builds_dir` on the Jenkins VM; filename must match `openspecimen_release` exactly. |
| `Paid plugin zip not found anywhere under <builds_dir>` | Plugin zip missing or wrong version suffix | Place `<plugin-name>-<version>.zip` in the same directory as the release zip. Version = `openspecimen_release` minus `openspecimen_` prefix. |
| `Customer plugin zip not found...` | Same as above for customer plugins | Same fix; or remove the plugin from `inventory/host_vars/<customer>.yml` if it's no longer needed. |

---

## `openspecimen_release` is empty - "version required" error

**Symptom:** The run fails with `✗ openspecimen_release is not set` (direction
detection) or `openspecimen_release is not set for <host>` (version check).

**Cause:** `openspecimen_release` was not passed at run time.

**Fix:** Always supply it explicitly:

```bash
ansible-playbook ... -e openspecimen_release=openspecimen_v12.3
```

The variable is intentionally NOT stored in `group_vars` - it must be injected
at each run so the playbook stays idempotent regardless of who runs it.

---

## SSH: Permission denied (publickey)

**Symptom:** Playbook fails with `Permission denied (publickey)` connecting to
the target node.

**Checklist:**
1. Confirm `ansible_ssh_private_key_file` is set in the customer hosts file or
   passed via `-e`.
2. Verify the public key is in `~/.ssh/authorized_keys` on the target node.
3. Test manually: `ssh -i /path/to/key user@host echo ok`

---

## Health check times out after deploy

**Symptom:** The post-restart readiness gate ("Wait until OpenSpecimen serves the
app") times out with "Condition check failed".

**How the gate probes** (so you know what "up" means): when the instance is
Apache-fronted (`apache_enabled`, typically AJP), a direct `localhost:<port>` hit
answers `302/403` because the request `Host` ≠ `app.url` - so the gate instead
probes `app_url/ui-app/` through the **local** Apache (`curl --resolve <host>:<port>:127.0.0.1`,
`-k` since it's a liveness probe). Otherwise (direct Tomcat, or ALB-direct) it
probes `localhost:<port>` and accepts `200|302|401|403`. So a timeout means the
app truly isn't serving through that path - not a code/URL mismatch.

**Common causes:**

| Cause | Fix |
|-------|-----|
| Wrong `openspecimen_port` | Check `inventory/group_vars/all.yml`; default is `8080` |
| Wrong `openspecimen_app_url` | If set, it must match the actual URL Tomcat answers on |
| Database connection failure | Check `catalina.out` on the target; verify the DB password passed via `-e mysql_db_password` |
| Tomcat startup too slow | Increase `openspecimen_health_retries` or `openspecimen_health_delay` in `group_vars` |

To check Tomcat logs on the target (single default instance):

```bash
sudo tail -f /usr/local/openspecimen/tomcat-as/logs/catalina.out
```

On a **multi-instance** host each instance has its own `CATALINA_BASE`, so the log
is `<openspecimen_instances_base>/<name>/base/logs/catalina.out`. Use `status.yml`
to see every instance's service state, HTTP health, port, heap and pool at a glance:

```bash
ansible-playbook -i inventory/customers/<name>/ status.yml
#   one instance:  ... -e instance=<name>
```

---

## Requested an older release - what happens

A requested release **lower** than what's installed is **no longer blocked**.
Per-instance direction detection treats it as a downgrade and automatically runs
the rollback flow for that instance: it restores the backup whose `.release`
matches the requested version. There is no "Downgrade is not supported" hard-stop
(it was removed - see ADR-004).

A downgrade also covers `master` builds: `master` → any tagged release, and
`master` → an older `master` snapshot (compared by the `-DD-MM-YYYY` date, since
day-first dates misrank under `sort -V`) both route to rollback. So a deploy that
fails with "No backup found" can mean you asked to move off a `master` build to an
older release with no matching backup on the node.

Two things can still halt a downgrade, both with operator guidance:

- **No matching backup** for the requested version (e.g. it was pruned by
  `openspecimen_backup_retention`). The play lists the available backups. Pick a
  version that has a backup, or deploy from the older release zip with
  `-e allow_downgrade=true`.
- **Schema moved forward** - Liquibase applied migrations after the backup was
  taken (see [Schema-downgrade safeguard](DEPLOY-UPGRADE.md#schema-downgrade-safeguard)).
  Use a more recent backup, restore the DB too (`-e restore_db=true`), or override
  with `-e allow_downgrade=true` once the schema is known safe.

To force a fresh (re)deploy of the same version regardless of the markers, pass
`-e force_deploy=true`.

---

## MySQL: "Table names cannot be changed after init"

**Symptom:** MySQL role fails or Liquibase migration fails with character set
or case sensitivity errors.

**Cause:** `lower_case_table_names=1` and `character-set-server=utf8` are
written to `mysqld.cnf` **before** MySQL is initialised and cannot be changed
afterward without recreating the data directory.

**Fix for fresh install:** Remove the data directory and let the role
reinitialise:

```bash
sudo systemctl stop mysql
sudo rm -rf /var/lib/mysql
```

Then re-run `site.yml`.

---

## Plugin zip contained no `.jar` files

**Symptom:**
```
✗ Paid plugin zip <name> contained no .jar files.
```

**Cause:** The zip was found, but `unzip -jo "<zip>" "*.jar"` extracted nothing.
The zip might be empty, contain only documentation, or contain the JAR under a glob that
shells expand differently.

**Fix:** Inspect the zip and re-package it so it contains at least one `.jar` at any path
depth:

```bash
unzip -l /path/to/<plugin>-<version>.zip
# Should list at least one *.jar entry
```

If the plugin is no longer needed, remove it from `openspecimen_paid_plugins` or
`openspecimen_customer_plugins` in `inventory/host_vars/<customer>.yml`.

---

## `set: Illegal option -o pipefail`

**Symptom:** A `shell` task fails with `/bin/sh: 1: set: Illegal option -o pipefail`,
typically before the actual work starts.

**Cause:** The task uses `set -o pipefail` but the default shell is `/bin/sh` (dash on
Ubuntu), which does not support pipefail.

**Fix:** This is a regression in the role - report it. The fix is to add
`args: executable: /bin/bash` to the affected task.

---

## Idempotency: playbook reports `changed` on every run

**Common sources:**

| Task | Why it changes | Fix |
|------|---------------|-----|
| A `shell`/`command` task | Always runs | Verify the command is idempotent; add `changed_when: false` if no state changes |
| Service restart handler | Triggered by a config change upstream | Check which `notify` fired; suppress the config task if inputs haven't changed |

Run with `--check` to see what would change without applying it:

```bash
ansible-playbook ... --check
```

---

## RHEL 9: Python 3 not found

**Symptom:** `The module failed to execute` or `python3 not found`.

**Fix:** Install Python 3 on the target before running:

```bash
sudo dnf install -y python3
```

Or set in inventory:

```ini
[openspecimen:vars]
ansible_python_interpreter=/usr/bin/python3
```

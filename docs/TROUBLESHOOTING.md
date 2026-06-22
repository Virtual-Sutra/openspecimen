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

If you see this format, the message itself usually contains everything you need — paths to
inspect, commands to run on the Jenkins VM or target, and the inventory file to edit.

If you see a plain Ansible failure (no `✗` prefix), it's likely a generic SSH, package, or
systemd issue — check the sections below or `journalctl` on the target.

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

Pre-flight runs as a `pre_task` in `site.yml` — **before any role executes**.
Most failures here mean inventory + on-disk state are out of sync.

| Error | Cause | Fix |
|-------|-------|-----|
| `openspecimen_release is not set` | Missing `-e openspecimen_release=...` | Pass it at run time. Never store in `group_vars`. |
| `openspecimen_release format is invalid` | Value doesn't match `openspecimen_<version>` | Use the exact zip filename minus `.zip` — e.g. `openspecimen_v12.2.RC12`. |
| `mysql_db_password is not set, but db_managed=true` | Vault secrets file not loaded, or `-e mysql_db_password` not passed | Pass via `-e @secrets/<customer>.yml` (Vault) or `-e mysql_db_password=<pwd>` |
| `Release zip not found on the Jenkins VM` | Zip not uploaded, or wrong filename | Upload to `openspecimen_builds_dir` on the Jenkins VM; filename must match `openspecimen_release` exactly. |
| `Paid plugin zip not found anywhere under <builds_dir>` | Plugin zip missing or wrong version suffix | Place `<plugin-name>-<version>.zip` in the same directory as the release zip. Version = `openspecimen_release` minus `openspecimen_` prefix. |
| `Customer plugin zip not found...` | Same as above for customer plugins | Same fix; or remove the plugin from `inventory/host_vars/<customer>.yml` if it's no longer needed. |

---

## `openspecimen_release` is empty — "downgrade" or "version required" error

**Symptom:** Version check reports `Requesting:  ` (empty string) and blocks
with "Downgrade is not supported" or "openspecimen_release is required".

**Cause:** `openspecimen_release` was not passed at run time.

**Fix:** Always supply it explicitly:

```bash
ansible-playbook ... -e openspecimen_release=openspecimen_v12.3
```

The variable is intentionally NOT stored in `group_vars` — it must be injected
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

**Symptom:** The `openspecimen` role waits for the health check URL and times
out with "Condition check failed".

**Common causes:**

| Cause | Fix |
|-------|-----|
| Wrong `openspecimen_port` | Check `inventory/group_vars/all.yml`; default is `8080` |
| Wrong `openspecimen_app_url` | If set, it must match the actual URL Tomcat answers on |
| Database connection failure | Check `catalina.out` on the target; verify the DB password passed via `-e mysql_db_password` |
| Tomcat startup too slow | Increase `openspecimen_health_retries` or `openspecimen_health_delay` in `group_vars` |

To check Tomcat logs on the target:

```bash
sudo tail -f /usr/local/openspecimen/tomcat-as/logs/catalina.out
```

---

## Upgrade blocked: "Downgrade is not supported"

**Symptom:** The version check task fails because the requested release is older
than what is installed.

**Cause:** The marker file `/usr/local/openspecimen/.release` on the target
contains a higher version than `openspecimen_release`.

**Fix:** Either specify the correct (newer) release, or — for a deliberate
downgrade — clear the marker file manually and restore from backup:

```bash
sudo systemctl stop openspecimen
sudo rm /usr/local/openspecimen/.release
# restore WAR from backup — see DEPLOY-UPGRADE.md rollback section
```

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

**Fix:** This is a regression in the role — report it. The fix is to add
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

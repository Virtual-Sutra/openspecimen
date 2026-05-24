# Troubleshooting

Common errors and their fixes.

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
| Database connection failure | Check `catalina.out` on the target; verify DB credentials in `secrets/<name>.yml` |
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

## Vault decryption fails

**Symptom:** `ERROR! Decryption failed (no vault secrets would decrypt)`.

**Fix:**
1. Check that `.vault-pass` contains the correct passphrase.
2. Check that the secrets file was encrypted with that passphrase:
   ```bash
   ansible-vault view secrets/<name>.yml --vault-password-file .vault-pass
   ```
3. Re-encrypt if needed:
   ```bash
   ansible-vault rekey secrets/<name>.yml
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

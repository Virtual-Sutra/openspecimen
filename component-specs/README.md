# Component version specs

Release-pinned baselines for the dependency components a deployment installs
(Tomcat, Java, MySQL, Apache). One file per OpenSpecimen release.

## How it works

`site.yml` resolves the spec for the release being deployed:

1. `openspecimen_release` (e.g. `openspecimen_v12.2.RC12`) → the `openspecimen_`
   prefix is stripped → `component-specs/v12.2.RC12.yml`.
2. If that file exists it is loaded; its `component_spec` is merged with any
   per-customer `component_versions_override`, and the result is exposed to the
   roles as **`os_versions`**.
3. If no file exists, built-in defaults are used (Java 17) and a warning is
   logged — deploys remain backward compatible.

Precedence (lowest → highest): built-in defaults → `component_spec` (this file)
→ `component_versions_override` (customer inventory).

## Pinning model (ADR-002)

| Components | Kind | Notes |
|------------|------|-------|
| `tomcat` | pinned exact | installed from a pinned download by the tomcat role |
| `java`, `mysql`, `apache` | track + validated build | OS packages; pin the track, record the tested build |
| connectors | from the release zip | bundled like the WAR/plugins; commented placeholders only |

## Adding a release

Generate a draft from a running host with the ops discovery playbook
(`discover-versions.yml`), review it, then commit it here:

```bash
cp component-specs/_template.yml component-specs/v12.3.yml
$EDITOR component-specs/v12.3.yml
```

## Per-customer override

Set in the customer inventory (no need to edit these files):

```yaml
component_versions_override:
  tomcat: "9.0.71"
  java: { track: "21" }
```

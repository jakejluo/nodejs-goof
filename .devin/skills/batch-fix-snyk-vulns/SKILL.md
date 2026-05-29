---
name: batch-fix-snyk-vulns
description: >
  Scans the repository with Snyk, groups overlapping vulnerabilities by
  package/upgrade-path, and spins up parallel child Devin sessions to fix
  each group in a dedicated PR. Overlapping vulns are combined into one PR
  to simplify review and avoid merge conflicts.
---

# Batch Fix Snyk Vulnerabilities

Scan the repository with Snyk, group overlapping vulnerabilities, and spin up
child Devin sessions to fix each group in a dedicated PR. Overlapping
vulnerabilities (same package, shared upgrade path, or transitive dependency
chain) are combined into a single PR so the reviewer sees one cohesive change
instead of multiple conflicting ones.

## Prerequisites

- The `snyk-security-scanner` MCP server must be installed and enabled.
- The `SNYK_TOKEN` secret must be available in the environment.
- The repository to scan must be cloned locally.

## Inputs

When invoking this skill you may include the following in the prompt:

| Input | Default | Description |
|---|---|---|
| `repo` | `jakejluo/nodejs-goof` | GitHub `owner/repo` identifier |
| `repo_path` | `/home/ubuntu/repos/nodejs-goof` | Absolute path to local clone |
| `severity_threshold` | `high` | Minimum severity to fix: `low`, `medium`, `high`, or `critical` |
| `max_groups` | `5` | Maximum number of child sessions to spin up |
| `dry_run` | `false` | If `true`, report the groups but do not spin up child sessions |

## Steps

### 1. Trust the project folder

Use the **snyk_trust** MCP tool so Snyk is allowed to scan the directory:

```
tool: snyk_trust
server: snyk-security-scanner
args:
  path: <repo_path>
```

### 2. Run the Snyk SCA scan

Use the **snyk_sca_scan** MCP tool:

```
tool: snyk_sca_scan
server: snyk-security-scanner
args:
  path: <repo_path>
  severity_threshold: low          # always scan at low; we filter later
```

Capture the full JSON output — it contains `issueCount` and an `issues` array.

### 3. (Optional) Run the Snyk Code (SAST) scan

```
tool: snyk_code_scan
server: snyk-security-scanner
args:
  path: <repo_path>
  severity_threshold: low
```

If Snyk Code is not enabled for the org, skip gracefully — do **not** block.

### 4. Filter vulnerabilities by severity threshold

From all collected issues, keep only those whose severity meets or exceeds the
configured `severity_threshold` (default: `high`). Severity order:
**critical > high > medium > low**.

### 5. Group overlapping vulnerabilities

Group the filtered vulnerabilities so that each group can be fixed in a single
PR without conflicting with other groups. Apply these rules **in order**:

1. **Same direct dependency** — If two or more vulnerabilities are in (or fixed
   by upgrading) the same top-level dependency listed in `package.json`, they
   belong to the same group.
2. **Shared upgrade path** — If Snyk reports that upgrading package A also fixes
   a vulnerability in transitive dependency B, merge the groups for A and B.
3. **Same vulnerable package (transitive)** — If multiple issues affect the same
   transitive package and are reachable through different direct dependencies,
   group them together since the fix likely touches both direct dependencies in
   `package.json`.

After grouping:

- Sort groups by **total severity score** descending (critical=4, high=3,
  medium=2, low=1; sum across all issues in the group).
- If there are more groups than `max_groups`, keep the top `max_groups` groups
  and note the remaining ones in the final report as "deferred."

### 6. Report the grouping plan

Before spinning up child sessions, send a summary to the user via
`message_user` (non-blocking). The summary should look like:

```
Snyk Batch Fix Plan — <repo>
Date: <today>

Total vulnerabilities found: <count>
After filtering (>= <severity_threshold>): <count>
Groups formed: <count> (max <max_groups>)

Group 1: <primary package(s)>
  Vulnerabilities: <count> (Critical: N, High: N, ...)
  Fix: Upgrade <pkg>@<current> -> <target> (+ related transitive fixes)
  CVEs: CVE-XXXX-YYYY, CVE-XXXX-ZZZZ, ...

Group 2: ...
  ...

Deferred (not fixed this run): <count> vulnerabilities
```

If `dry_run` is `true`, stop here and send the report as a blocking message.

### 7. Spin up child sessions

Use the **devin_session_create** Devin MCP tool to create one child session per
group. For each group, construct the prompt as follows:

```
tool: devin_session_create
server: devin (MCP)
args:
  repos: ["<owner/repo>"]
  sessions:
    - title: "Fix Snyk vulns: <primary package(s)>"
      prompt: |
        Fix the following Snyk vulnerabilities in <owner/repo> by creating a
        single PR.

        ## Vulnerabilities to fix

        <For each vulnerability in the group, list:>
        - **<Title>** (Severity: <severity>)
          Package: <package@version>
          CVE: <CVE-ID or N/A>
          Recommended fix: <upgrade path or description>
          Snyk ID: <snyk-vuln-id>

        ## Instructions

        1. Check out a new branch named `devin/<timestamp>-fix-snyk-<primary-pkg>`.
        2. Update `package.json` (and `package-lock.json`) to apply the
           recommended upgrades. Use `npm install` or direct version edits as
           appropriate.
        3. If the upgrade introduces breaking changes, make the minimal code
           changes needed to keep the application building.
        4. Run `npm install` to regenerate the lockfile.
        5. Run `npm test` (if tests exist) and fix any test failures caused by
           the upgrade.
        6. Commit with message: "fix: upgrade <packages> to address <N> Snyk vulnerabilities"
        7. Create a PR into the default branch. In the PR description, list
           every CVE/vulnerability fixed and the package version changes.
        8. Do NOT modify any files unrelated to the vulnerability fix.
      tags: ["snyk-batch-fix", "<primary-package>"]
```

Send all sessions in a single `devin_session_create` call so they spin up in
parallel. Record the returned session IDs.

### 8. Monitor child sessions

Use **devin_session_gather** to wait for all child sessions to settle:

```
tool: devin_session_gather
server: devin (MCP)
args:
  session_ids: ["devin-<id1>", "devin-<id2>", ...]
  timeout_seconds: 600
  poll_interval_seconds: 30
```

If any session is still running after the timeout, use
**devin_session_interact** (action: `get`) to check its status and report
accordingly.

### 9. Collect results from child sessions

For each settled child session, use **devin_session_interact** (action: `get`)
to retrieve:

- Final status (success / error / waiting)
- Any PR URL created
- Summary of changes made

### 10. Send Snyk feedback

Use the **snyk_send_feedback** MCP tool to report the number of issues fixed:

```
tool: snyk_send_feedback
server: snyk-security-scanner
args:
  path: <repo_path>
  preventedIssuesCount: 0
  fixedExistingIssuesCount: <total vulnerabilities addressed across all groups>
```

### 11. Post the final report

Send a summary to the user via `message_user` (blocking):

```
Snyk Batch Fix Report — <repo>
Date: <today>

Scan Summary:
- Total vulnerabilities: <count>
- Filtered (>= <severity_threshold>): <count>
- Groups created: <count>

Results:

Group 1: <primary package(s)> - <STATUS>
  PR: <url or "No PR created">
  Vulnerabilities addressed: <count>
  Session: <devin session url>

Group 2: ...

Overall: <N>/<M> groups completed successfully, <X> vulnerabilities fixed.
Deferred: <count> vulnerabilities below threshold or beyond max_groups.
```

## Error Handling

- If the SCA scan fails entirely, report the error and stop.
- If a child session fails, include the failure reason in the final report but
  do not block other groups.
- If all child sessions fail, suggest the user review the scan results manually
  and provide the raw vulnerability list.

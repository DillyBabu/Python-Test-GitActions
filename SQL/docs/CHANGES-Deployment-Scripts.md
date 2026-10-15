# Change Log: SQL Deployment Scripts

| | |
|---|---|
| **Date** | 2026-10-10 |
| **Scope** | `Scripts/Deploy-FeatureBasedSQL.ps1`, `Scripts/Parse_FeatureChecklist.ps1`, `Scripts/Publish-DeploymentResults.ps1` |
| **Runtime** | Windows PowerShell 5.1. No new modules or external tools |
| **Not changed** | `Scripts/Generate-EnvironmentCSV.ps1`, `Pipelines/azure-pipelines.yml`, environment configs and checklists, SQL scripts |

## Summary

| # | Change | File(s) | Type |
|---|---|---|---|
| 1 | Each SQL script runs in a single transaction. If any batch fails, the whole script is rolled back | Deploy | Enhancement |
| 2 | More detail in the deployment output (CSV, console, JSON, HTML): server, database, status, transaction outcome, batches and timings for every script | Deploy, Publish | Enhancement |
| 3 | A client named in `Client_Name` is deployed to **every** database it has in the environment config | Parse, Deploy | Enhancement |
| 4 | Bug fixes found while making these changes (Section 4) | Deploy, Publish | Fix |

| File | Lines before | Lines after |
|---|---|---|
| `Deploy-FeatureBasedSQL.ps1` | 680 | 842 |
| `Parse_FeatureChecklist.ps1` | 385 | 411 |
| `Publish-DeploymentResults.ps1` | 451 | 583 (rewritten) |

---

## 1. Script-level transaction and rollback

**Before:** each batch (the text between `GO` lines) committed on its own. If batch 3 of 5 failed, batches 1–2 stayed in the database and the script was left half-applied.

**After:** all batches of a script run inside one `SqlTransaction`.

| Situation | Result |
|---|---|
| All batches succeed | Transaction is **committed**, and `Transaction_Status = Committed` |
| Any batch fails | The **whole script is rolled back**, including the batches that already succeeded. `Transaction_Status = RolledBack`, and `Failed_Batch` records which batch failed |
| Rollback itself fails | `Transaction_Status = RollbackFailed`, and the error is logged |
| SQL Server already ended the transaction (severe error, or the script ran its own `COMMIT`/`ROLLBACK`) | `Transaction_Status = EndedByServer`, with a warning to check the database manually |
| Unexpected error, such as a failed commit | Caught, and the transaction is rolled back |

**Opting out (`-- @NoTransaction`):** some statements can't run inside a transaction, for example `ALTER DATABASE`, `CREATE DATABASE`, `BACKUP` and full-text catalog changes. A script containing those can include this line anywhere:

```sql
-- @NoTransaction
```

That script then runs batch by batch, as before. If it fails partway, `Transaction_Status = PartiallyApplied`, and the log warns that the completed batches remain applied.

**Code** (`Deploy-FeatureBasedSQL.ps1`):
- `Undo-SqlTransaction` (new, line 90) rolls back safely and returns the outcome.
- In `Invoke-SQLScript` (line 110):
  - checks for the opt-out marker (line 165)
  - begins the transaction (line 225), and every batch command joins it
  - rolls back after a failed batch (line 312), or after an unexpected error (line 348)
  - commits after the last successful batch (line 328)
- Feature-level rollback scripts run through the same function, so each of them is also all-or-nothing.

> **Note:** a script holds its locks until it commits. A long script can therefore block other sessions on that database for longer than before.

---

## 2. More detail in the deployment output

### 2.1 New columns in the results CSV (`executionsql-results-<BuildId>.csv`)

The new columns are added to every row by `Initialize-ResultFields` (`Deploy-FeatureBasedSQL.ps1`, line 51).

| Column | Meaning |
|---|---|
| `Script_Name` | File name of the script |
| `Actual_Server` | Server reported by the SQL connection, i.e. where the script really ran |
| `Actual_Database` | Database the script ran in |
| `Batches_Executed` | Number of batches that completed |
| `Total_Batches` | Number of batches in the script |
| `Failed_Batch` | Number of the batch that failed (empty on success) |
| `Transaction_Status` | `Committed`, `RolledBack`, `RollbackFailed`, `EndedByServer`, `PartiallyApplied`, `NotUsed`, `NotStarted` |
| `Start_Time` / `End_Time` | When the script started and finished |

Existing columns are unchanged: `Server_Name`, `Database_Name`, `Client_Name`, `Execution_Status`, `Duration`, `Rows_Affected`, `Error_Message`, `Executed_By`, and the rest.

### 2.2 Every planned script is now reported

**Before:** the results only held scripts that were attempted. Scripts that never ran because of an earlier failure simply disappeared from the report.

**After:**
- Every row of the execution plan appears once in the results.
- Rows start as `Pending`. Any row that never ran is marked **`Skipped`**, with the note *"Not executed: deployment stopped after an earlier failure (\<strategy\> strategy)"* (line 767).

### 2.3 Status values

| `Execution_Status` | Meaning |
|---|---|
| `Success` | Script ran and was committed |
| `Failed` | Script failed, or couldn't start (for example a missing connection string) |
| `Rollback Success` | Script succeeded, then was undone by a feature-level rollback |
| `Rollback Failed` | A feature-level rollback was attempted and failed (new) |
| `Skipped` | Never executed (new) |

### 2.4 Console output

- **Deploy step:**
  - A table of every script with its client, server, database, status, transaction outcome, batches (e.g. `2/3`) and duration (line 791).
  - New counts for **Rolled Back** and **Skipped** scripts.
  - Connection lines `Connected to SQL Server: …` and `Target database: …`.
  - A transaction-mode line for every script.
- **Publish step:** a per-server/database summary table, plus counts for rolled-back, rollback-failed and skipped scripts.

### 2.5 HTML report (new): `deployment-report-<BuildId>.html`

**Before:** the HTML function existed but was never called, so no HTML report was produced.

**After:** `New-HtmlReport` (`Publish-DeploymentResults.ps1`, line 286) runs and writes the report to the artifacts folder, which `ExecutionResults` publishes. It contains:

1. **Header:** environment, release version, build, requested by, report time, overall status.
2. **Summary counts:** total, succeeded, failed, rolled back, rollback failed, skipped, success rate, number of servers and databases, total duration.
3. **Server / Database summary:** one row per server and database, with clients and counts.
4. **Application summary.**
5. **Execution details:** every script, with application/feature, client, script name and path, server, database, a status badge, a transaction badge, batches (with the failed batch number), rows, duration, start time, and the error.
   - If the server or database the connection actually used differs from the plan, a red **"connected: …"** note appears under it.
6. **Failure analysis:** failure types, recommended actions, and a table of failed scripts showing the failed batch and the transaction outcome.

All values are HTML-encoded, so error text can't break or inject into the page. A sample made from test data is in `Sample-Report/deployment-report-999.html`, outside the repo folder.

### 2.6 New pipeline output variables

| Step | Variable | Status |
|---|---|---|
| Deploy | `RolledBackScripts`, `SkippedScripts` | New |
| Publish | `FailedScripts` | Now includes `Rollback Failed` rows |

### 2.7 Artifact file names

| Before | After |
|---|---|
| `deployment-anlaysis.json` (typo) | `deployment-analysis.json` |
| none | `deployment-report-<BuildId>.html` |

---

## 3. Deploy a client to all of its databases

**Before:**
- A client listed twice in the config (for example `Client002` for `application2` and `application6`) was merged into one execution-plan row, and `Client_Name` was written as `System.Object[]`.
- The deploy step never switched database. Rows sharing a connection string all ran against whichever database that connection string names. One database could get the script twice and the other none.

**After:**

| Area | Change |
|---|---|
| `Get-ClientConfiguration` (`Parse_FeatureChecklist.ps1`, line 35) | Returns **every** config entry for the client |
| `Expand-ExecutionPlanForClient` (line 53) | Creates one plan row per entry, per server, per database, with the correct client name |
| `Get-ExpandedRow` (line 94, new) | Builds a single plan row |
| Duplicate targets (lines 80, 283) | Within one checklist row, a script is planned **once per server/database**. If `Client001,WorkflowPrimaryServer` both point to `dev-server1/dev_Client1DB_001`, the second is skipped with a log message |
| Parse log | Lists the target databases for each client, e.g. `… for client 'Client002' to 2 database(s): dev-server1/dev_Client2DB_001, dev-server1/dev_Client2DB_003` |
| `Invoke-SQLScript` (`Deploy-FeatureBasedSQL.ps1`, line 195) | After connecting, **switches to the row's planned database** (`ChangeDatabase`). If the database doesn't exist or the login can't open it, that row fails with SQL Server's error |

Results with the current `dev-config.json`:

| Checklist `Client_Name` | Planned targets |
|---|---|
| `Client002` | `dev_Client2DB_001`, `dev_Client2DB_003` |
| `WorkflowSecondaryServer` | `dev-server2/dev_Client3DB_001`, `dev-server2/dev_Client4DB_001` |
| `Client001,WorkflowPrimaryServer` | `dev-server1/dev_Client1DB_001`, deployed once |

---

## 4. Bug fixes

| File | Bug | Fix |
|---|---|---|
| Deploy | **The SQL connection was never created** (`$connection = $null`, then `$connection.open()`), so every script failed | Creates a `SqlConnection` from the connection string, then opens it |
| Deploy | `:IsNullorwhitespace(...)` was parsed as a loop label, and the block referenced an undefined `$sqlException` | Block removed; the error message is always set from the exception |
| Deploy | SQL errors were written as `Failure` while other errors were written as `Failed`, so the publish step didn't count SQL errors | `Failed` is used throughout. The publish step also still accepts `Failure` |
| Deploy | Rows that failed before running (empty path, empty database name) were missing from the results | Results now come from every plan row |
| Publish | The HTML report was never generated, and its code had several errors | Rewritten and now called |
| Publish | Overall status could be `Success` even when scripts had failed | All status values are mapped to categories, and any failure gives `Failed` |
| Publish | Failure details selected a nonexistent `Script_Name` column, sorted by a nonexistent `Execution_Timestamp`, and printed `$summary` before it was set | Fixed |
| Publish | `Write-Warning -ForegroundColor` (an invalid parameter) on the CSV import error path | Removed |
| Publish | The "timeout" failure category was unreachable, and "time out" wasn't recognized | Categories reordered, and "time out" / "timed out" matched |
| Publish | Local runs (no `BUILD_BUILDID`) couldn't find the results file, which the deploy step names `…-local.csv` | Falls back to `local`, matching the deploy step |

---

## 5. Behaviour changes to be aware of

1. **Scripts with non-transactional statements** (`ALTER DATABASE`, `CREATE DATABASE`, `BACKUP`, …) now fail unless they contain `-- @NoTransaction`.
2. **Scripts are now executed in the planned database.** If a connection string names a different database than the config, the script now runs in the config's database, which is the intended behaviour. If that database doesn't exist or isn't accessible, the row fails instead of silently running elsewhere.
3. **A client with several config entries is now deployed to all of them.** The `applicationName` field in the config is still ignored, so every entry for the client is targeted.
4. **The results CSV is longer.** It contains every planned row, including `Skipped`, plus the new columns.
5. **Locks are held longer**, until the script commits (see Section 1).

---

## 6. Testing

Performed on Windows PowerShell 5.1.26100 with no SQL Server available:

| Test | Result |
|---|---|
| Parse check of all three changed scripts | No syntax errors in the new code. See item 1 in Section 7 for the existing encoding issue in the deploy script |
| Parse step with the real `dev-config.json` and a test checklist (`Client002`; `Client001,WorkflowPrimaryServer`; `WorkflowSecondaryServer`) | Planned 5 targets as listed in Section 3, including the duplicate skip |
| Deploy step against an unreachable server: one connection failure, one missing connection-string variable, one script not reached | Statuses `Failed`, `Failed`, `Skipped`; new columns present in the CSV; console table printed; exit code 1 |
| Publish step on synthetic results covering every status and transaction outcome, plus an error message containing `<script>` | Console, JSON and HTML produced; all rows and badges rendered; the "connected:" note and failed-batch number shown; error text HTML-encoded |

**Not tested (needs a real SQL Server):**
- commit and rollback of a real multi-batch script
- `ChangeDatabase` to each planned database
- feature-level rollback with real rollback scripts

**Suggested first dev test:**
1. Deploy a 3-batch script whose batch 2 fails.
2. Confirm nothing from batch 1 remains in the database, and that the log shows `Rollback complete.`
3. Deploy to `Client002` and confirm the log shows `Target database: dev_Client2DB_001` and `dev_Client2DB_003`.

---

## 7. Known open items (not part of these changes)

1. **The deploy script still doesn't parse in Windows PowerShell 5.1.** The `✓` and `✗` characters on lines 827 and 831 are misread, because the file is UTF-8 without a BOM. Replace them with `[+]` and `[-]`, or save the file as UTF-8 with BOM.
2. **Secret variables aren't passed to the script.** Connection strings stored as secrets in the Library aren't exposed as environment variables. See `docs/Passwordless-SQL-Authentication.md` for the long-term fix, or map each secret under `env:` in the YAML.
3. **`serverName` in the config is a label only.** The real server comes from the connection string. `WorkflowSecondaryServer` and `Client004` share `dev-client004-connstr` while listing different servers (same pattern in qa). A check that fails on a mismatch hasn't been added yet.
4. **The pipeline YAML hasn't changed.** The blockers listed in `PRODUCTION_READINESS_REVIEW.md` (missing `Validate-SQLScripts.ps1`, `ManualValidation` in an agent job, the execution-plan download path, the single dev variable group, and others) still apply.

---

## 8. Reverting

The original versions of the three scripts were backed up to the Claude Code session scratchpad (`…\scratchpad\Scripts-backup-original\`). That folder is **temporary**. The repository has no commits yet, so commit the current state to git to keep a permanent baseline.

## Related documents

- `PRODUCTION_READINESS_REVIEW.md`: full production-readiness review
- `docs/Passwordless-SQL-Authentication.md`: removing stored SQL passwords (gMSA / Entra ID)

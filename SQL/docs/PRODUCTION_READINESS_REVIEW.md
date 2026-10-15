# SQL Deployment Framework: Production Readiness Review

| | |
|---|---|
| **Scope** | Everything under `SQL/`: Azure DevOps pipeline, 4 PowerShell scripts, `dev`/`qa` environment configs and checklists, and the 20 SQL scripts for release `1.0.0` |
| **Review date** | 2026-10-10 |
| **Method** | Every file was reviewed by reading the source. Each PowerShell script was also checked with the PowerShell parser under **Windows PowerShell 5.1**, the runtime the pipeline uses (`pwsh: false`), and the source was scanned for credentials. Nothing was run against a database or in Azure DevOps. Findings marked **(Verified)** were reproduced locally. The rest come from reading the code. |
| **Overall verdict** | **Not production-ready.** The design is sound, but the code is at prototype stage. As written, the pipeline cannot complete a real deployment. |

---

## 1. Executive Summary

The framework's design is good. A CSV checklist drives the work, and a JSON config fans each script out across tenants and databases. Dry run is on by default. Operators can review the execution plan before they approve it, and there are three rollback strategies to choose from. These are the right building blocks for a multi-tenant SQL release process.

The implementation has not yet been run end-to-end. **At least ten independent blockers (Section 3) will each stop a real deployment.** Examples: the validation script it calls is missing, the approval task is in a job type that doesn't support it, the deploy script fails to parse on the configured PowerShell version, and the SQL connection object is never created.

Beyond the blockers, these enterprise gaps remain:

- **No deployment journal or idempotency.** Re-running a release runs every script again.
- **No transactions, and no real rollback.** Rollback scripts are placeholders, and the rollback order is inverted.
- **Approvals cannot be enforced.** There are no named approvers and no separation of duties, and anyone who can run the pipeline can deploy to `prod` from any branch.
- **Environments are not isolated.** Every environment uses the one dev variable group (`mssql-vg-dev`). Every environment also uses the same agent pool. Some tenants share connection strings.
- **Secrets cannot reach the script** if they are stored as secret variables, which is the correct way to store them.
- **No tests, linting, PR validation or documentation**, and **no `prod` configuration**.

### Finding counts

| Severity | Count | Meaning |
|---|---|---|
| **Critical** | 14 | Blocks deployment, or risks data loss or an uncontrolled change to production |
| **High** | 17 | Wrong behaviour, a security exposure, or a missing control expected in production |
| **Medium** | 18 | Reliability, governance or maintainability risk |
| **Low** | 13 | Hygiene and polish |
| **Hard-coded values** | 20 | Listed separately in Section 7 |

### Readiness scorecard

| Area | Rating | Summary |
|---|---|---|
| Architecture and design concept | Amber | Checklist plus config fan-out, dry run, plan-then-approve and rollback strategies are good ideas |
| Functional correctness | **Red** | Cannot complete a deployment. Defects in which database is targeted and how results are reported |
| Security and secrets | **Red** | Secret delivery broken. No TLS enforcement. Arbitrary file paths are accepted. No guardrails on SQL content |
| RBAC and approvals | **Red** | Approval step cannot run. No approver group. Any branch can deploy to prod |
| Rollback and recovery | **Red** | Placeholder rollbacks, inverted order, no transactions, no backup or snapshot |
| Idempotency and state tracking | **Red** | No journal of applied scripts in the target DB |
| Auditability | Amber | Detailed console logs, but records the agent's account instead of the person, and no commit SHA |
| Configuration management | Amber | Config lives outside the code, but there is no schema, entries are duplicated, and dev and qa disagree |
| Code quality and testing | **Red** | Parse failure on the target runtime. No Pester, PSScriptAnalyzer or SQL lint |
| Observability | Amber | Good per-batch logs and artifacts. Nothing central, no alerts |
| Documentation | **Red** | No README, runbook or script-author guide |
| SQL content (release 1.0.0) | **Red** | Empty files, placeholders and syntax errors |

### Top 10 actions

1. Fix the blockers in Section 3 so that one dev deployment completes end-to-end.
2. Move approvals into **Azure DevOps Environment checks**: an approver group, no self-approval, branch control and an exclusive lock. Remove reliance on an in-YAML `ManualValidation` step.
3. Give each environment its own **Key Vault–backed variable group** and **agent pool**. Better still, use identity-based SQL auth (gMSA or Entra ID) so no passwords are needed.
4. Add a **deployment journal table** to each target database (script path, SHA-256, applied-by, run ID) and skip scripts that are already applied.
5. Run each script inside a **transaction** (`SET XACT_ABORT ON`), and **enforce the target database** with `ChangeDatabase`.
6. Make rollback real: require tested rollback scripts, fix the ordering, and take a snapshot or backup before production changes.
7. Restrict `SQL_Path`, `Rollback_Script_Path` and `Validation_Query` to the release folder, which closes the arbitrary-file-execution hole.
8. Add a **PR validation pipeline**: PSScriptAnalyzer, Pester tests, CSV/JSON schema checks, SQL lint, and an integration test against a SQL Server container.
9. Use one list of status values across all scripts, and record **the person who requested the run, the approver, and the commit SHA** in results.
10. Add `prod` config, a README and runbook, and a SQL script-authoring standard.

---

## 2. What Is Done Well

- **No credentials in source.** Connection strings are referenced by variable name (`connectionStringVar`). A scan for passwords, tokens and keys found nothing except one placeholder email address.
- **`dryRun` defaults to `true`** ([azure-pipelines.yml:37-40](Pipelines/azure-pipelines.yml#L37-L40)). This is a safe default.
- **The execution plan is published as an artifact before approval.** Approvers can see exactly which client, server and database will receive each script.
- **The deployment job uses an Azure DevOps Environment** ([azure-pipelines.yml:169](Pipelines/azure-pipelines.yml#L169)). Proper approvals and checks can be attached to it.
- **A guard against connection strings with no database** ([Deploy-FeatureBasedSQL.ps1:95](Scripts/Deploy-FeatureBasedSQL.ps1#L95)).
- **Detailed per-batch logging**, with timings, SQL error number, state and class, plus `##vso` output variables.
- **Selectable rollback strategies**, and filters by application and by feature.
- **Folder conventions with numeric prefixes.** The generator rejects missing or duplicate prefixes ([Generate-EnvironmentCSV.ps1:156-178](Scripts/Generate-EnvironmentCSV.ps1#L156-L178)).

---

## 3. Deployment Blockers (Critical)

Any one of these stops a real (non-dry-run) deployment.

| ID | Location | Problem | Fix |
|---|---|---|---|
| **BLK-01** | [azure-pipelines.yml:130-134](Pipelines/azure-pipelines.yml#L130-L134) | `scripts/Validate-SQLScripts.ps1` **does not exist** (Verified). When `dryRun=false`, the `ValidateScripts` stage fails, so `ExecuteScripts` never runs. The arguments are also malformed: `- ArtifactsDirectory` has a space after the hyphen, so PowerShell treats the values as positional arguments. | Add the validation script (lint, banned statements, file existence, idempotency header) or remove the stage. Fix the argument syntax to `-ArtifactsDirectory "..."`. |
| **BLK-02** | [azure-pipelines.yml:151-164](Pipelines/azure-pipelines.yml#L151-L164) | `ManualValidation@1` is inside an **agent job**. The task only runs in **agentless jobs** (`pool: server`), so the job fails. | Use Environment approvals (see RBAC-01). If an in-pipeline plan review is still wanted, put it in a `pool: server` job. |
| **BLK-03** | [Deploy-FeatureBasedSQL.ps1:668](Scripts/Deploy-FeatureBasedSQL.ps1#L668), [:672](Scripts/Deploy-FeatureBasedSQL.ps1#L672) | **The deploy script does not parse under Windows PowerShell 5.1** (Verified). The file is UTF-8 without a BOM and contains `✓` and `✗`. PS 5.1 reads it as Windows-1252. Byte `0x93` becomes a curly quote, which PowerShell treats as a string delimiter. The parser then reports *"Missing closing '}'"* at line 588 and *"Try statement is missing its Catch or Finally block"* at line 680. | Use only ASCII characters, **or** save the file as UTF-8 with BOM, **or** switch to PowerShell 7 (`pwsh: true`). Add PSScriptAnalyzer and a parse check to PR validation. |
| **BLK-03b** | [Generate-EnvironmentCSV.ps1:255-258](Scripts/Generate-EnvironmentCSV.ps1#L255-L258) | Same encoding defect (2,832 non-ASCII bytes, no BOM). Here it is worse: the script **parses without errors but tokenizes incorrectly** (Verified). The `–` on line 255 ends the string early, and the `else` block on line 257 becomes part of a string literal. In PS 5.1 the generator's logic is silently corrupted. | Same fix as BLK-03. |
| **BLK-04** | [Deploy-FeatureBasedSQL.ps1:77](Scripts/Deploy-FeatureBasedSQL.ps1#L77), [:115](Scripts/Deploy-FeatureBasedSQL.ps1#L115) | **The SQL connection is never created.** `$connection = $null` is followed by `$connection.open()`. No `New-Object SqlConnection` exists in `Invoke-SQLScript`. Calling a method on null is not a `SqlException`, so the outer `catch` at line 227 handles it, and **every script reports as failed**. | `$connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)` before `Open()`. Section 11.B shows the full pattern. |
| **BLK-05** | [azure-pipelines.yml:180-184](Pipelines/azure-pipelines.yml#L180-L184) vs [:195](Pipelines/azure-pipelines.yml#L195) | The execution plan is downloaded to `$(System.DefaultWorkingDirectory)`, but the script is given `$(ArtifactsDirectory)`, which is `$(System.ArtifactsDirectory)`. The deploy script exits with *"Execution plan not found"* ([Deploy:540-546](Scripts/Deploy-FeatureBasedSQL.ps1#L540-L546)). | Use one path. Deployment jobs automatically download current-run artifacts to `$(Pipeline.Workspace)/ExecutionPlan`, so pass that path. |
| **BLK-06** | [Deploy:334](Scripts/Deploy-FeatureBasedSQL.ps1#L334), [:471](Scripts/Deploy-FeatureBasedSQL.ps1#L471); task at [yml:186-203](Pipelines/azure-pipelines.yml#L186-L203) | The script reads connection strings from `Env:<connectionStringVar>`. **Azure DevOps does not expose secret variables as environment variables**; each one must be mapped under `env:`, and the task has no `env:` block. If the values are secret, every script fails with *"Connection string variable not set"*. If they aren't secret, credentials are in plain text for anyone with Library or pipeline access. | Map secrets explicitly, or better, use identity-based auth with no secrets (SEC-01). |
| **BLK-07** | [azure-pipelines.yml:173](Pipelines/azure-pipelines.yml#L173) | Variable group `mssql-vg-dev` is **hard-coded for every environment**. QA and prod runs load dev variables, and the `qa-*`/`prod-*` connection variables don't exist there. If someone "fixes" this by adding prod secrets to the dev group, every dev run gains prod credentials. | `- group: mssql-vg-${{ parameters.environment }}`, one Key Vault–backed group per environment. |
| **BLK-08** | [azure-pipelines.yml:13-16](Pipelines/azure-pipelines.yml#L13-L16), [:51-57](Pipelines/azure-pipelines.yml#L51-L57) | `prod` is a selectable environment, but **`Environments/prod/` does not exist** (Verified), so parsing fails. The agent pool name is the placeholder `Your-Self-Hosted-Windows-Pool`. | Add the prod config and checklist (with access restricted). Configure real agent pools, one per environment. |
| **BLK-09** | [qa.csv:8-11](Environments/qa/qa.csv#L8-L11), [dev.csv:1](Environments/dev/dev.csv#L1) | The checklists don't match the repo. `qa.csv` references `004_vendors/Internal/Deployment/Primary/001_vendors.sql` and similar paths, which **don't exist**. The real layout is `01_Selection/Primary/001_tableinsert.sql`, and so on. Every QA row has `Execute_Script=No`, so parsing exits with *"No scripts found"*. `dev.csv` has no `Branch_Name` column. | Regenerate the checklists. Add a PR check that every `SQL_Path` and `Rollback_Script_Path` exists and that headers match a schema. |
| **BLK-10** | [003_sample.sql:3](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/003_sample.sql#L3), [:14-15](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/003_sample.sql#L14-L15) and 7 empty files | The release content can't be deployed. `sys.columns` has no `COLUMN_NAME` column (it should be `name`), which raises *Invalid column name* at runtime. A duplicated `FOREIGN KEY` line is a syntax error. Seven SQL files are empty, and an empty file makes the script throw *"SQL script file is empty"* ([Deploy:90-92](Scripts/Deploy-FeatureBasedSQL.ps1#L90-L92)). See Section 9. | Fix or remove the scripts. Add an SQL lint/build step to PR validation. |

---

## 4. Functional Correctness Defects

| ID | Sev | Location | Issue and impact | Recommendation |
|---|---|---|---|---|
| **COR-01** | High | [Deploy:110](Scripts/Deploy-FeatureBasedSQL.ps1#L110); [dev-config.json:23-25](Environments/dev/dev-config.json#L23-L25), [:79-81](Environments/dev/dev-config.json#L79-L81) | **The target database is not enforced.** `Invoke-SQLScript` only *prints* `DatabaseName` and never runs `USE` or `ChangeDatabase`. Scripts run against whatever database the connection string names. `dev-client002-connstr` is mapped to both `dev_Client2DB_001` and `dev_Client2DB_003`, so one database gets the script twice and the other gets nothing, yet the report shows both as successful. `Test-ValidationQuery` *does* prepend `USE` ([:275-277](Scripts/Deploy-FeatureBasedSQL.ps1#L275-L277)), so the two code paths behave differently. | After `Open()`, call `$connection.ChangeDatabase($DatabaseName)`, then assert `SELECT DB_NAME()`. |
| **COR-02** | High | [dev-config.json:50-51](Environments/dev/dev-config.json#L50-L51) vs [:98-101](Environments/dev/dev-config.json#L98-L101); same in [qa-config.json](Environments/qa/qa-config.json#L98-L101) | **`serverName` is informational only and can be wrong.** `WorkflowSecondaryServer` says `dev-server2` while using `dev-client004-connstr`, but `Client004` lists `dev-server1` for the same variable. Reports and audit records will name a server that was never touched. | Read the server from the connection string (`SqlConnectionStringBuilder.DataSource`) and fail if it doesn't match the config. |
| **COR-03** | High | [Parse:42](Scripts/Parse_FeatureChecklist.ps1#L42), [:83](Scripts/Parse_FeatureChecklist.ps1#L83); [dev-config.json:16-29](Environments/dev/dev-config.json#L16-L29), [:72-85](Environments/dev/dev-config.json#L72-L85) | **Duplicate client entries break targeting.** `Client002` appears twice, with different `applicationName` values. `Where-Object` returns both, so `Client_Name` becomes an array (written to CSV as `System.Object[]`) and the script fans out to *both* applications' databases. The `applicationName` and `environment` fields are never read; the `$Environment` parameter ([:39](Scripts/Parse_FeatureChecklist.ps1#L39)) is unused. | Use a unique key (`clientName` + `applicationName`), filter by `Application_Name`, and validate the config against a JSON Schema. |
| **COR-04** | High | [Parse:74-99](Scripts/Parse_FeatureChecklist.ps1#L74-L99); [Deploy:424-440](Scripts/Deploy-FeatureBasedSQL.ps1#L424-L440) | **Post-deployment validation never runs.** `Expand-ExecutionPlanForClient` doesn't copy `Validation_Query`, `Expected_Result` or `Actual_Result`, so the deploy step always sees an empty validation query. If those fields *were* copied, assigning `$Script.Actual_Result` would throw, because the CSV-derived object has no such property. | Carry all checklist columns through, and add an end-to-end test for a validation query. |
| **COR-05** | High | [Deploy:413](Scripts/Deploy-FeatureBasedSQL.ps1#L413) vs [:387](Scripts/Deploy-FeatureBasedSQL.ps1#L387), [:437](Scripts/Deploy-FeatureBasedSQL.ps1#L437); [Publish:30](Scripts/Publish-DeploymentResults.ps1#L30), [:61](Scripts/Publish-DeploymentResults.ps1#L61), [:391](Scripts/Publish-DeploymentResults.ps1#L391) | **Failures can be reported as success.** The deploy script writes `"Failure"` for SQL errors and `"Failed"` for other errors. The publish script counts only `"Failed"`, so SQL errors are missed and the overall status is `"Success"`. `"Rollback Success"` ([Deploy:349](Scripts/Deploy-FeatureBasedSQL.ps1#L349)) isn't counted anywhere. | Define the status values once in a shared module (`Pending`, `Success`, `Failed`, `Skipped`, `RolledBack`, `RollbackFailed`) and use them everywhere. |
| **COR-06** | High | [Generate:351-352](Scripts/Generate-EnvironmentCSV.ps1#L351-L352), [:381-382](Scripts/Generate-EnvironmentCSV.ps1#L381-L382); [Deploy:318-322](Scripts/Deploy-FeatureBasedSQL.ps1#L318-L322); [qa.csv:2-3](Environments/qa/qa.csv#L2-L3) | **Rollback runs in the wrong order.** The generator gives `Feature_Rollback_Order = 1` to the *highest*-numbered script (in qa.csv, 001 gets 2 and 002 gets 1). The deploy script sorts **descending**, so 001's rollback runs before 002's: the earliest change is undone first. With real DDL that has foreign-key dependencies, this fails. | Choose one convention. Simplest: roll back the scripts that actually succeeded, in reverse order of execution. |
| **COR-07** | High | [Deploy:146-213](Scripts/Deploy-FeatureBasedSQL.ps1#L146-L213), [:319-322](Scripts/Deploy-FeatureBasedSQL.ps1#L319-L322) | **No transaction, so scripts can be partly applied.** Each batch commits on its own. If batch 3 of 5 fails, batches 1–2 stay committed. Rollback only targets scripts marked `Success`, so the partly applied script is **never** rolled back. | Wrap each script in a transaction (Section 11.B) with `SET XACT_ABORT ON`. Mark the few statements that can't run in a transaction (for example `ALTER DATABASE`, full-text operations) as `-- transactional: false` in the script header. |
| **COR-08** | Medium | [Parse:120-127](Scripts/Parse_FeatureChecklist.ps1#L120-L127); [dev.csv:2-3](Environments/dev/dev.csv#L2-L3) | **Prerequisites are checked only loosely and never at runtime.** The check uses a substring wildcard (`-like "*$prereq*"`). It ignores which database each script targets: `002_allclients` targets the Workflow servers, but its prerequisite `001_students` only targets `Client001`, and the check still passes. It also ignores order, and nothing checks at runtime that the prerequisite actually succeeded. | Check prerequisites per target database and require them to come earlier in order. At runtime, skip any script whose prerequisite failed on that database. |
| **COR-09** | Medium | [Generate:294-299](Scripts/Generate-EnvironmentCSV.ps1#L294-L299), [:328-330](Scripts/Generate-EnvironmentCSV.ps1#L328-L330) | **Numbered sub-folders don't control execution order.** Only *immediate* sub-folders are considered, and for `004_vendors` that is just `Internal`. Scripts are grouped Primary, then Secondary, then everything else, so the order becomes `01_Selection/Primary`, `02_History/Primary`, `05_WF_common/Primary`, then the Secondary scripts, and **`03_WF` and `04_Config` run last**. | Order by the full relative path, using the numeric prefixes at every level. Confirm with script authors what the intended order is. |
| **COR-10** | Medium | [Generate:375-377](Scripts/Generate-EnvironmentCSV.ps1#L375-L377) | **Rollback scripts are matched to deployment scripts by numeric prefix, and the prefixes collide.** In `004_vendors` every deployment file is named `001_tableinsert.sql`, so **all** of them map to `001_vendors_rollback.sql`. The pattern `^001` also matches `0010_*`. | Mirror the deployment folder tree under `Rollback/`, using the same file names, or declare the rollback file in each script's header. |
| **COR-11** | Medium | [Deploy:473-481](Scripts/Deploy-FeatureBasedSQL.ps1#L473-L481), [:497-499](Scripts/Deploy-FeatureBasedSQL.ps1#L497-L499) | **Rollback strategies don't do what their names and logs say.** *Progressive* logs "continuing with next script", then `return`s and skips the rest of the feature. A missing connection string just `continue`s, which ignores the strategy and lets dependent scripts run. A feature spans every tenant, so one tenant's failure stops that feature for all tenants. | Document each strategy precisely and test each one. Consider isolating tenants so one tenant's failure doesn't block the others. |
| **COR-12** | Medium | [yml:159](Pipelines/azure-pipelines.yml#L159), [:168](Pipelines/azure-pipelines.yml#L168), [:188](Pipelines/azure-pipelines.yml#L188) | **The approval can be skipped by its own condition.** The condition is on the *step*. If it evaluates to false (for example `validationStatus` isn't `Success`), the step is skipped, the job succeeds, and `DeployToDatabase` runs. The deploy step's condition checks only `executionPlanRows`. | Gate at stage level (`condition: eq(dependencies.ValidateScripts.outputs[...], 'Success')`), and enforce approvals through Environment checks. |
| **COR-13** | Medium | [yml:234](Pipelines/azure-pipelines.yml#L234) | **The "fail pipeline" step reads the wrong variable.** `$(deploymentSuccess)` is never set. The deploy step publishes it as an output variable, which is read as `$(deployStep.DeploymentSuccess)`. The check can never fire. Today the deploy script's `exit 1` hides this. | Use `$(deployStep.DeploymentSuccess)` and compare it without depending on letter case. |
| **COR-14** | Low | [Publish-DeploymentResults.ps1](Scripts/Publish-DeploymentResults.ps1) | Many defects in the publish script: **`Create-HTMLReport` ([:169-335](Scripts/Publish-DeploymentResults.ps1#L169-L335)) is never called**, so only JSON is produced. Line 200 `{Success}` would throw. Line 165 selects a nonexistent `Script_Name` and leaves out the `SQL_Path` that line 317 needs. Lines 88-89 sort by a nonexistent `Execution_Timestamp`. Line 341 uses `$summary` before it is set. Lines 356-364 are unreachable. Line 379 passes `-ForegroundColor` to `Write-Warning`, which doesn't accept it. Line 429 reads `.Type.Key`. The `timeout` branch at line 146 is unreachable because line 128 already matches it. Line 401 writes `anlaysis` while line 403 says `analysis`. A function is defined inside a loop (line 117). | Rewrite the script with Pester tests. Call the HTML report and publish it to the run summary (`##vso[task.uploadsummary]`). |
| **COR-15** | Low | [Deploy:187-189](Scripts/Deploy-FeatureBasedSQL.ps1#L187-L189) | `:IsNullorwhitespace(...)` is parsed as a **loop label**, not `[string]::IsNullOrWhiteSpace` (Verified with the tokenizer). It also references `$sqlException`, which is never defined in that scope. | `if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $_.Exception.Message }` |
| **COR-16** | Low | [Deploy:103](Scripts/Deploy-FeatureBasedSQL.ps1#L103) | The `GO` splitter doesn't handle `GO <n>`, or `GO` inside block comments or strings. | Use `ScriptDom` (`TSql160Parser`) or a library such as DbUp to split batches. |
| **COR-17** | Low | [Generate:211-217](Scripts/Generate-EnvironmentCSV.ps1#L211-L217), [:409-410](Scripts/Generate-EnvironmentCSV.ps1#L409-L410), [:141-142](Scripts/Generate-EnvironmentCSV.ps1#L141-L142) | The generator **deletes rows for other releases**, so history is lost. Every script defaults to `DDL` with `Execute_Script=No`. `Client_Name` is left blank, so every row needs manual editing, which is error-prone. | Keep one checklist per release version. Derive the script type and target clients from folder metadata (for example, `Primary` maps to `WorkflowPrimaryServer`). |
| **COR-18** | Low | [Generate:33-35](Scripts/Generate-EnvironmentCSV.ps1#L33-L35) | The comment says paths are "relative to the script's own location", but the code uses `Get-Location`. Running the script from any other folder breaks it. | Use `$PSScriptRoot`, or take a `-RepoRoot` parameter. |
| **COR-19** | Low | [yml:1-7](Pipelines/azure-pipelines.yml#L1-L7) | `trigger: main` combined with a `releaseVersion` that has no default value: CI-triggered runs fail when the pipeline is compiled. Auto-triggering a database deployment pipeline is also not wanted. | `trigger: none`, plus a separate PR validation pipeline. |

---

## 5. Security Findings

| ID | Sev | Location | Issue and impact | Recommendation |
|---|---|---|---|---|
| **SEC-01** | High | [Deploy:334](Scripts/Deploy-FeatureBasedSQL.ps1#L334), [:471](Scripts/Deploy-FeatureBasedSQL.ps1#L471); [yml:173](Pipelines/azure-pipelines.yml#L173) | **The secret-handling model is broken and relies on passwords.** See BLK-06 and BLK-07. Connection strings with SQL logins are long-lived secrets, and some are shared across tenants. | **Preferred: no secrets.** For on-prem SQL, run the self-hosted agent under a **gMSA** and use `Integrated Security=SSPI`. For Azure SQL, use an **Entra ID service connection with workload identity federation** and set `SqlConnection.AccessToken`. **If secrets must remain:** one Key Vault per environment linked to an environment-specific variable group, explicit `env:` mapping, and scheduled rotation. |
| **SEC-02** | High | [Deploy:84](Scripts/Deploy-FeatureBasedSQL.ps1#L84), [:270-272](Scripts/Deploy-FeatureBasedSQL.ps1#L270-L272), [:329](Scripts/Deploy-FeatureBasedSQL.ps1#L329) | **Any file on the agent can be executed.** `SQL_Path`, `Rollback_Script_Path` and `Validation_Query` come from the CSV unchecked. Absolute paths and `..\..\` paths are accepted, so any `.sql` file readable on the self-hosted agent can be run against production. `Validation_Query` can also contain arbitrary inline SQL. | Resolve each full path and require it to sit under `workflow.sql/<ReleaseVersion>/` (Section 11.D). Allow `Validation_Query` only as a repo file, and run it with a **read-only** login. |
| **SEC-03** | High | (missing validation stage) | **Nothing checks SQL content for dangerous statements.** Nothing blocks `DROP DATABASE`/`DROP TABLE`, `TRUNCATE`, `DELETE` or `UPDATE` with no `WHERE`, `GRANT … TO public`, `xp_cmdshell`, `sp_configure`, `ALTER LOGIN`, `EXECUTE AS`, or `USE <otherdb>` before they reach production. | At PR time: SQLFluff (T-SQL dialect) or TSQLLint, SSDT/`ScriptDom` parsing, and a block-list of destructive statements that needs an explicit override label plus DBA approval. |
| **SEC-04** | Medium | [Deploy:29](Scripts/Deploy-FeatureBasedSQL.ps1#L29), [:95](Scripts/Deploy-FeatureBasedSQL.ps1#L95) | **TLS is not enforced, and the SQL client library is deprecated.** The only check on the connection string is that it contains "database". `System.Data.SqlClient` is in maintenance mode only. | Reject connection strings without `Encrypt=True;TrustServerCertificate=False`. Move to `Microsoft.Data.SqlClient`, or the `SqlServer` module 22+, which defaults to `Encrypt=Mandatory`. |
| **SEC-05** | Medium | [dev-config.json:65](Environments/dev/dev-config.json#L65), [:93](Environments/dev/dev-config.json#L93), [:100](Environments/dev/dev-config.json#L100) | **Tenants share credentials.** `WorkflowPrimaryServer` reuses Client001's connection string, and `WorkflowSecondaryServer` reuses Client003's and Client004's. If one is misused or compromised, multiple tenants are affected, and the audit trail can't tell them apart. | Use one identity per tenant database, or per server with least privilege. Never reuse a tenant's identity for a shared or workflow target. |
| **SEC-06** | Medium | [yml:51-57](Pipelines/azure-pipelines.yml#L51-L57) | **One self-hosted agent pool serves dev, qa and prod.** Dev runs, and any other pipeline authorized on the pool, land on agents with network access to production SQL. Leftover files in `_work` can carry over between runs. | Give prod its own agent pool, limit pipeline permissions on it, set `workspace: clean: all`, use ephemeral agents (VMSS) if possible, and firewall SQL so only the prod agent subnet can reach it. |
| **SEC-07** | Medium | (results export) [Deploy:641-646](Scripts/Deploy-FeatureBasedSQL.ps1#L641-L646) | **Nothing proves which scripts ran.** Results record neither a script hash nor the commit SHA, so there is no evidence that the code that ran is the code that was reviewed and approved. | Record a SHA-256 for every script plus `$(Build.SourceVersion)` in the execution plan, the results and the journal. Show the hashes to approvers. |
| **SEC-08** | Low | [Publish:325](Scripts/Publish-DeploymentResults.ps1#L325) | The HTML report would embed raw SQL error messages without encoding them, which allows HTML injection if the report is ever generated and hosted. | `[System.Net.WebUtility]::HtmlEncode()` every value inserted into the HTML. |
| **SEC-09** | Low | Configs and published artifacts | Server and database names are in the repo and in pipeline artifacts. They aren't secrets, but they map out internal infrastructure. | Restrict who can read prod artifacts and how long they are kept. Consider keeping the prod config in a restricted repo or in Azure App Configuration. |
| **SEC-10** | Low | Repo root | No `.gitignore` (local artifacts and result CSVs could be committed). No secret scanning. The Git repo has **no commits and no remote** (Verified), so no branch policies apply yet. | Add a `.gitignore`. Enable GitHub Advanced Security for Azure DevOps (secret and dependency scanning). Push to a protected remote. |

---

## 6. RBAC and Governance Findings

| ID | Sev | Location | Issue and impact | Recommendation |
|---|---|---|---|---|
| **RBAC-01** | **Critical** | [yml:151-164](Pipelines/azure-pipelines.yml#L151-L164) | **Approvals can't be enforced, and the person who queues a run can approve it.** The approval task can't run (BLK-02). Even once it runs: there is no `approvers` input, so approval isn't limited to a named group; `notifyUsers` is a placeholder (`me@myemail.com`); `allowApproversToApproveTheirOwnRuns` isn't set to `false`; and no timeout behaviour is defined. Because the approval lives in YAML, anyone who can edit the pipeline on a branch can delete it. | Put approvals on the **Azure DevOps Environment** (a protected resource that branch edits can't remove). For **prod**: an Entra ID approver group, at least 2 approvers, *"approvers can't approve their own runs"*, a 24-hour timeout, and *Exclusive lock*, *Branch control* and *Business hours* checks. For **qa**: 1 approver plus branch control. |
| **RBAC-02** | High | [yml:4-40](Pipelines/azure-pipelines.yml#L4-L40); [Parse](Scripts/Parse_FeatureChecklist.ps1) | **Anyone who can run the pipeline can deploy to prod from any branch.** Runtime parameters let the caller choose `environment=prod`, `dryRun=false` and any rollback strategy. The `Branch_Name` column is never checked. | Add an Environment *Branch control* check (prod: `refs/heads/main` and `refs/heads/release/*` only). In the parse script, check that `$(Build.SourceBranch)` matches `release/<ReleaseVersion>`. Limit *Queue builds* permission on this pipeline to a release-manager group. |
| **RBAC-03** | High | [yml:173](Pipelines/azure-pipelines.yml#L173) | **Secret access isn't separated by environment** (BLK-07). | One variable group per environment, each linked to its own Key Vault. In the group's *Pipeline permissions*, allow only this pipeline. Its *Security* administrators should be release admins only. In Key Vault RBAC, grant *Key Vault Secrets User* only to that environment's service connection. |
| **RBAC-04** | High | Not defined anywhere | **The deployment identity's database rights are undefined.** Nothing documents or limits what the login behind each connection string can do, so a script can do anything that login can. | Use a separate deployer principal per environment, with `db_ddladmin` plus the specific data rights it needs, or a custom `deployer` role. **No `sysadmin`, `db_owner` or `securityadmin`.** Use a separate read-only principal for validation queries. Document this in a permissions matrix. |
| **RBAC-05** | Medium | `workflow.sql/` | **Database permissions aren't managed in code.** No scripts create or grant roles, users or schema permissions. Application permissions are set by hand and drift between tenants and environments. | Add scripts for roles and grants per feature, have DBAs review them, and check for drift by comparing `sys.database_permissions` with the expected state. |
| **RBAC-06** | Medium | [Deploy:418](Scripts/Deploy-FeatureBasedSQL.ps1#L418); [Parse:98](Scripts/Parse_FeatureChecklist.ps1#L98) | **The audit trail names the agent's service account, not the person.** `Executed_By = [Environment]::UserName` records the agent's account. No approver is recorded. `Pipeline_Run_ID` is never filled in: the parse script writes `Pipeline_RunId` while the CSV header is `Pipeline_Run_ID`. | Record `Build.RequestedFor`, `Build.RequestedForEmail`, the approver (from the Environment approval REST API), `Build.BuildId` and `Build.SourceVersion`. Use UTC ISO-8601 timestamps. |
| **RBAC-07** | Medium | Repo | **No code ownership or branch protection.** No reviewers are required for `workflow.sql/**`, `Environments/prod/**`, `Pipelines/**` or `Scripts/**`. | Azure DevOps branch policies: required reviewers by path (DBA group for SQL, platform group for the pipeline and scripts), at least 2 reviewers, no self-approval, build validation, and protected `main` and `release/*` branches. |
| **RBAC-08** | Low | Pipeline | The pipeline YAML can be changed on a branch to remove the checks and then run. | Add a *Required template* check on the prod Environment so only pipelines that extend an approved template can deploy there. |

---

## 7. Hard-Coded Values

| # | Value | Location | Issue | Recommendation |
|---|---|---|---|---|
| 1 | `me@myemail.com` | [yml:161](Pipelines/azure-pipelines.yml#L161) | Placeholder, so approval notifications go nowhere | An Entra ID group, ideally on the Environment approval |
| 2 | `Your-Self-Hosted-Windows-Pool` (×3) | [yml:53](Pipelines/azure-pipelines.yml#L53), [:55](Pipelines/azure-pipelines.yml#L55), [:57](Pipelines/azure-pipelines.yml#L57) | Placeholder, and the same pool for every environment | A per-environment variable template (`vars/<env>.yml`) |
| 3 | `mssql-vg-dev` | [yml:173](Pipelines/azure-pipelines.yml#L173) | Dev variable group used for every environment | `mssql-vg-${{ parameters.environment }}` |
| 4 | `trigger: main` | [yml:1-2](Pipelines/azure-pipelines.yml#L1-L2) | CI trigger on a database deployment pipeline | `trigger: none` |
| 5 | Environment list `dev`/`qa`/`prod` | [yml:13-16](Pipelines/azure-pipelines.yml#L13-L16) | `prod` is offered but not configured | Drive it from per-environment variable templates |
| 6 | `pwsh: false` (×4) | [yml:86](Pipelines/azure-pipelines.yml#L86), [:135](Pipelines/azure-pipelines.yml#L135), [:201](Pipelines/azure-pipelines.yml#L201), [:217](Pipelines/azure-pipelines.yml#L217) | Ties the pipeline to PS 5.1, which causes the encoding failure (BLK-03), and to Windows only | PowerShell 7 (`pwsh: true`) |
| 7 | Command timeout `0` (infinite) | [Deploy:63](Scripts/Deploy-FeatureBasedSQL.ps1#L63), [:345](Scripts/Deploy-FeatureBasedSQL.ps1#L345), [:410](Scripts/Deploy-FeatureBasedSQL.ps1#L410) | A hung script holds locks in production indefinitely | Configurable per environment and per script (e.g. 600 s default), plus a job `timeoutInMinutes` |
| 8 | Validation timeout `60` | [Deploy:281](Scripts/Deploy-FeatureBasedSQL.ps1#L281) | Can't be configured | Config |
| 9 | Status strings `Success`/`Failure`/`Failed`/`Rollback Success` | [Deploy:349](Scripts/Deploy-FeatureBasedSQL.ps1#L349), [:387](Scripts/Deploy-FeatureBasedSQL.ps1#L387), [:413](Scripts/Deploy-FeatureBasedSQL.ps1#L413); [Publish:29-32](Scripts/Publish-DeploymentResults.ps1#L29-L32) | Inconsistent repeated literals, which cause COR-05 | Shared constants in a `.psm1` module |
| 10 | Artifact file names (`execution_plan.csv`, `executionsql-results-<id>.csv`, `summary_report.json`, `deployment-anlaysis.json`, `skipped_rows.csv`) | [Parse:335](Scripts/Parse_FeatureChecklist.ps1#L335), [:344](Scripts/Parse_FeatureChecklist.ps1#L344), [:376](Scripts/Parse_FeatureChecklist.ps1#L376); [Deploy:540](Scripts/Deploy-FeatureBasedSQL.ps1#L540), [:643](Scripts/Deploy-FeatureBasedSQL.ps1#L643); [Publish:354](Scripts/Publish-DeploymentResults.ps1#L354), [:401](Scripts/Publish-DeploymentResults.ps1#L401) | The same names are repeated in each script, and one contains a typo | Define them once in the shared module |
| 11 | Build ID fallback `"local"` | [Deploy:642](Scripts/Deploy-FeatureBasedSQL.ps1#L642) | The publish script expects `BUILD_BUILDID`, so local runs don't match | Pass it as a parameter |
| 12 | Branch convention `release/<ver>` | [Generate:107](Scripts/Generate-EnvironmentCSV.ps1#L107) | Written to the CSV but never enforced | Read it from config and enforce it in the parse step (RBAC-02) |
| 13 | `Script_Type = "DDL"`, `Execute_Script = "No"`, `Environment.ToUpper()` | [Generate:409-411](Scripts/Generate-EnvironmentCSV.ps1#L409-L411) | Wrong for DML and SELECT scripts, and casing is inconsistent (dev.csv uses `dev`, qa.csv uses `QA`) | Derive from script header metadata, and normalize casing |
| 14 | Folder keywords `Rollback`, `Primary`, `Secondary`; order `Primary=1, Secondary=2` | [Generate:276-283](Scripts/Generate-EnvironmentCSV.ps1#L276-L283), [:303](Scripts/Generate-EnvironmentCSV.ps1#L303), [:318](Scripts/Generate-EnvironmentCSV.ps1#L318) | Conventions built into regexes and undocumented | Put them in config and document them |
| 15 | Server names `dev-server1/2`, `qa-server1/2` | [dev-config.json](Environments/dev/dev-config.json), [qa-config.json](Environments/qa/qa-config.json) | Not authoritative (COR-02), and they expose infrastructure layout | Check them against the connection string, or source them from App Configuration |
| 16 | Database names `dev_Client*DB_*`, `QA_Client*DB_*` | Same files | Not enforced at runtime (COR-01) | Enforce with `ChangeDatabase` |
| 17 | Connection variable names `dev-client00X-connstr` (hyphenated, shared) | Same files | Hyphenated environment variable names are awkward in PowerShell, and tenants share them (SEC-05) | A `SQL_<ENV>_<CLIENT>_<DB>` naming convention, or identity-based auth |
| 18 | `sugar_crm. Accounts` (×8) | `004_vendors/**/001_tableinsert.sql` | Hard-coded reference to another database or schema, and placeholder content | Real scripts. Use synonyms or SQLCMD variables for cross-database references |
| 19 | Object names without a schema: `OBJECT_ID('clients')`, `orders` | [003_sample.sql:3](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/003_sample.sql#L3), [:11](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/003_sample.sql#L11), [:14](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/003_sample.sql#L14) | Name resolution depends on the login's default schema | Always qualify with the schema (`dbo.clients`) |
| 20 | Local-time `Get-Date` timestamps | [Deploy:417](Scripts/Deploy-FeatureBasedSQL.ps1#L417); [Parse:372](Scripts/Parse_FeatureChecklist.ps1#L372); [Publish:56](Scripts/Publish-DeploymentResults.ps1#L56) | Time zone is ambiguous in audit records | `(Get-Date).ToUniversalTime().ToString('o')` |

> No passwords, keys or tokens were found in source.

---

## 8. Production-Grade and Operational Gaps

| ID | Sev | Gap | Impact | Recommendation |
|---|---|---|---|---|
| **PRD-01** | **Critical** | **No deployment journal or idempotency** | Nothing in the target database records which scripts have been applied. Re-running after a partial failure, or re-queuing a run, executes **every** script again. Most scripts have no existence guards, and the one that does (`003_sample.sql`) is broken. The status columns in the checklist CSV are never written back; results exist only as pipeline artifacts, which expire under retention policy. | A journal table in each target database (Section 11.C): skip scripts already applied (matched on path and hash), and **fail** if an applied script's hash has changed. **Strongly consider a proven migration engine** (DbUp, Flyway, Liquibase, or SSDT/DACPAC with SqlPackage) to execute the scripts, and keep this framework as the multi-tenant orchestrator on top. |
| **PRD-02** | **Critical** | **Rollback isn't real** | Every rollback script is either `SELECT 'rollback';` or empty. The placeholders still get marked `Rollback Success` ([Deploy:347-350](Scripts/Deploy-FeatureBasedSQL.ps1#L347-L350)). Empty rollback scripts fail. Three of the four features have no working rollback, and `003_sample.sql`, the only real DDL, has none at all. Together with COR-06 and COR-07, there is **no reliable recovery path**. | Require a rollback script for every DDL change (PR check). Test the cycle deploy, then rollback, then deploy again in a lower environment. For prod, keep a pre-deployment backup or snapshot as the last resort. |
| **PRD-03** | High | **No safety net before deployment** | No backup, database snapshot or recorded restore point before prod changes. No pre-checks: database online, not an AG secondary, enough free log space, no blocking. | Add a per-database pre-deploy stage: health checks, a `COPY_ONLY` backup or snapshot (on-prem) or a recorded PITR timestamp (Azure SQL). |
| **PRD-04** | High | **No concurrency control** | Two runs against the same environment can interleave. | Add an *Exclusive lock* check on the Environment, and `lockBehavior: sequential`. |
| **PRD-05** | High | **No CI or quality gates** | No PR pipeline, Pester tests, PSScriptAnalyzer or SQL lint. BLK-03, BLK-04, COR-05 and most other defects here would have been caught automatically. | A PR pipeline with: PSScriptAnalyzer; Pester unit tests for Parse/Generate/Publish using fixture CSV and JSON files; CSV and JSON schema validation; SQL lint; and an **integration test against a `mcr.microsoft.com/mssql/server` container** that runs deploy, validate and rollback. |
| **PRD-06** | High | **Unsafe error-handling defaults** | Parse, Deploy and Publish don't set `$ErrorActionPreference = 'Stop'` or `Set-StrictMode`. Cmdlet errors are non-terminating and execution carries on. State lives in `$Global:` variables ([Deploy:32-34](Scripts/Deploy-FeatureBasedSQL.ps1#L32-L34)). | Strict mode and `Stop`. Move shared logic into a `.psm1` module with exported, tested functions. |
| **PRD-07** | Medium | **Timeouts and resilience** | Command timeout is infinite. No retry on transient faults (for example Azure SQL 40613, 40501, 40197, 4060, 49918–49920). No `timeoutInMinutes` on jobs. | Retry the *connection* with exponential backoff; never automatically retry a batch that isn't idempotent. Set script and job timeouts. |
| **PRD-08** | Medium | **Scale and blast radius** | All tenants are processed one after another in a single job. One failure affects every tenant in that feature. Changes can't be rolled out to a pilot group first. | Roll out in rings (pilot tenants, then wave 1, then everyone). Optionally isolate tenants. Run servers in parallel up to a set limit. |
| **PRD-09** | Medium | **Observability** | Logs only exist in the pipeline console. No central log store, no failure alerts, and no dashboard of which version each tenant database is on. | Emit structured JSON events to Log Analytics. Post a summary to Teams or email. Build a per-database version report from the journal. |
| **PRD-10** | Medium | **Configuration management** | The JSON config has no schema, allows duplicate entries, and has fields nothing reads. The CSV mixes desired state (what to run) with run results (status columns). The dev and qa CSVs already disagree on headers and naming (`Application_Name` is `Workflow` in dev but `student` in qa). | Validate JSON Schema and CSV schema in PR. Keep run results separate from the checklist. Consider one YAML release manifest with per-environment overrides. |
| **PRD-11** | Medium | **Environment parity** | Only dev and qa exist. There is no UAT or staging, and no prod. The checklists don't match the folder contents. | Promote the *same* release manifest through every environment, and generate each environment's checklist from it. |
| **PRD-12** | Low | **Documentation** | No README, no runbook (deploy, rollback, handling partial failures), no architecture diagram, no guide for script authors. | Add `README.md`, `docs/runbook.md` and `docs/script-authoring-standard.md`. |
| **PRD-13** | Low | **Runtime platform** | Tied to Windows PowerShell 5.1 and Windows agents, and uses the deprecated `System.Data.SqlClient`. | PowerShell 7 (cross-platform) and `Microsoft.Data.SqlClient`. |
| **PRD-14** | Low | **The generator is interactive** | `Read-Host` at [Generate:74](Scripts/Generate-EnvironmentCSV.ps1#L74), [:101](Scripts/Generate-EnvironmentCSV.ps1#L101), [:123](Scripts/Generate-EnvironmentCSV.ps1#L123) and [:259](Scripts/Generate-EnvironmentCSV.ps1#L259) means it can't run in CI. | Take parameters, add `-WhatIf` support, and run it in the PR pipeline to check for drift. |

---

## 9. SQL Script Review (Release 1.0.0)

| File | Finding |
|---|---|
| [001_student/.../001_students.sql](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/001_students.sql) | `select * from student;` does nothing during a deployment. It is tagged DDL, has no schema prefix and uses `SELECT *`. |
| [001_student/.../002_allclients.sql](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/002_allclients.sql) | `SELECT 1;` placeholder. |
| [001_student/.../003_sample.sql](workflow.sql/1.0.0/001_student/Internal/Deployment/Primary/003_sample.sql) | **Line 3**: `sys.columns` has no `COLUMN_NAME` column (use `name`, or `COL_LENGTH('dbo.clients','email')`), so this raises *Invalid column name*. **Lines 14-15**: the `FOREIGN KEY` clause is duplicated, which is a **syntax error**. `OBJECT_ID` is called without a schema on lines 3, 11 and 20. The foreign key assumes `orders.client_id` is unique. Adding the `CHECK` constraint fails if any existing row breaks it. There is no transaction and **no rollback script**. |
| [002_teacher/01_common.sql](workflow.sql/1.0.0/002_teacher/01_common.sql), [02_allteachers.sql](workflow.sql/1.0.0/002_teacher/02_allteachers.sql) | **Empty**, so deployment fails. |
| [003_school/client1/01_client1.sql](workflow.sql/1.0.0/003_school/client1/01_client1.sql) | **Empty**. The folder name `client1` doesn't match any config client ID (`Client001`). |
| `004_vendors/Internal/Deployment/**/001_tableinsert.sql` (×8) | All eight are identical: `Select * From sugar_crm. Accounts`. They are named *tableinsert* but only read data, and they hard-code a reference to another database or schema. |
| [001_student/Internal/Rollback/*](workflow.sql/1.0.0/001_student/Internal/Rollback/) | `SELECT 'rollback';` placeholders, reported as successful rollbacks. One file has a double extension: `001_students.sql_rollback.sql`. |
| `004_vendors/Internal/Rollback/**` (×4) | **Empty.** The names (`001_vendors`, `002_vendorspayments`) don't match any deployment script. |

### Recommended script-authoring standard

```sql
/*
  Ticket        : ABC-1234
  Author        : <name>
  Description   : Add email column + check constraint to dbo.clients
  Idempotent    : Yes
  Transactional : Yes
  Rollback      : Rollback/<same-relative-path>.sql
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF COL_LENGTH(N'dbo.clients', N'email') IS NULL
BEGIN
    ALTER TABLE dbo.clients ADD email VARCHAR(255) NULL;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_clients_email' AND parent_object_id = OBJECT_ID(N'dbo.clients'))
BEGIN
    ALTER TABLE dbo.clients WITH CHECK
        ADD CONSTRAINT CK_clients_email CHECK (email IS NULL OR email LIKE '%_@_%._%');
END;
GO
```

Rules: always qualify object names with the schema. Guard every change with an existence check. Don't use `USE` (the framework sets the database). Don't use `SELECT *`. Put `GO` on its own line. Every DDL change needs a tested rollback script at the mirrored path.

---

## 10. Remediation Roadmap

| Phase | Goal | Findings |
|---|---|---|
| **Phase 0: Make it work** | One dev deployment completes end-to-end | BLK-01 to BLK-10, COR-01, COR-04, COR-05, COR-13, COR-15 |
| **Phase 1: Secure it** | Safe enough to point at QA | SEC-01 to SEC-06, RBAC-01 to RBAC-04, COR-12, COR-19 |
| **Phase 2: Make it safe for prod** | Recoverable, idempotent, auditable | PRD-01 to PRD-04, PRD-06, PRD-07, COR-02, COR-03, COR-06 to COR-11, SEC-07, RBAC-06 |
| **Phase 3: Enterprise maturity** | Scales, observable, governed | PRD-05, PRD-08 to PRD-14, RBAC-05, RBAC-07, RBAC-08, SEC-08 to SEC-10, COR-14, COR-16 to COR-18 |

> **Strategic option:** Replace the custom script runner (`Invoke-SQLScript`) with **DbUp** (a .NET library that works well from PowerShell) or **Flyway**, which provide a journal, transactions, checksums and batch splitting. Keep the parts that add real value here: the checklist, the multi-tenant fan-out, plan review and the approval flow. That removes about half of the High and Critical findings in one move.

---

## 11. Reference Fixes

### A. Pipeline: per-environment isolation, Environment-based gating, consistent paths

```yaml
trigger: none

variables:
- group: mssql-vg-${{ parameters.environment }}      # one Key Vault-backed group per environment
- template: vars/${{ parameters.environment }}.yml   # agentPoolName, timeouts, etc.

stages:
- stage: ExecuteScripts
  dependsOn: [ParseChecklist, ValidateScripts]
  condition: |
    and(succeeded(),
        eq(dependencies.ValidateScripts.outputs['ValidateSQL.ValidateStep.validationStatus'], 'Success'))
  lockBehavior: sequential
  jobs:
  - deployment: DeployToDatabase
    environment: sql-${{ parameters.environment }}   # Approvals, Branch control, Exclusive lock, Required template
    pool:
      name: ${{ variables.agentPoolName }}
    timeoutInMinutes: 120
    workspace:
      clean: all
    strategy:
      runOnce:
        deploy:
          steps:
          - checkout: self
          # Current-run artifacts are auto-downloaded to $(Pipeline.Workspace)/ExecutionPlan
          - task: PowerShell@2
            name: deployStep
            inputs:
              targetType: filePath
              filePath: Scripts/Deploy-FeatureBasedSQL.ps1
              arguments: >
                -ArtifactsDirectory "$(Pipeline.Workspace)/ExecutionPlan"
                -Environment "${{ parameters.environment }}"
                -ReleaseVersion "${{ parameters.releaseVersion }}"
              pwsh: true
            env:                                       # secrets must be mapped explicitly
              SQL_CLIENT001: $(sql-client001-connstr)
          - pwsh: |
              if ('$(deployStep.DeploymentSuccess)' -ne 'True') {
                Write-Error 'Deployment contains failures. Check the ExecutionResults artifact.'
                exit 1
              }
            displayName: Fail pipeline if deployment failed
            condition: always()
```

**Environment checks to configure in Azure DevOps (UI):**

| Check | `sql-qa` | `sql-prod` |
|---|---|---|
| Approvals | 1 approver (QA leads group) | ≥ 2 approvers (Release + DBA groups); *approvers can't approve own runs*; 24 h timeout |
| Branch control | `main`, `release/*` | `main`, `release/*`, with *verify branch protection* |
| Exclusive lock | Yes | Yes |
| Business hours | n/a | Change window only |
| Required template | Optional | Yes |

### B. `Invoke-SQLScript`: create the connection, enforce the database, use a transaction

```powershell
$connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
$connection.Open()
$connection.ChangeDatabase($DatabaseName)

$transaction = $connection.BeginTransaction()
try {
    foreach ($batch in $batches) {
        $command = $connection.CreateCommand()
        $command.Transaction    = $transaction
        $command.CommandText    = $batch.Trim()
        $command.CommandTimeout = $TimeoutSeconds   # from config, never 0
        [void]$command.ExecuteNonQuery()
        $command.Dispose()
    }
    $transaction.Commit()
}
catch {
    if ($transaction.Connection) { $transaction.Rollback() }
    throw
}
finally {
    $connection.Dispose()
}
```

### C. Deployment journal (one per target database)

```sql
IF OBJECT_ID(N'dbo.__DeploymentJournal') IS NULL
CREATE TABLE dbo.__DeploymentJournal (
    JournalId       INT IDENTITY(1,1) PRIMARY KEY,
    ReleaseVersion  NVARCHAR(50)   NOT NULL,
    ScriptPath      NVARCHAR(400)  NOT NULL,
    ScriptSha256    CHAR(64)       NOT NULL,
    Status          NVARCHAR(20)   NOT NULL,   -- Success | Failed | RolledBack
    AppliedAtUtc    DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME(),
    RequestedBy     NVARCHAR(256)  NOT NULL,   -- $(Build.RequestedForEmail)
    ApprovedBy      NVARCHAR(256)  NULL,
    PipelineRunId   NVARCHAR(50)   NOT NULL,   -- $(Build.BuildId)
    CommitSha       CHAR(40)       NOT NULL,   -- $(Build.SourceVersion)
    DurationMs      INT            NULL,
    CONSTRAINT UQ_Journal UNIQUE (ScriptPath, ScriptSha256, Status)
);
```

Before running a script: if a row with the same `ScriptPath` and hash has `Status = 'Success'`, skip the script. If the same `ScriptPath` succeeded with a *different* hash, **fail**, because an already-applied script has been edited.

### D. Keep file paths inside the release folder

```powershell
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot "workflow.sql/$ReleaseVersion")) + [IO.Path]::DirectorySeparatorChar
$fullPath    = [IO.Path]::GetFullPath((Join-Path $RepoRoot $row.SQL_Path))
if (-not $fullPath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "SQL_Path '$($row.SQL_Path)' is outside the release folder."
}
```

---

## Appendix A: Verification Evidence

Run locally with Windows PowerShell 5.1, system ANSI code page 1252:

```text
Parser.ParseFile results
  Deploy-FeatureBasedSQL.ps1   : 2 parse errors
     L588: Missing closing '}' in statement block or type definition.
     L680: The Try statement is missing its Catch or Finally block.
  Generate-EnvironmentCSV.ps1  : 0 parse errors (but mis-tokenized, see below)
  Parse_FeatureChecklist.ps1   : 0 parse errors
  Publish-DeploymentResults.ps1: 0 parse errors

Deploy-FeatureBasedSQL.ps1 re-parsed as UTF-8 text: 0 errors  -> confirms an encoding cause

Encoding: no BOM in any script; non-ASCII bytes: Deploy=6, Generate=2832, Parse=0, Publish=0

Generate-EnvironmentCSV.ps1 line 255 tokens under PS 5.1:
  [StringExpandable] "  '$($featureFolder.Name)' already in CSV â€“      <- string ends early
  [Identifier] keeping
  ...
  [StringExpandable] "\n    }\n    else {\n        # New folder â€“         <- else-block swallowed into a string

Deploy-FeatureBasedSQL.ps1 line 187 tokens:
  If | LParen | Label(:IsNullorwhitespace) | ...                            <- label, not a method call

File existence:
  Scripts/Validate-SQLScripts.ps1 : False
  Environments/prod/              : False

Credential scan (password|pwd=|secret|token|apikey|uid=|user id=): no matches
Git: repository initialised, no commits, no remote, no .gitignore
```

## Appendix B: Files Reviewed

- `Pipelines/azure-pipelines.yml` (240 lines)
- `Scripts/Parse_FeatureChecklist.ps1` (385), `Scripts/Deploy-FeatureBasedSQL.ps1` (680), `Scripts/Publish-DeploymentResults.ps1` (451), `Scripts/Generate-EnvironmentCSV.ps1` (463)
- `Environments/dev/dev-config.json`, `Environments/dev/dev.csv`, `Environments/qa/qa-config.json`, `Environments/qa/qa.csv`
- `workflow.sql/1.0.0/**`: 14 deployment scripts and 6 rollback scripts (20 files)

# Passwordless SQL Authentication for the SQL Deployment Pipeline

This guide removes stored SQL passwords from the pipeline. Connection strings then contain no secret, so they can stay **non-secret variables** in the Library, and the deploy script continues to read them as environment variables.

| Your SQL platform | Use | Script change |
|---|---|---|
| **SQL Server on-premises / on VMs** (domain-joined) | **Part A: gMSA + Windows authentication** | **None.** Only the connection strings change |
| **Azure SQL Database / Managed Instance** | **Part B: Microsoft Entra ID token** | Small: request a token and attach it to the connection |

Roll out in **dev first**. Keep the old SQL logins until a dev deployment and rollback succeed, then retire them (Part C).

---

## Part A: On-premises SQL Server with a gMSA

A **group Managed Service Account (gMSA)** is an Active Directory account whose password Windows generates and rotates automatically. Nobody knows or stores it. The Azure Pipelines agent service runs as the gMSA, and every script it runs authenticates to SQL Server as that account through Windows authentication.

Use **one gMSA and one agent pool per environment** (dev, qa, prod). A dev agent then has no rights on prod databases.

### Prerequisites

| Requirement | Who |
|---|---|
| Domain functional level Windows Server 2012 or later | AD admin |
| Agent hosts and SQL Servers in the same domain (or a trusted one) | AD admin |
| Domain Admin rights (or delegated rights to create a KDS root key and service accounts) | AD admin |
| `sysadmin` (or `securityadmin`) on each SQL Server, to create the login | DBA |
| Local admin on each agent host | Platform team |

### Step 1: Create the KDS root key (once per forest)

Check whether one exists:

```powershell
Get-KdsRootKey
```

If nothing is returned, create one on a domain controller:

```powershell
Add-KdsRootKey -EffectiveImmediately
```

> The key becomes usable after up to 10 hours, while it replicates to all domain controllers. Plan for that delay before Step 3.

### Step 2: Create a security group for the agent hosts

The group lists the computers allowed to retrieve the gMSA password.

```powershell
New-ADGroup -Name "grp-ado-sqlagent-dev-hosts" -GroupScope Global -GroupCategory Security `
    -Path "OU=Groups,DC=corp,DC=local"

Add-ADGroupMember -Identity "grp-ado-sqlagent-dev-hosts" -Members "DEVAGENT01$", "DEVAGENT02$"
```

Reboot each agent host afterwards, or run `klist purge -li 0x3e7` on it as administrator, so its Kerberos ticket picks up the new group membership.

### Step 3: Create the gMSA

```powershell
New-ADServiceAccount -Name "gmsa-adosql-dev" `
    -DNSHostName "gmsa-adosql-dev.corp.local" `
    -PrincipalsAllowedToRetrieveManagedPassword "grp-ado-sqlagent-dev-hosts" `
    -KerberosEncryptionType AES128, AES256
```

> Keep the name to 15 characters or fewer. Repeat with `-qa` and `-prod` names for the other environments, each with its own host group.

### Step 4: Install and test the gMSA on each agent host

Run these as administrator on every agent host:

```powershell
# Windows Server
Install-WindowsFeature RSAT-AD-PowerShell

Install-ADServiceAccount -Identity "gmsa-adosql-dev"
Test-ADServiceAccount   -Identity "gmsa-adosql-dev"    # must return True
```

If `Test-ADServiceAccount` returns `False`, the host isn't in the group yet, or hasn't refreshed its ticket (see Step 2).

### Step 5: Run the Azure Pipelines agent service as the gMSA

**Option 1: services console** (simplest)

1. Open `services.msc` on the agent host.
2. Open **Azure Pipelines Agent (`vstsagent.<org>.<pool>.<agent>`)** and go to the **Log On** tab.
3. Choose **This account** and enter `CORP\gmsa-adosql-dev$`. Note the trailing `$`. **Leave both password boxes empty.**
4. Click OK, then restart the service. The console grants the *Log on as a service* right automatically.

**Option 2: reconfigure the agent** (repeatable, can be scripted)

```powershell
cd C:\agent
.\config.cmd remove
.\config.cmd --unattended --url https://dev.azure.com/<org> --auth pat --token <PAT> `
    --pool "<dev-pool>" --agent "$env:COMPUTERNAME" --runAsService `
    --windowsLogonAccount "CORP\gmsa-adosql-dev$" --windowsLogonPassword ""
```

> Check that your agent version accepts an empty password for a gMSA. If it doesn't, use Option 1.

**Folder permissions:** the gMSA needs **Modify** on the agent folder, including `_work`. Configuring through `config.cmd` sets this. If you used Option 1, grant it yourself:

```powershell
icacls "C:\agent" /grant "CORP\gmsa-adosql-dev$:(OI)(CI)M" /T
```

### Step 6: Make Kerberos work against SQL Server (recommended)

Without a registered SPN, Windows authentication falls back to NTLM. That still works for this single hop (agent to SQL), but Kerberos is stronger and is what most security standards require.

1. Check the SPNs registered for the SQL Server service account:
   ```powershell
   setspn -L CORP\svc-sqlserver-dev1
   ```
   You should see `MSSQLSvc/dev-server1.corp.local:1433` and `MSSQLSvc/dev-server1.corp.local`.
2. If they're missing, a Domain Admin registers them:
   ```powershell
   setspn -S MSSQLSvc/dev-server1.corp.local:1433 CORP\svc-sqlserver-dev1
   setspn -S MSSQLSvc/dev-server1.corp.local      CORP\svc-sqlserver-dev1
   ```
3. Always use the **fully qualified name** (`dev-server1.corp.local`) in connection strings.

### Step 7: Create the SQL login and database users (least privilege)

Run on each SQL Server in that environment, as a DBA:

```sql
-- Server level: Windows login for the gMSA (note the trailing $)
CREATE LOGIN [CORP\gmsa-adosql-dev$] FROM WINDOWS;
```

Then in **every target database** listed in `dev-config.json` (for example `dev_Client1DB_001`, `dev_Client2DB_001`, `dev_Client2DB_003`):

```sql
USE [dev_Client1DB_001];

CREATE USER [CORP\gmsa-adosql-dev$] FOR LOGIN [CORP\gmsa-adosql-dev$];

-- Deployment role: schema changes plus data changes, but no security administration
IF DATABASE_PRINCIPAL_ID(N'sql_deployer') IS NULL
    CREATE ROLE sql_deployer;
ALTER ROLE db_ddladmin   ADD MEMBER sql_deployer;
ALTER ROLE db_datareader ADD MEMBER sql_deployer;
ALTER ROLE db_datawriter ADD MEMBER sql_deployer;
GRANT EXECUTE         TO sql_deployer;   -- only if scripts execute stored procedures
GRANT VIEW DEFINITION TO sql_deployer;   -- lets existence checks see object metadata

ALTER ROLE sql_deployer ADD MEMBER [CORP\gmsa-adosql-dev$];
```

> Don't grant `sysadmin` or `db_owner`. If release scripts contain `GRANT` or `CREATE USER` statements, add `db_securityadmin` to the role, and do it knowingly. Rather than adding the gMSA directly, you can add it to an AD group and create the login for the group.

### Step 8: Change the connection strings

Replace each Library value with a Windows-authentication connection string. It holds no password, so it can be a **normal (non-secret) variable**, and the script's existing environment-variable lookup works unchanged.

```text
Server=tcp:dev-server1.corp.local,1433;Database=dev_Client1DB_001;Integrated Security=SSPI;Encrypt=True;TrustServerCertificate=False;
```

> `Encrypt=True;TrustServerCertificate=False` requires SQL Server to present a certificate the agent hosts trust (issued for the server's FQDN). If no such certificate exists yet, use `TrustServerCertificate=True` temporarily, and track getting a proper certificate as a follow-up.

### Step 9: Verify

1. Add a temporary pipeline step, or run on the agent host as the gMSA:
   ```powershell
   whoami    # expected: corp\gmsa-adosql-dev$
   ```
2. Run this as a validation query or a one-off script against a target database:
   ```sql
   SELECT SUSER_SNAME() AS login_name, auth_scheme
   FROM sys.dm_exec_connections
   WHERE session_id = @@SPID;
   -- expected: CORP\gmsa-adosql-dev$, KERBEROS (NTLM if Step 6 was skipped)
   ```
3. Run a dev deployment, including one deliberately failing script, and confirm the rollback.

---

## Part B: Azure SQL with a Microsoft Entra ID token

The pipeline signs in to Azure through a **workload identity federation** service connection, which stores no secret either. The script asks for a short-lived access token for Azure SQL and attaches it to the connection.

### Prerequisites

| Requirement | Who |
|---|---|
| A **Microsoft Entra admin** set on each Azure SQL logical server (an Entra group is recommended) | Azure admin |
| Permission to create Azure Resource Manager service connections in the Azure DevOps project | Project admin |
| Network path from the self-hosted agents to Azure SQL (firewall rule for the agents' egress IP, or a private endpoint) | Network / Azure admin |
| `Az.Accounts` PowerShell module on each self-hosted agent: `Install-Module Az.Accounts -Scope AllUsers` | Platform team |

### Step 1: Create one service connection per environment

1. Go to **Project settings**, then **Service connections**, then **New service connection**, then **Azure Resource Manager**.
2. Choose **Workload Identity federation**:
   - **Automatic** creates an app registration for you.
   - **Manual** lets you use your own user-assigned managed identity. **Recommended**, because you control its Azure RBAC rights.
3. Name it per environment, for example `sc-sql-deploy-dev`, and **don't** tick *Grant access permission to all pipelines*.
4. Under **Security**, allow only this pipeline.
5. Azure SQL **data access doesn't need any Azure RBAC role**. If the automatic option assigned *Contributor*, reduce it to the minimum your organization's policy allows.
6. Note the identity's **display name** and **Object (principal) ID**.

### Step 2: Create the database users

Connect to **each target database** as the server's Entra admin, using SSMS or Azure Data Studio with *Microsoft Entra* authentication, and run:

```sql
CREATE USER [sc-sql-deploy-dev] FROM EXTERNAL PROVIDER
    WITH OBJECT_ID = '<object-id-of-the-identity>';   -- avoids ambiguity between identities with the same name

IF DATABASE_PRINCIPAL_ID(N'sql_deployer') IS NULL
    CREATE ROLE sql_deployer;
ALTER ROLE db_ddladmin   ADD MEMBER sql_deployer;
ALTER ROLE db_datareader ADD MEMBER sql_deployer;
ALTER ROLE db_datawriter ADD MEMBER sql_deployer;
GRANT EXECUTE         TO sql_deployer;
GRANT VIEW DEFINITION TO sql_deployer;

ALTER ROLE sql_deployer ADD MEMBER [sc-sql-deploy-dev];
```

> If an *automation identity* runs `CREATE USER … FROM EXTERNAL PROVIDER` instead of a person, the SQL server's own managed identity needs the Entra **Directory Readers** role.

### Step 3: Change the connection strings

There are no user names, passwords or `Integrated Security` settings. Keep them as **non-secret** variables:

```text
Server=tcp:<server-name>.database.windows.net,1433;Database=dev_Client1DB_001;Encrypt=True;TrustServerCertificate=False;
```

### Step 4: Script change in `Deploy-FeatureBasedSQL.ps1`

Add a parameter and a token helper. This is compatible with Windows PowerShell 5.1:

```powershell
# param() block
[parameter(Mandatory = $false)]
[switch]$UseEntraAuth

function Get-SqlAccessToken {
    $tokenResult = Get-AzAccessToken -ResourceUrl "https://database.windows.net/" -ErrorAction Stop
    $token = $tokenResult.Token

    # Az.Accounts 5.x returns a SecureString; earlier versions return plain text
    if ($token -is [System.Security.SecureString]) {
        $token = (New-Object System.Net.NetworkCredential("", $token)).Password
    }
    return $token
}
```

Wherever a connection is created (`Invoke-SQLScript` and `Test-ValidationQuery`), attach the token before `Open()`:

```powershell
$connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
if ($UseEntraAuth) {
    $connection.AccessToken = Get-SqlAccessToken
}
$connection.Open()
```

> Tokens last about 60–90 minutes. Requesting one for each script connection, as above, keeps long deployments working, and Az.Accounts caches tokens, so the cost is negligible.

### Step 5: Pipeline change

Run the deploy step under the service connection. `AzurePowerShell@5` signs in first, then runs the same script on Windows PowerShell 5.1:

```yaml
- task: AzurePowerShell@5
  name: deployStep                      # keep the name; later steps read its output variables
  displayName: 'Execute Feature-Based SQL Deployment Script'
  inputs:
    azureSubscription: 'sc-sql-deploy-${{ parameters.environment }}'
    ScriptType: 'FilePath'
    ScriptPath: 'Scripts/Deploy-FeatureBasedSQL.ps1'
    ScriptArguments: >
      -ChecklistPath "$(ChecklistPath)"
      -ConfigFilePath "$(ConfigFilePath)"
      -ArtifactsDirectory "$(ArtifactsDirectory)"
      -Environment "${{ parameters.environment }}"
      -ReleaseVersion "${{ parameters.releaseVersion }}"
      -ApplicationFilter "${{ parameters.ApplicationFilter }}"
      -FeatureFilter "${{ parameters.FeatureFilter }}"
      -RollbackStrategy "${{ parameters.RollbackStrategy }}"
      -UseEntraAuth
    azurePowerShellVersion: 'LatestVersion'
    pwsh: false
    workingDirectory: '$(System.DefaultWorkingDirectory)'
```

The publish-results step doesn't connect to SQL, so it stays `PowerShell@2`.

### Step 6: Verify

```sql
SELECT SUSER_SNAME() AS login_name, ORIGINAL_LOGIN() AS original_login;
-- expected: the service connection's identity (application ID / name)
```

Then run a dev deployment, including one deliberately failing script, and confirm the rollback.

---

## Part C: Retire the passwords

Do this only after dev and qa deployments **and** rollbacks have succeeded with the new method.

1. **Library:** delete the old secret and literal connection-string values, and keep only the passwordless ones.
2. **SQL logins:**
   - On-prem: `ALTER LOGIN [old_sql_login] DISABLE;` Drop the login after an agreed observation period.
   - Azure SQL: optionally enable **Microsoft Entra-only authentication** on the logical server, which blocks SQL logins entirely.
3. **Separate the environments:** one gMSA or service connection per environment, used only by that environment's agent pool and pipeline. The dev identity must have **no** login on qa or prod servers.
4. **Document the identities:** record each environment's identity, the databases it can reach, and its role (`sql_deployer`) in your access-review register.
5. **Review regularly:** run a quarterly access review of `sql_deployer` members and of who can use each service connection or agent pool.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Test-ADServiceAccount` returns False | Host isn't in the host group, or its Kerberos ticket is stale | Add the computer to the group, then reboot or run `klist purge -li 0x3e7` |
| Agent service won't start after the logon change | Missing *Log on as a service* right, or no folder permissions | Use `services.msc` (it grants the right) and grant Modify on the agent folder |
| `Login failed for user 'CORP\DEVAGENT01$'` | Agent is still running as the machine account | Recheck the service's **Log On** account, and restart it |
| `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'` | A double hop, or a Kerberos delegation problem | Make sure the agent connects directly to SQL. Check the SPNs (Part A, Step 6) |
| `auth_scheme` = NTLM | No SPN, or server addressed by IP or short name | Register the SPNs and use the FQDN in connection strings |
| `The certificate chain was issued by an authority that is not trusted` | The SQL Server certificate isn't trusted by the agent | Install a trusted certificate on SQL Server, or use `TrustServerCertificate=True` temporarily |
| Azure: `Login failed for user '<token-identified principal>'` | No database user for the identity in that database | Run Part B, Step 2 in **that** database |
| Azure: `Get-AzAccessToken` isn't recognized | Az.Accounts isn't installed on the agent, or the step isn't `AzurePowerShell@5` | Install the module and use `AzurePowerShell@5` |
| Azure: `Cannot open server … requested by the login. Client with IP address … is not allowed` | Azure SQL firewall | Allow the agents' egress IP, or use a private endpoint |

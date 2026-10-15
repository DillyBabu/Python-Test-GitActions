param(
    [parameter(Mandatory = $true)]
    [string]$ChecklistPath,

    [parameter(Mandatory = $true)]
    [string]$ConfigFilePath,

    [parameter(Mandatory = $true)]
    [string]$Environment,

    [parameter(Mandatory = $true)]
    [string]$ReleaseVersion,

    [parameter(Mandatory = $false)]
    [string]$ApplicationFilter = 'all',

    [parameter(Mandatory = $false)]
    [string]$FeatureFilter = 'all',

    [parameter(Mandatory = $false)]
    [string]$ArtifactsDirectory = "$(Join-Path $PWD 'artifacts')",

    [parameter(Mandatory = $false)]
    [string]$DryRun = 'true'
)

$VarDryRun = [System.Convert]::ToBoolean($DryRun)

function Write-StageHeader {
    param([string]$Message)
    Write-Host $Message
    Write-Host ('=' * ($Message.Length + 3))
}

function Get-ClientConfiguration {
    param(
        [array]$ConfigData,
        [string]$ClientName,
        [string]$Environment
    )

    # A client can appear in several config entries (e.g. one per application);
    # all of them are returned so the script is deployed to every database of the client
    $clientConfigs = @($ConfigData | Where-Object { $_.clientName -eq $ClientName })

    if ($clientConfigs.Count -eq 0) {
        Write-Warning "Client '$ClientName' not found in configuration"
    }

    return $clientConfigs
}

function Expand-ExecutionPlanForClient {
    param(
        [object]$ScriptRow,
        [object[]]$ClientConfigs,
        [hashtable]$SeenTargets
    )

    $expandedRows = @()

    foreach ($clientConfig in $ClientConfigs) {
        if (-not $clientConfig.servers) {
            Write-Warning "No servers found for client $($clientConfig.clientName) (application: $($clientConfig.applicationName))"
            continue
        }

        foreach ($server in $clientConfig.servers) {
            $databases = @($server.databases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            if ($databases.Count -eq 0) {
                Write-Warning "No databases found for server $($server.serverName) in client $($clientConfig.clientName)"
                continue
            }

            foreach ($database in $databases) {
                # Deploy a script only once per server/database, even if several clients
                # in the same Client_Name list point to the same database
                $targetKey = "$($server.serverName)|$database".ToLowerInvariant()
                if ($SeenTargets.ContainsKey($targetKey)) {
                    Write-Host "Skipping $($server.serverName)/$database for client '$($clientConfig.clientName)': already targeted by client '$($SeenTargets[$targetKey])' for $($ScriptRow.SQL_Path)" -ForegroundColor Yellow
                    continue
                }
                $SeenTargets[$targetKey] = $clientConfig.clientName

                $expandedRows += Get-ExpandedRow -ScriptRow $ScriptRow -ClientName $clientConfig.clientName -Server $server -Database $database
            }
        }
    }

    return $expandedRows
}

function Get-ExpandedRow {
    param(
        [object]$ScriptRow,
        [string]$ClientName,
        [object]$Server,
        [string]$Database
    )

    return [PSCustomObject]@{
        Release_Version        = $ScriptRow.Release_Version
        Application_Name       = $ScriptRow.Application_Name
        Feature_Name           = $ScriptRow.Feature_Name
        Feature_Order          = $ScriptRow.Feature_Order
        SQL_Path               = $ScriptRow.SQL_Path
        Script_Type            = $ScriptRow.Script_Type
        Execute_Script         = $ScriptRow.Execute_Script
        Environment            = $ScriptRow.Environment
        Client_Name            = $ClientName
        Server_Name            = $Server.serverName
        Database_Name          = $Database
        ConnectionStringVar    = $Server.connectionStringVar
        Script_Order           = $ScriptRow.Script_Order
        Prerequisites          = $ScriptRow.Prerequisites
        Rollback_script_path   = $ScriptRow.Rollback_script_path
        Feature_Rollback_order = $ScriptRow.Feature_Rollback_order
        Execution_Status       = $ScriptRow.Execution_Status
        Duration               = $ScriptRow.Duration
        Rows_Affected          = $ScriptRow.Rows_Affected
        Error_Message          = $ScriptRow.Error_Message
        Execution_Date         = $ScriptRow.Execution_Date
        Executed_By            = $ScriptRow.Executed_By
        Comments               = $ScriptRow.Comments
        Pipeline_RunId         = $ScriptRow.Pipeline_RunId
    }
}

function Validate-Prerequisites {
    param(
        [array]$FeatureScripts,
        [array]$AllFilteredScripts,
        [string]$Feature_Name
    )

    Write-Host "Validating prerequisites for feature: $Feature_Name"
    foreach ($currentScript in $FeatureScripts) {
        if ([string]::IsNullOrWhiteSpace($currentScript.Prerequisites)) {
            continue
        }

        $prereqExists = $FeatureScripts | Where-Object {
            $_.SQL_Path -like "*$($currentScript.Prerequisites)*"
        }

        if (-not $prereqExists) {
            $crossFeaturePrereq = $AllFilteredScripts | Where-Object {
                $_.SQL_Path -like "*$($currentScript.Prerequisites)*"
            }

            if (-not $crossFeaturePrereq) {
                Write-Warning "Prerequisite '$($currentScript.Prerequisites)' not found for $($currentScript.SQL_Path)"
                return $false
            }
            else {
                Write-Host "Cross-feature dependency found for $($currentScript.SQL_Path)" -ForegroundColor Cyan
            }
        }
    }
    return $true
}

function Export-ExecutionPlan {
    param (
        [array]$ExecutionPlan,
        [string]$OutputPath
    )

    try {
        if ($ExecutionPlan.Count -eq 0) {
            Write-Warning "No execution plan rows to export"
            return $false
        }

        $ExecutionPlan | Export-Csv -Path $OutputPath -NoTypeInformation -Force
        Write-Host "Exported Execution Plan with $($ExecutionPlan.Count) rows to $OutputPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to export execution plan: $($_.Exception.Message)"
        return $false
    }
}

# Main execution block
Write-StageHeader "Parsing Feature-Based Release Checklist"

# Validate paths
if (-not (Test-Path $ChecklistPath)) {
    Write-Error "Checklist path '$ChecklistPath' does not exist."
    exit 1
}

if (-not (Test-Path $ConfigFilePath)) {
    Write-Error "Config file path '$ConfigFilePath' does not exist."
    exit 1
}

if (-not (Test-Path -Path $ArtifactsDirectory)) {
    New-Item -ItemType Directory -Path $ArtifactsDirectory -Force | Out-Null
    Write-Host "Created artifacts directory: $ArtifactsDirectory" -ForegroundColor Yellow
}

# Read configuration file
Write-Host "Reading client configuration from $ConfigFilePath"
try {
    $configContent = Get-Content -Path $ConfigFilePath -Raw
    $ConfigData = $configContent | ConvertFrom-Json
    Write-Host "Loaded configuration for $($ConfigData.Count) client(s)" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to read config file: $($_.Exception.Message)"
    exit 1
}

# Read feature checklist
Write-Host "Reading feature checklist from $ChecklistPath"
try {
    $Checklist = Import-Csv $ChecklistPath
    Write-Host "Total records in checklist: $($Checklist.Count)" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to read feature checklist: $($_.Exception.Message)"
    exit 1
}

# Filter for current environment, release version, and Execute_Script = 'Yes'
Write-Host "Filtering features for Environment: $Environment, Release Version: $ReleaseVersion"
$baseScripts = $Checklist | Where-Object {
    $_.Environment -eq $Environment -and
    $_."Release_Version" -eq $ReleaseVersion -and
    $_.'Execute_Script' -eq 'Yes'
}

if ($baseScripts.Count -eq 0) {
    Write-Warning "No scripts found for Environment $Environment and Release Version $ReleaseVersion"
    Write-Host "Available Combinations in checklist:" -ForegroundColor Yellow
    $Checklist | Select-Object "Application_Name", "Feature_Name", "Environment", "Release_Version" -Unique | Format-Table -AutoSize
    exit 1
}

$FilteredScripts = $baseScripts

# Apply optional Application Filter
if ($ApplicationFilter -ne 'all') {
    Write-Host "Applying Application Filter: $ApplicationFilter" -ForegroundColor Cyan
    $FilteredScripts = $FilteredScripts | Where-Object { $_.Application_Name -eq $ApplicationFilter }
}

# Apply optional Feature Filter
if ($FeatureFilter -ne 'all') {
    Write-Host "Applying Feature Filter: $FeatureFilter" -ForegroundColor Cyan
    $FilteredScripts = $FilteredScripts | Where-Object { $_.Feature_Name -eq $FeatureFilter }
}

if ($FilteredScripts.Count -eq 0) {
    Write-Warning "No scripts found after applying filters"
    Write-Host "Applied Filters - Application: '$ApplicationFilter', Feature: $FeatureFilter, Environment: $Environment, Release Version: $ReleaseVersion"
    exit 1
}

# Track skipped rows
$SkippedRows = @()
$ExecutionPlan = @()

# Expand execution plan for each script based on client configurations
Write-StageHeader "Expanding Execution Plan by Client and Database"

foreach ($script in $FilteredScripts) {
    $clientName = $script.Client_Name

    if ([string]::IsNullOrWhiteSpace($clientName)) {
        Write-Warning "Skipping row - Client_Name is empty for script: $($script.SQL_Path)"
        $SkippedRows += @($script)
        continue
    }

    # Handle comma-separated client names
    $clientNames = @($clientName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # Server/database targets already planned for this script row (prevents double deployment)
    $seenTargets = @{}

    foreach ($clientId in $clientNames) {
        $clientConfigs = @(Get-ClientConfiguration -ConfigData $ConfigData -ClientName $clientId -Environment $Environment)

        if ($clientConfigs.Count -eq 0) {
            Write-Warning "Client '$clientId' not found in configuration - skipping this client for script $($script.SQL_Path)"
            $SkippedRows += @(@{
                    SQL_Path    = $script.SQL_Path
                    Client_Name = $clientId
                    Reason      = "Client not found in configuration"
                })
            continue
        }

        $expandedRows = @(Expand-ExecutionPlanForClient -ScriptRow $script -ClientConfigs $clientConfigs -SeenTargets $seenTargets)
        if ($expandedRows.Count -gt 0) {
            $ExecutionPlan += $expandedRows
        }

        $targets = ($expandedRows | ForEach-Object { "$($_.Server_Name)/$($_.Database_Name)" }) -join ', '
        Write-Host "Expanded script $($script.SQL_Path) for client '$clientId' to $($expandedRows.Count) database(s): $targets" -ForegroundColor Cyan
    }
}

if ($ExecutionPlan.Count -eq 0) {
    Write-Error "No execution plan rows generated after processing all scripts"
    exit 1
}

Write-Host "Total execution plan rows: $($ExecutionPlan.Count)" -ForegroundColor Green

# Sort by Application, Feature Order, Script Order
$ExecutionPlan = $ExecutionPlan | Sort-Object -Property Application_Name, @{Expression = { [int]$_.Feature_Order }; Ascending = $true }, @{Expression = { [int]$_.Script_Order }; Ascending = $true }, Server_Name, Database_Name

# Validate prerequisites
Write-StageHeader "Validating Prerequisites"
$featureGroups = $ExecutionPlan | Group-Object -Property Application_Name, Feature_Name

$validationSuccess = $true
foreach ($featureGroup in $featureGroups) {
    $FeatureScripts = $featureGroup.Group | Sort-Object { [int]$_.'Script_Order' }
    $prereqValid = Validate-Prerequisites -FeatureScripts $FeatureScripts -AllFilteredScripts $ExecutionPlan -Feature_Name $featureGroup.Name

    if (-not $prereqValid) {
        $validationSuccess = $false
        Write-Error "Prerequisite validation failed for feature: $($featureGroup.Name)"
    }
}

if (-not $validationSuccess) {
    Write-Error "Validation failed. Exiting script."
    exit 1
}

# Dry run report
if ($VarDryRun) {
    Write-StageHeader "DRY RUN - No artifacts will be created"
    Write-Host "Environment: $Environment"
    Write-Host "Release Version: $ReleaseVersion"
    Write-Host "Application Filter: $ApplicationFilter"
    Write-Host "Feature Filter: $FeatureFilter"
    Write-Host "Total Execution Plan Rows: $($ExecutionPlan.Count)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Sample Execution Plan (first 10 rows):" -ForegroundColor Yellow
    $ExecutionPlan | Select-Object -First 10 | Format-Table -Property Application_Name, Feature_Name, Client_Name, Server_Name, Database_Name, Script_Order -AutoSize

    if ($SkippedRows.Count -gt 0) {
        Write-Host ""
        Write-Host "Skipped Rows: $($SkippedRows.Count)" -ForegroundColor Yellow
        $SkippedRows | Format-Table -AutoSize
    }

    Write-StageHeader "End of DRY RUN"
    exit 0
}

# Export execution plan
$executionPlanPath = Join-Path $ArtifactsDirectory "execution_plan.csv"
$exportSuccess = Export-ExecutionPlan -ExecutionPlan $ExecutionPlan -OutputPath $executionPlanPath
if (-not $exportSuccess) {
    Write-Error "Failed to export execution plan. Exiting script."
    exit 1
}

# Export skipped rows report
if ($SkippedRows.Count -gt 0) {
    $skippedPath = Join-Path $ArtifactsDirectory "skipped_rows.csv"
    try {
        $SkippedRows | Export-Csv -Path $skippedPath -NoTypeInformation -Force
        Write-Host "Exported skipped rows report to $skippedPath" -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Failed to export skipped rows report: $($_.Exception.Message)"
    }
}

# Output variables for pipeline
Write-Host "##vso[task.setvariable variable=ExecutionPlanRows;isOutput=true]$($ExecutionPlan.Count)"
Write-Host "##vso[task.setvariable variable=SkippedRows;isOutput=true]$($SkippedRows.Count)"
Write-Host "##vso[task.setvariable variable=FeatureCount;isOutput=true]$($featureGroups.Count)"
Write-Host "##vso[task.setvariable variable=ClientCount;isOutput=true]$(($ExecutionPlan | Select-Object -Unique Client_Name).Count)"
Write-Host "##vso[task.setvariable variable=ServerCount;isOutput=true]$(($ExecutionPlan | Select-Object -Unique Server_Name).Count)"

# Create summary report
$SummaryReport = @{
    "ReleaseVersion"    = $ReleaseVersion
    "Environment"       = $Environment
    "ApplicationFilter" = $ApplicationFilter
    "FeatureFilter"     = $FeatureFilter
    "ExecutionPlanRows" = $ExecutionPlan.Count
    "SkippedRows"       = $SkippedRows.Count
    "FeatureCount"      = $featureGroups.Count
    "ClientCount"       = ($ExecutionPlan | Select-Object -Unique Client_Name).Count
    "ServerCount"       = ($ExecutionPlan | Select-Object -Unique Server_Name).Count
    "ProcessingTime"    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    "ValidationSuccess" = if ($validationSuccess) { "Success" } else { "Failed" }
}

$SummaryPath = Join-Path $ArtifactsDirectory "summary_report.json"
$SummaryReport | ConvertTo-Json | Set-Content $SummaryPath
Write-Host "Exported Summary Report to $SummaryPath" -ForegroundColor Green

Write-StageHeader "Checklist Parsing Completed Successfully"
Write-Host "Execution Plan Rows: $($ExecutionPlan.Count)" -ForegroundColor Green
Write-Host "Skipped Rows: $($SkippedRows.Count)" -ForegroundColor Yellow
Write-Host "Features: $($featureGroups.Count)" -ForegroundColor Green

Write-Host "Ready for Script Validation and Deployment stages" -ForegroundColor Green
<#
.SYNOPSIS
    Creates or updates an <environment>.csv file for a specific release stage.

.DESCRIPTION
    - Lists available release folders under workflow.sql.
    - Validates feature sub-folder numeric prefixes (unique, required).
    - Recursively discovers SQL scripts under each feature folder.
    - Generates / updates Environments\<env>\<env>.csv with all required headers.
    - Auto-populates: Application_Name (from folder suffix), Feature_Order,
      Script_order, SQL_Path, Branch_Name, Prerequisites,
      Rollback_Script_Path, Feature_Rollback_Order.
    - Repo_Name and Client_Name are left blank per specification.

.NOTES
    Actual Project Structure:
        <root>\
            workflow.sql\
                <Release_Version>\
                    <NNN_FeatureName>\
                        (any sub-folder depth, e.g. Internal\Deployment\Primary\)
                            *.sql
            Environments\
                <env>\
                    <env>.csv
                    <env>-config.json
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────
#  PATHS (relative to the script's own location)
# ─────────────────────────────────────────────────
$ProjectRoot = (Get-Location).Path
$WorkflowRoot = Join-Path $ProjectRoot "workflow.sql"
$EnvironmentsDir = Join-Path $ProjectRoot "Environments"

$RequiredHeaders = @(
    "Release_Version", "Application_Name", "Feature_Name", "Feature_Order",
    "Repo_Name", "Branch_Name", "SQL_Path", "Script_Type", "Execute_Script",
    "Environment", "Client_Name", "Script_order", "Prerequisites",
    "Rollback_Script_Path", "Feature_Rollback_Order", "Execution_Status",
    "Pipeline_Run_ID", "Executed_By", "Execution_Date", "Duration",
    "Validation_Query", "Expected_Result", "Actual_Result", "Rows_Affected",
    "Comments", "Error_Message"
)

# ─────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────
function Write-Info { param($Msg) Write-Host "[INFO]    $Msg" -ForegroundColor Cyan }
function Write-Ok { param($Msg) Write-Host "[OK]      $Msg" -ForegroundColor Green }
function Write-Warn { param($Msg) Write-Host "[WARNING] $Msg" -ForegroundColor Yellow }
function Write-Err { param($Msg) Write-Host "[ERROR]   $Msg" -ForegroundColor Red }
function Write-Section { param($Msg) Write-Host "`n$('─' * 65)`n  $Msg`n$('─' * 65)" -ForegroundColor Magenta }

# Convert an absolute path to a forward-slash path relative to $ProjectRoot
function Get-RelativePath {
    param([string]$AbsPath)
    return $AbsPath.Substring($ProjectRoot.Length).TrimStart('\', '/') -replace '\\', '/'
}

# ─────────────────────────────────────────────────
#  STEP 1 – Get Release_Version and validate
# ─────────────────────────────────────────────────
Write-Section "Step 1: Enter Release Version"

if (-not (Test-Path $WorkflowRoot)) {
    Write-Err "workflow.sql folder not found at: $WorkflowRoot"
    exit 1
}

$releaseVersion = (Read-Host "Enter the Release_Version (e.g., 1.0.0)").Trim()

if ([string]::IsNullOrWhiteSpace($releaseVersion)) {
    Write-Err "Release_Version cannot be empty."
    exit 1
}

$releasePath = Join-Path $WorkflowRoot $releaseVersion

if (-not (Test-Path $releasePath -PathType Container)) {
    Write-Err "No folder found for release '$releaseVersion' under '$WorkflowRoot'."
    Write-Err "There is no such folder to create the CSV file."

    # Show available folders so the user can pick the correct version
    $available = @(Get-ChildItem -Path $WorkflowRoot -Directory | Sort-Object Name)
    if ($available.Count -gt 0) {
        Write-Info "Available release folders:"
        $available | ForEach-Object { Write-Host "   * $($_.Name)" -ForegroundColor White }
    }
    else {
        Write-Warn "No release folders exist under '$WorkflowRoot'."
    }
    exit 1
}

Write-Ok "Exact match found: $releasePath"

$confirm = (Read-Host "Create/update the CSV file for release '$releaseVersion'? (Y/N)").Trim()
if ($confirm -notmatch '^[Yy]$') {
    Write-Info "Operation cancelled by user."
    exit 0
}

$branchName = "release/$releaseVersion"

# ─────────────────────────────────────────────────
#  STEP 3 – Get Environment from user
# ─────────────────────────────────────────────────
Write-Section "Step 3: Select Environment"

# Show available environments
if (Test-Path $EnvironmentsDir) {
    $envFolders = Get-ChildItem -Path $EnvironmentsDir -Directory | Sort-Object Name
    if ($envFolders.Count -gt 0) {
        Write-Info "Existing environment folders:"
        $envFolders | ForEach-Object { Write-Host "   * $($_.Name)" -ForegroundColor White }
    }
}

$environment = (Read-Host "Enter the Environment name (e.g., Dev / QA / UAT / PRD)").Trim().ToLower()

if ([string]::IsNullOrWhiteSpace($environment)) {
    Write-Err "Environment cannot be empty."
    exit 1
}

# CSV path: Environments\<env>\<env>.csv
$envDir = Join-Path $EnvironmentsDir $environment
$csvPath = Join-Path $envDir "$environment.csv"

# ─────────────────────────────────────────────────
#  STEP 4 – (skipped – all values are auto-derived)
# ─────────────────────────────────────────────────
# Application_Name  → derived from feature folder suffix (e.g. 001_student → student)
# Repo_Name         → left blank per specification
# Client_Name       → left blank per specification
# Branch_Name       → release/<releaseVersion>  (set after confirmation above)
$repoName = ""
$clientName = ""

# ─────────────────────────────────────────────────
#  STEP 5 – Validate feature sub-folders
# ─────────────────────────────────────────────────
Write-Section "Step 5: Validating Feature Folders"

$featureFolders = Get-ChildItem -Path $releasePath -Directory | Sort-Object Name

if ($featureFolders.Count -eq 0) {
    Write-Err "No feature sub-folders found under '$releasePath'."
    exit 1
}

$seenOrders = @{}
$validationErrors = @()

foreach ($folder in $featureFolders) {
    if ($folder.Name -notmatch '^(\d+)_') {
        $validationErrors += "Folder '$($folder.Name)' has no numeric prefix (e.g., 001_). Please rename it."
    }
    else {
        $numericPrefix = [int]$Matches[1]
        if ($seenOrders.ContainsKey($numericPrefix)) {
            $validationErrors += "Duplicate prefix '$numericPrefix' in '$($seenOrders[$numericPrefix])' and '$($folder.Name)'. Please rename one."
        }
        else {
            $seenOrders[$numericPrefix] = $folder.Name
        }
    }
}

if ($validationErrors.Count -gt 0) {
    Write-Err "Folder validation failed:"
    $validationErrors | ForEach-Object { Write-Err "  * $_" }
    exit 1
}

Write-Ok "All feature folders have valid unique numeric prefixes."
$featureFolders | ForEach-Object { Write-Info "  Found: $($_.Name)" }

# ─────────────────────────────────────────────────
#  STEP 6 – Load existing CSV (if any)
# ─────────────────────────────────────────────────
Write-Section "Step 6: Loading / Initialising CSV"

[System.Collections.Generic.List[PSCustomObject]] $existingRows =
[System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path $csvPath) {
    Write-Info "Existing CSV found: $csvPath"
    $rawRows = @(Import-Csv -Path $csvPath)

    if ($rawRows.Count -gt 0) {
        # Add any missing headers
        $existingCols = ($rawRows[0].PSObject.Properties).Name
        $missingHeaders = @($RequiredHeaders | Where-Object { $_ -notin $existingCols })
        if ($missingHeaders.Count -gt 0) {
            Write-Warn "Adding missing headers: $($missingHeaders -join ', ')"
            foreach ($row in $rawRows) {
                foreach ($h in $missingHeaders) {
                    $row | Add-Member -NotePropertyName $h -NotePropertyValue "" -Force
                }
            }
        }
        else {
            Write-Ok "All required headers present."
        }

        # Remove rows from a different release version
        $beforeCount = $rawRows.Count
        $rawRows = @($rawRows | Where-Object { $_.Release_Version -eq $releaseVersion })
        $removedCount = $beforeCount - $rawRows.Count
        if ($removedCount -gt 0) {
            Write-Warn "Removed $removedCount row(s) from a different release version."
        }

        if ($rawRows.Count -gt 0) {
            $existingRows.AddRange([PSCustomObject[]]$rawRows)
        }
    }

    Write-Ok "Loaded $($existingRows.Count) existing row(s) for release '$releaseVersion'."
}
else {
    Write-Info "No existing CSV found. A new file will be created at: $csvPath"
}

# ─────────────────────────────────────────────────
#  STEP 7 – Scan feature folders & build rows
# ─────────────────────────────────────────────────
Write-Section "Step 7: Scanning Feature Folders & Building CSV Rows"

[System.Collections.Generic.List[PSCustomObject]] $newRows =
[System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($featureFolder in $featureFolders) {

    $null = $featureFolder.Name -match '^(\d+)_(.+)$'
    $featureOrder = [int]$Matches[1]
    $folderSuffix = $Matches[2]          # e.g. "student" from "001_student"
    $applicationName = $folderSuffix        # Application_Name derived from folder suffix

    # Determine if this folder already has rows in the existing CSV
    # (match by checking whether any existing row's SQL_Path falls under this feature folder)
    $folderRelPrefix = (Get-RelativePath $featureFolder.FullName) -replace '\\', '/'
    $existingFeatureRows = @($existingRows | Where-Object {
            ($_.SQL_Path -replace '\\', '/') -like "$folderRelPrefix/*"
        })

    if ($existingFeatureRows.Count -gt 0) {
        # Folder already known – reuse its stored Feature_Name, no prompt needed
        $featureName = $existingFeatureRows[0].Feature_Name
        Write-Info "  '$($featureFolder.Name)' already in CSV – keeping Feature_Name: '$featureName'"
    }
    else {
        # New folder – ask the user once for a Feature_Name
        $featureNameInput = Read-Host "`nNew folder found: '$($featureFolder.Name)'. Enter Feature_Name (Enter to keep '$folderSuffix')"
        $featureName = if ([string]::IsNullOrWhiteSpace($featureNameInput)) { $folderSuffix } else { $featureNameInput.Trim() }
    }
 
    # ── Recursively collect ALL .sql files under this feature folder ─────
    $allSqlFiles = @(
        Get-ChildItem -Path $featureFolder.FullName -Filter "*.sql" -Recurse |
        Sort-Object { Get-RelativePath $_.FullName }
    )

    if ($allSqlFiles.Count -eq 0) {
        Write-Warn "No .sql files found under '$($featureFolder.Name)'. Skipping."
        continue
    }

    # Separate deployment scripts from rollback scripts by path segment
    # Convention: files whose path contains '\Rollback\' (case-insensitive) are rollback scripts
    $deploymentScripts = @($allSqlFiles | Where-Object { $_.FullName -notmatch '\\Rollback\\' })
    $rollbackScripts   = @($allSqlFiles | Where-Object { $_.FullName -match  '\\Rollback\\' })

    # If nothing is explicitly in a Rollback folder, treat files named *rollback* as rollback scripts
    if ($rollbackScripts.Count -eq 0) {
        $rollbackScripts   = @($allSqlFiles | Where-Object { $_.Name -match    'rollback' })
        $deploymentScripts = @($allSqlFiles | Where-Object { $_.Name -notmatch 'rollback' })
    }

    if ($rollbackScripts.Count -eq 0) {
        Write-Warn "No Rollback scripts found for '$($featureFolder.Name)'."
    }

    # ── Discover immediate sub-folders under this feature folder ─────────
    # Scripts are processed sub-folder by sub-folder in sorted order.
    # Within each sub-folder, Primary is processed before Secondary.
    # Script_Order is continuous within the feature folder (resets to 1
    # at the start of each new feature folder, not at each sub-folder).
    $immediateSubFolders = @(
        Get-ChildItem -Path $featureFolder.FullName -Directory | Sort-Object Name
    )

    # If there are no sub-folders, treat the feature folder itself as the only "sub-folder"
    $subFolderList = if ($immediateSubFolders.Count -gt 0) { $immediateSubFolders } else { @($featureFolder) }

    $totalDeploymentCount = 0
    $runningScriptOrder   = 0   # Resets to 0 at the start of each feature folder
    $groupOrder = @{ "Primary" = 1; "Secondary" = 2 }

    foreach ($subFolder in $subFolderList) {

        # Collect deployment scripts that live under this sub-folder
        $subDeployment = @($deploymentScripts | Where-Object { $_.FullName.StartsWith($subFolder.FullName) })

        if ($subDeployment.Count -eq 0) { continue }

        Write-Info "    Sub-folder '$($subFolder.Name)': $($subDeployment.Count) deployment script(s)"

        # Group scripts within this sub-folder by Primary / Secondary (or flat "")
        $groupedDeployment = @{}
        foreach ($script in $subDeployment) {
            $groupKey = ""
            if ($script.FullName -match '\\(Primary|Secondary)\\') {
                $groupKey = $Matches[1]
            }
            if (-not $groupedDeployment.ContainsKey($groupKey)) {
                $groupedDeployment[$groupKey] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
            $groupedDeployment[$groupKey].Add($script)
        }

        # Process Primary before Secondary within this sub-folder
        $sortedGroupKeys = @($groupedDeployment.Keys | Sort-Object {
                if ($groupOrder.ContainsKey($_)) { $groupOrder[$_] } else { 99 }
            }, { $_ })

        foreach ($groupKey in $sortedGroupKeys) {

            $groupScripts = @($groupedDeployment[$groupKey])
            $totalDeploymentCount += $groupScripts.Count

            if ($groupKey -ne "") {
                Write-Info "      Group '$groupKey' ($($groupScripts.Count) script(s))..."
            }

            # Rollback scripts for this group (same Primary/Secondary segment),
            # or fall back to all rollback scripts when not segmented.
            if ($groupKey -ne "") {
                $groupRollbacks = @($rollbackScripts | Where-Object { $_.FullName -match "\\$groupKey\\" })
                if ($groupRollbacks.Count -eq 0) { $groupRollbacks = @($rollbackScripts) }
            }
            else {
                $groupRollbacks = @($rollbackScripts)
            }

            # Rollback order: reverse sort (highest numeric prefix = order 1)
            [System.IO.FileInfo[]] $rollbackReversed = @($groupRollbacks | Sort-Object Name -Descending)

            # ── Build a row per deployment script ────────────────────────
            # Prerequisites chain is scoped to this group only.
            # Script_Order continues from the running counter of the feature folder.
            $previousSqlPath = $null

            foreach ($script in $groupScripts) {

                $relativeSqlPath = Get-RelativePath $script.FullName

                # Script_Order is continuous within the feature folder,
                # advancing through sub-folders and their Primary/Secondary groups.
                $runningScriptOrder++
                $scriptOrder = $runningScriptOrder

                # Prerequisite = immediately preceding script in this group only
                $prerequisite = if ($previousSqlPath) { $previousSqlPath } else { "" }

                # Match rollback script by numeric prefix of filename
                $rollbackScriptPath   = ""
                $featureRollbackOrder = ""

                if ($script.Name -match '^(\d+)') {
                    $pfx = $Matches[1]
                    $matchedRollback = $groupRollbacks | Where-Object { $_.Name -match "^$pfx" } | Select-Object -First 1

                    if ($matchedRollback) {
                        $rollbackScriptPath = Get-RelativePath $matchedRollback.FullName
                        $rbIdx = [array]::IndexOf($rollbackReversed, $matchedRollback)
                        $featureRollbackOrder = if ($rbIdx -ge 0) { $rbIdx + 1 } else { "" }
                    }
                }

                # Reuse an existing row if SQL_Path already exists (update auto fields, keep user fields)
                $existingRow = $existingRows |
                    Where-Object { $_.SQL_Path -eq $relativeSqlPath } |
                    Select-Object -First 1

                if ($existingRow) {
                    $existingRow.Feature_Order          = $featureOrder
                    $existingRow.Script_order           = $scriptOrder
                    $existingRow.Branch_Name            = $branchName
                    $existingRow.Prerequisites          = $prerequisite
                    $existingRow.Rollback_Script_Path   = $rollbackScriptPath
                    $existingRow.Feature_Rollback_Order = $featureRollbackOrder
                    $newRows.Add($existingRow)
                }
                else {
                    $row = [PSCustomObject]@{
                        Release_Version        = $releaseVersion
                        Application_Name       = $applicationName
                        Feature_Name           = $featureName
                        Feature_Order          = $featureOrder
                        Repo_Name              = $repoName
                        Branch_Name            = $branchName
                        SQL_Path               = $relativeSqlPath
                        Script_Type            = "DDL"
                        Execute_Script         = "No"
                        Environment            = $environment.ToUpper()
                        Client_Name            = $clientName
                        Script_order           = $scriptOrder
                        Prerequisites          = $prerequisite
                        Rollback_Script_Path   = $rollbackScriptPath
                        Feature_Rollback_Order = $featureRollbackOrder
                        Execution_Status       = ""
                        Pipeline_Run_ID        = ""
                        Executed_By            = ""
                        Execution_Date         = ""
                        Duration               = ""
                        Validation_Query       = ""
                        Expected_Result        = ""
                        Actual_Result          = ""
                        Rows_Affected          = ""
                        Comments               = ""
                        Error_Message          = ""
                    }
                    $newRows.Add($row)
                }

                $previousSqlPath = $relativeSqlPath
            }
        }
    }

    Write-Ok "Feature '$($featureFolder.Name)': $($totalDeploymentCount) deployment script(s), $($rollbackScripts.Count) rollback script(s)."
}

# ─────────────────────────────────────────────────
#  STEP 8 – Write CSV
# ─────────────────────────────────────────────────
Write-Section "Step 8: Writing CSV File"

if ($newRows.Count -eq 0) {
    Write-Warn "No rows generated. CSV will not be written."
    exit 0
}

# Ensure the environment sub-folder exists
if (-not (Test-Path $envDir)) {
    New-Item -ItemType Directory -Path $envDir | Out-Null
    Write-Ok "Created environment folder: $envDir"
}

$newRows | Select-Object $RequiredHeaders | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Ok "CSV saved : $csvPath"
Write-Ok "Rows written: $($newRows.Count)"

Write-Section "Complete"
Write-Host "Environment CSV generation finished successfully." -ForegroundColor Green

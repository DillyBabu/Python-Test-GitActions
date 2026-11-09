# Powershell Script for validating SQL Scripts before deployment

param(
    [parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory,
    
    [parameter(Mandatory = $false)]
    [string]$Environment = "",

    [parameter(Mandatory = $false)]
    [bool]$EnableAdvancedValidation = $true,

    [parameter(Mandatory = $false)]
    [string]$validationRulesPath = ""
)

function Write-StageHeader {
    param([string]$Message)
    Write-Host $Message
    Write-Host ('=' * ($Message.Length + 3))
}

function Test-Productionsafety {
    param(
        [string]$scriptPath,
        [string]$Content,
        [string]$Environment,
        [string]$scriptType
    )

    $dangerousOperations = @()

    # Critical Operations that should be blocked in Production
    if ($Environment -eq "PRD") {
        if ($Content -match "(?i)drop\s+database") {
            $dangerousOperations += "DROP DATABASE detected in PRDuction script"
        }

        if ($content -match "(?i)truncate\s+table") {
            $dangerousOperations += "TRUNCATE TABLE detected in PRDuction script"
        }

        if ($Content -match "(?i)drop\s+table" -and $scriptType -ne "ROLLBACK") {
            $dangerousOperations += "DROP TABLE detected in PRDuction script"     
        }

        if ($content -match "(?i)alter\s+database.*set\s+single_user") {
            $dangerousOperations += "SINGLE_USER mode detected in PRDuction script"         
        }

        if ($content -match "(?i)shutdown|dbcc\s+checkdb.*repair") {
            $dangerousOperations += "System-Level Operation detected in PRDuction Script"         
        }
    }

    # Operation that need review regardless of environment
    if ($content -match "(?i)sp_configure|xp_cmdshell") {
        $dangerousOperations += "System Configuration Change detected - requires DBA review."
    }

    if ($content -match "(?i)backup\s+database|restore\s+database") {
        $dangerousOperations += "Backup/Restore Operations detected - should be handled separately"
    }

    return $dangerousOperations
}

function Test-SQLSyntax {
    param(
        [string]$scriptPath,
        [string]$Content
    )

    $issues = @()

    #Basic SQL Syntax Checks
    if ($Content -match "(?i)select\s+\*\s+from" -and $Content -notmatch "(?i)where|top\s+\d+|limit\s+\d+") {
        $issues += "Potential performance issue: SELECT * without WHERE clause"
    }

    # Check for missing semi-colons in multi-statement scripts
    $statements = ($content -split "(?i)go\s*|;").Trim() | Where-Object { $_ -ne "" }
    if ($statements.Count -gt 1 ) {
        foreach ($statement in $statements) {
            if ($statement -match "(?i)insert|update|delete" -and $statement -notmatch ";$|(?i)go$") {
                $issues += "Missing semicolon or GO statement in multi-statement script"
                break
            }
        }
    }
    #Check for proper error handling in procedures
    if ($Content -match "(?i)create\s+(procedure|proc)" -and $Content -notmatch "(?i)begin\s+try|raiserror|throw") {
        $issues += "Stored Procedure or function found without proper error handling"
    }
    return $issues
}

function Test-ScriptComplexity {
    param(
        [string]$scriptType,
        [string]$Content
    )
    $warnings = @()
    $lineCount = ($Content -split "`n").Count

    #Check Script Size
    if ($lineCount -gt 500) {
        $warnings += "Script size exceeds 500 lines. Consider splitting the script."     
    }
    
    #Check for complex operations that might take long.
    if ($Content -match "(?i)create\s+index.*on.*\(" -and $Content -notmatch "(?i)with.*online.*=on") {
        $warnings += "Index Creation Without ONLINE option - may cause blocking."
    }

    if ($Content -match "(?i)alter\s+table.*add*.*constraint" -and $Content -notmatch "(?i)with\s+check|nocheck") {
        $warnings += "Constraint addition without WITH CHECK/NOCHECK speciifed"
    }

    #Check for batch operations
    if ($Content -match "(?i)insert.*select.*from" -and $Content -notmatch "(?i)top\s+\d+") {
        $warnings += "Large INSERT..SELECT operation without TOP clause - may cause blocking"
    }
    return $warnings
}

function Get-ScriptDependencies {
    param(
        [string]$Content,
        [array]$AllScripts
    )
    $dependencies = @()
    
    # Look for table references
    $tableMatches = [regex]::Matches($Content, "(?i)from\s+(\w+)|join\s+(\w+)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($match in $tableMatches) {
        # The regex has two alternations: Groups[1] captures FROM table, Groups[2] captures JOIN table
        # Only one will have a value per match
        $tableName = if ($match.Groups[1].Value) { $match.Groups[1].Value.Trim() } else { $match.Groups[2].Value.Trim() }
        if ($tableName -and $tableName -ne "") {
            # Check if this table is created by another script in the same deployment
            $dependentScript = $AllScripts | Where-Object {
                $_.'ScriptType' -eq 'DDL' -and
                (Get-Content $_.SQL_Path -ErrorAction SilentlyContinue -Raw ) -match "(?i)create\s+table\s+$tableName"
            }

            if ($dependentScript) {
                $dependencies += "Depends on table '$tableName' created by $($dependentScript.'SQL_Path')"
            }
        }
    }
    return $dependencies
}

# Main execution starts here
Write-StageHeader "Validating SQL Scripts"

# Validate input parameters
$executionPlanPath = Join-Path $ArtifactsDirectory "execution_plan.csv"

if (-not (Test-Path $executionPlanPath)) {
    Write-Error "Execution Plan not found: $executionPlanPath"
    Write-Host "Available files in artifacts directory:" -ForegroundColor Yellow
    Get-ChildItem $ArtifactsDirectory -ErrorAction SilentlyContinue | ForEach-Object { Write-Host " $($_.Name)" }
    exit 1
}

# Read Execution Plan
Write-Host "Reading execution plan: $executionPlanPath" -ForegroundColor White
try {
    $executionPlan = Import-csv $executionPlanPath
    Write-Host "Total execution plan rows: $($executionPlan.Count)" -ForegroundColor White
}
catch {
    Write-Error "Failed to read Execution Plan: $($_.Exception.Message)"
    exit 1
}

# Deduplicate: validate each unique SQL_Path only once.
# The execution plan may list the same script for multiple clients/databases;
# re-validating the same file is redundant.
$uniqueScripts = $executionPlan | Group-Object -Property SQL_Path | ForEach-Object {
    # Keep the first row per SQL_Path to carry metadata (Script_Type, Environment, etc.)
    $_.Group[0]
}
Write-Host "Unique scripts to validate: $($uniqueScripts.Count) (out of $($executionPlan.Count) plan rows)" -ForegroundColor White

# Initialize Validation Results
$validationResults = @()
$validationSuccess = $true
$criticalIssues = 0
$warningCount = 0

# Validate each unique script
foreach ($script in $uniqueScripts) {
    $scriptPath = $script.'SQL_Path'
    $scriptName = Split-Path $scriptPath -Leaf
    
    Write-Host "`nValidating: $scriptName" -ForegroundColor Blue
    Write-Host "Type: $($script.'Script_Type') | Environment: $($script.Environment)" -ForegroundColor Gray

    # Check if script file exists
    if (-not (Test-Path $scriptPath)) {
        Write-Host "Script File not found: $scriptPath" -ForegroundColor Red
        $validationResults += [PSCustomObject]@{
            ScriptPath       = $scriptPath
            ValidationStatus = "Failed"
            Issues           = @("File not Found")
            Warnings         = @()
            Dependencies     = @()
        }
        $criticalIssues++
        $validationSuccess = $false
        continue
    } 

    # Read Script Content
    try {
        $Content = Get-Content $scriptPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($Content)) {
            Write-Host "Script file is empty: $scriptPath" -ForegroundColor Yellow
            $warningCount++
        }
    }
    catch {
        Write-Host "Failed to read script: $($_.Exception.Message)" -ForegroundColor Red
        $validationResults += [PSCustomObject]@{
            ScriptPath       = $scriptPath
            ValidationStatus = "Failed"
            Issues           = @("Failed to read file: $($_.Exception.Message)")
            Warnings         = @()
            Dependencies     = @()
        }
        $criticalIssues++
        $validationSuccess = $false
        continue
    }

    # Perform Validation Checks
    $issues = @()
    $scriptWarnings = @()
    $dependencies = @()

    # PRDuction Safety Checks
    $dangerousOps = Test-Productionsafety -scriptPath $scriptPath -Content $Content -Environment $script.Environment -scriptType $script.'Script_Type'
    $issues += $dangerousOps

    if ($EnableAdvancedValidation) {
        #SQL syntax checks
        $syntaxIssues = Test-SQLSyntax -scriptPath $scriptPath -Content $Content
        $scriptWarnings += $syntaxIssues
    
        # Complexity Checks
        $complexityWarnings = Test-ScriptComplexity -Content $Content -scriptType $script.'Script_Type'
        $scriptWarnings += $complexityWarnings

        #Dependency Analysis
        $dependencies = Get-ScriptDependencies -Content $Content -AllScripts $uniqueScripts
    }

    # Determine Validation Status
    if ($issues.count -gt 0) {
        $Status = "Failed"
        $criticalIssues++
        $validationSuccess = $false
    }
    elseif ($scriptWarnings.Count -gt 0) {
        $Status = "Warning"
        $warningCount++
    }
    else {
        $Status = "Success"
    }

    # Log Results
    if ($Status -eq "Failed") {
        Write-Host "Validation Failed:" -ForegroundColor Red
        foreach ($issue in $issues) {
            Write-Host "$issue" -ForegroundColor Red
        }
    }
    elseif ($Status -eq "Warning") {
        Write-Host "Validation Passed with Warnings:" -ForegroundColor Yellow
        foreach ($scriptWarn in $scriptWarnings) {
            Write-Host "$scriptWarn" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Validation Successful" -ForegroundColor Green
    }

    if ($dependencies.Count -gt 0) {
        Write-Host "Dependencies found:" -ForegroundColor Cyan
        foreach ($dependency in $dependencies) {
            Write-Host "  $dependency" -ForegroundColor Cyan     
        }
    }

    # Store Results
    $validationResults += [PSCustomObject]@{
        ScriptPath       = $scriptPath
        ScriptType       = $script.'Script_Type'
        Environment      = $script.Environment
        Application_Name = $script.'Application_Name'
        Feature_Name     = $script.'Feature_Name'
        ValidationStatus = $Status
        Issues           = $issues
        Warnings         = $scriptWarnings
        Dependencies     = $dependencies
        FileSize         = if (Test-Path $scriptPath) { (Get-Item $scriptPath).Length } else { 0 }
        LineCount        = if ($Content) { ($Content -split "`n").Count } else { 0 }
    }
}

# Generate Validation Summary
Write-StageHeader "Validation Summary"

Write-Host "Overall Results:" -ForegroundColor White
Write-Host "Successful Validations: $(($validationResults | Where-Object {$_.ValidationStatus -eq 'Success'}).Count )" -ForegroundColor Green
Write-Host "Warnings: $warningCount" -ForegroundColor Yellow
Write-Host "Critical Issues: $criticalIssues" -ForegroundColor Red

if ($validationSuccess) {
    Write-Host "All critical validations passed-proceeding to deployment" -ForegroundColor Green
}
else {
    Write-Host " Critical validation issues found - deployment blocked" -ForegroundColor Red
    Write-Host "Scripts with Critical issues:" -ForegroundColor Red
    $failedScripts = $validationResults | Where-Object { $_.ValidationStatus -eq "Failed" }
    foreach ($failed in $failedScripts) {
        Write-Host "$($failed.ScriptPath)" -ForegroundColor Red
        foreach ($issue in $failed.Issues) {
            Write-Host "- $issue" -ForegroundColor Red
        }
    }
}

#Export Validation Results
$validationResultsPath = Join-Path $ArtifactsDirectory "validation-results.json"
$validationResults | ConvertTo-Json -Depth 3 | Out-File $validationResultsPath -Encoding utf8
Write-Host "Validation results exported to: $validationResultsPath" -ForegroundColor Cyan

# Create CSV summary 
$csvPath = Join-Path $ArtifactsDirectory "validation-summary.csv"
$validationResults | Select-Object ScriptPath, ScriptType, Environment, Application_Name, Feature_Name, ValidationStatus,
@{Name = 'IssueCount'; Expression = { $_.Issues.Count } },
@{Name = 'WarningCount'; Expression = { $_.Warnings.Count } },
FileSize, LineCount |
Export-Csv $csvPath -NoTypeInformation

Write-Host "Validation Summary exported to: $csvPath" -ForegroundColor Cyan

# Set Pipeline Variables
if ($validationSuccess) {
    Write-Host "##vso[task.setvariable variable=validationStatus;isOutput=true]Success"
    Write-Host "##vso[task.setvariable variable=criticalIssues;isOutput=true]0"
}
else {
    Write-Host "##vso[task.setvariable variable=validationStatus;isOutput=true]Failed"
    Write-Host "##vso[task.setvariable variable=criticalIssues;isOutput=true]$criticalIssues"
}

Write-Host "##vso[task.setvariable variable=warningCount;isOutput=true]$warningCount"

#Exit with appropriate code
if ($validationSuccess) {
    Write-Host "SQL Script Validation Completed successfully" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "SQL Script Validation Failed" -ForegroundColor Red
    exit 1
}
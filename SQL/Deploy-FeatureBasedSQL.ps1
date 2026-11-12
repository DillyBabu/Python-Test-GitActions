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
    [ValidateSet("AtomicFeature", "Progressive", "CascadingApplication")]
    [string]$RollbackStrategy = "Progressive",

    [parameter(Mandatory = $false)]
    [string]$ApplicationFilter = 'all',

    # 'all' or a comma-separated list of feature names, e.g. "FeatureA,FeatureB"
    [parameter(Mandatory = $false)]
    [string]$FeatureFilter = 'all',

    [parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory,

    # StopOnFirstClientFailure : the first failed script stops the feature and applies RollbackStrategy
    # ContinueOnClientFailure  : a failed script only stops the remaining scripts of that client in that
    #                            feature; other clients and the next features continue
    [parameter(Mandatory = $false)]
    [ValidateSet("StopOnFirstClientFailure", "ContinueOnClientFailure")]
    [string]$ClientResilienceMode = "StopOnFirstClientFailure"
)

# Import required modules and functions
Add-Type -AssemblyName System.Data

# Global variables for tracking deployment state
$Global:DeploymentResults = @()
$Global:FailedFeatures = @()
$Global:ExecutionStartTime = Get-Date

# Result columns added to every execution plan row so the results CSV and the HTML report
# show where and how each script ran. Every row gets every column because Export-Csv
# takes its headers from the first row.
$Global:ResultFieldDefaults = [ordered]@{
    Script_Name        = ""
    Actual_Server      = ""
    Actual_Database    = ""
    Batches_Executed   = 0
    Total_Batches      = 0
    Failed_Batch       = ""
    Transaction_Status = ""
    Start_Time         = ""
    End_Time           = ""
}

function Initialize-ResultFields {
    param([object]$Row)

    foreach ($field in $Global:ResultFieldDefaults.Keys) {
        if ($Row.PSObject.Properties.Name -notcontains $field) {
            $Row | Add-Member -NotePropertyName $field -NotePropertyValue $Global:ResultFieldDefaults[$field]
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Row.SQL_Path)) {
        $Row.Script_Name = Split-Path -Path $Row.SQL_Path -Leaf
    }

    # Rows still Pending after the deployment loop were never executed
    $Row.Execution_Status = "Pending"
}

function Write-StageHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ('=' * ($Message.Length + 3)) -ForegroundColor Cyan
}

function Write-ScriptExecution {
    param(
        [string]$Message,
        [string]$Status = "Info"
    )
    switch ($Status) {
        "Success" { Write-Host "[+] $Message" -ForegroundColor Green }
        "Failed" { Write-Host "[-] $Message" -ForegroundColor Red }
        "Warning" { Write-Host "[!] $Message" -ForegroundColor Yellow }
        "Info" { Write-Host "[*] $Message" }
        "Validation" { Write-Host "[?] $Message" -ForegroundColor Cyan }
        "Rollback" { Write-Host "[R] $Message" -ForegroundColor Magenta }
    }
}

function Undo-SqlTransaction {
    param([System.Data.SqlClient.SqlTransaction]$Transaction)

    # Connection is null once the transaction has ended on the server, e.g. after a severe
    # error or a COMMIT/ROLLBACK issued by the script itself. There is nothing left to roll back.
    if ($null -eq $Transaction.Connection) {
        Write-Host "##[warning]The transaction was already ended by SQL Server (severe error, or COMMIT/ROLLBACK inside the script). Verify the database state manually."
        return "EndedByServer"
    }

    try {
        $Transaction.Rollback()
        return "RolledBack"
    }
    catch {
        Write-Host "##[error]Transaction rollback failed: $($_.Exception.Message)"
        return "RollbackFailed"
    }
}

function Invoke-SQLScript {
    param(
        [string]$ScriptPath,
        [string]$ConnectionString,
        [string]$DatabaseName,
        [int]$TimeoutSeconds = 0
    )

    $result = @{
        Success           = $false
        ExecutionTime     = 0
        RowsAffected      = 0
        BatchesExecuted   = 0
        TotalBatches      = 0
        FailedBatch       = $null
        ErrorMessage      = $null
        Output            = $null
        ErrorType         = $null
        ActualServer      = $null
        ActualDatabase    = $null
        TransactionStatus = "NotStarted"
        StartTime         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        EndTime           = $null
    }

    $connection = $null
    $transaction = $null
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $scriptName = Split-Path -Path $ScriptPath -Leaf
    $batchFailed = $false

    try {
        # Validate script file exists
        if (-Not (Test-Path -Path $ScriptPath)) {
            throw "SQL script file not found: $ScriptPath"
        }

        $ScriptContent = Get-Content -Path $ScriptPath -Raw

        if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
            throw "SQL script file is empty: $ScriptPath"
        }

        # Validate connection string has database
        if ($ConnectionString -notmatch "(?i)(database|initial\s+catalog)") {
            throw "Connection string does not specify a database. Aborting for safety."
        }

        # Remove UTF-8 BOM if present
        $ScriptContent = $ScriptContent.TrimStart([char]0xFEFF)

        # All batches of a script run in one transaction, so a failed batch rolls back the whole script.
        # Scripts with statements SQL Server does not allow inside a transaction
        # (e.g. ALTER DATABASE, CREATE DATABASE, BACKUP, full-text catalogs) can opt out
        # with a line containing:  -- @NoTransaction
        $useTransaction = $ScriptContent -notmatch '(?im)^\s*--\s*@NoTransaction\b'

        # Split into batches on GO statement
        $batches = $ScriptContent -split "(?im)^\s*GO\s*$"
        $batches = @($batches | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $result.TotalBatches = $batches.Count
        Write-Host ""
        Write-Host "================="
        Write-Host "Executing SQL Script: $scriptName"
        Write-Host "Database: $DatabaseName"
        Write-Host "Total Batches: $($batches.Count)"
        if ($useTransaction) {
            Write-Host "Transaction Mode: Single transaction (all batches commit or roll back together)"
        }
        else {
            Write-Host "Transaction Mode: None (-- @NoTransaction) - each batch commits on its own"
        }
        Write-Host "================="

        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
            $connection.Open()
            $result.ActualServer = $connection.DataSource
            Write-Host "Connected to SQL Server: $($connection.DataSource)" -ForegroundColor Green

            # One connection string can serve several databases of a client on the same server,
            # so switch explicitly to the database of this execution plan row
            if ($connection.Database -ne $DatabaseName) {
                Write-Host "Switching database: $($connection.Database) -> $DatabaseName"
                $connection.ChangeDatabase($DatabaseName)
            }
            $result.ActualDatabase = $connection.Database
            Write-Host "Target database: $($connection.Database)" -ForegroundColor Green
        }
        catch [System.Data.SqlClient.SqlException] {
            $sqlException = $_.Exception
            $result.Success = $false
            $result.ErrorType = "SQL Login failure"
            $result.ErrorMessage = "SQL Login failed: $($sqlException.Message)"

            Write-Host ""
            Write-Host "=================="
            Write-host "##[error] SQL Server connection failed."
            Write-Host "=================="
            Write-Host "Database: $DatabaseName connection failed." -ForegroundColor Red
            Write-Host "Error: $($sqlException.Message)" -ForegroundColor Red

            foreach ($sqlError in $sqlException.Errors) {
                Write-Host "Error Number: $($sqlError.Number)" -ForegroundColor Red
                Write-Host "Error State: $($sqlError.State)" -ForegroundColor Red
                Write-Host "Error Message: $($sqlError.Message)" -ForegroundColor Red
                Write-Host "Error Class: $($sqlError.Class)" -ForegroundColor Red
            }

            Write-Host "=================="
            return $result
        }

        if ($useTransaction) {
            $transaction = $connection.BeginTransaction()
            $result.TransactionStatus = "Open"
            Write-Host "Transaction started."
        }
        else {
            $result.TransactionStatus = "NotUsed"
            Write-Host "##[warning]Script is marked -- @NoTransaction. Batches that complete before a failure cannot be rolled back automatically."
        }

        $totalRowsAffected = 0
        $batchNumber = 0

        foreach ($batch in $batches) {
            $batchNumber++

            $batchStartTime = Get-Date
            $batchStopWatch = [System.Diagnostics.Stopwatch]::StartNew()

            Write-Host ""
            Write-Host "--------------------------------"
            Write-Host "Executing Batch $batchNumber of $($batches.Count)"
            Write-host "Started: $($batchStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
            Write-host "--------------------------------"

            $command = $null
            try {
                $command = $connection.CreateCommand()
                if ($transaction) {
                    $command.Transaction = $transaction
                }
                $command.CommandText = $batch.Trim()
                $command.CommandTimeout = $TimeoutSeconds

                $rows = $command.ExecuteNonQuery()
                $batchStopWatch.Stop()
                $batchDuration = [math]::Round($batchStopWatch.Elapsed.TotalSeconds, 2)

                if ($rows -ge 0) {
                    $totalRowsAffected += $rows
                }

                $result.BatchesExecuted++

                Write-Host "##[Section]Batch $batchNumber executed successfully."
                Write-Host "Status: Success"
                Write-Host "Rows affected: $rows"
                Write-Host "Duration: $batchDuration seconds"
            }
            catch [System.Data.SqlClient.SqlException] {
                $batchStopWatch.Stop()
                $batchDuration = [math]::Round($batchStopWatch.Elapsed.TotalSeconds, 2)
                $batchFailed = $true

                $result.FailedBatch = $batchNumber
                $result.ErrorType = "SQL Script failure"
                $result.ErrorMessage = "Batch $batchNumber execution failed: $($_.Exception.Message)"

                Write-Host ""
                Write-Host "--------------------------------"
                Write-Host "Batch $batchNumber execution failed."
                Write-Host "Script: $scriptName"
                Write-Host "Database: $DatabaseName"
                Write-Host "Batch: $batchNumber of $($batches.Count)"
                Write-Host "Duration: $batchDuration seconds"
                Write-Host "--------------------------------"

                Foreach ($sqlError in $_.Exception.Errors) {
                    Write-Host "Error Number: $($sqlError.Number)" -ForegroundColor Red
                    Write-Host "Error State: $($sqlError.State)" -ForegroundColor Red
                    Write-Host "Error Message: $($sqlError.Message)" -ForegroundColor Red
                    Write-Host "Error Class: $($sqlError.Class)" -ForegroundColor Red
                }
                break
            }
            finally {
                if ($command) {
                    $command.Dispose()
                }
            }
        }

        $result.RowsAffected = $totalRowsAffected

        if ($batchFailed) {
            if ($transaction) {
                Write-Host ""
                Write-Host "##[error]Batch $($result.FailedBatch) of $($result.TotalBatches) failed. Rolling back the entire script $scriptName ($($result.BatchesExecuted) batch(es) had already executed)."
                $result.TransactionStatus = Undo-SqlTransaction -Transaction $transaction

                if ($result.TransactionStatus -eq "RolledBack") {
                    Write-Host "Rollback complete. No changes from $scriptName were committed to $($result.ActualDatabase)." -ForegroundColor Yellow
                }
            }
            elseif ($result.BatchesExecuted -gt 0) {
                $result.TransactionStatus = "PartiallyApplied"
                Write-Host "##[warning]$($result.BatchesExecuted) batch(es) of $scriptName were committed before the failure and remain applied."
            }

            $result.Success = $false
            $result.Output = "Script execution failed at batch $($result.FailedBatch) of $($result.TotalBatches). Transaction: $($result.TransactionStatus). Error: $($result.ErrorMessage)"
        }
        else {
            if ($transaction) {
                $transaction.Commit()
                $result.TransactionStatus = "Committed"
                Write-Host "Transaction committed." -ForegroundColor Green
            }

            $result.Success = $true
            $result.Output = "Script executed successfully. Batches executed: $($result.BatchesExecuted) of $($result.TotalBatches). Rows affected: $totalRowsAffected"
        }

    }
    catch {
        $result.Success = $false

        if (-not $result.ErrorMessage) {
            $result.ErrorMessage = $_.Exception.Message
        }

        # Any unexpected error (including a failed Commit) must not leave the transaction open
        if ($transaction -and $result.TransactionStatus -eq "Open") {
            Write-Host "##[error]Unexpected error while executing $scriptName. Rolling back the entire script."
            $result.TransactionStatus = Undo-SqlTransaction -Transaction $transaction
        }

        $result.Output = "Script execution failed: $($result.ErrorMessage)"
        Write-Verbose "SQL script execution failed."
        Write-Verbose $_.Exception.Message
    }
    finally {
        $stopWatch.Stop()
        $result.ExecutionTime = [math]::Round($stopWatch.Elapsed.TotalSeconds, 2)
        $result.EndTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if ($transaction) {
            $transaction.Dispose()
        }

        if ($connection) {
            if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
                $connection.Close()
            }
            $connection.Dispose()
        }
    }
    return $result
}
function Test-ValidationQuery {
    param(
        [string]$ValidationQuery,
        [string]$ExpectedResult,
        [string]$ConnectionString,
        [string]$DatabaseName
    )

    if ([string]::IsNullOrWhiteSpace($ValidationQuery)) {
        return @{Success = $true; Message = "No validation query provided" }
    }

    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
        $connection.Open()

        try {
            # Load validation query content if it's a file path
            $queryContent = $ValidationQuery
            if (Test-Path $ValidationQuery -ErrorAction SilentlyContinue) {
                $queryContent = Get-Content $ValidationQuery -Raw
            }

            # Add USE statement if needed
            if ($queryContent -notmatch "(?i)^\s*USE\s+\[$DatabaseName\]" -and $queryContent -notmatch "(?i)^\s*USE\s+$DatabaseName") {
                $queryContent = "USE [$DatabaseName];`n" + $queryContent
            }

            $command = $connection.CreateCommand()
            $command.CommandText = $queryContent
            $command.CommandTimeout = 60

            $actualResult = $command.ExecuteScalar()

            if ($null -eq $actualResult -and [string]::IsNullOrWhiteSpace($ExpectedResult)) {
                return @{ Success = $true; Message = "Validation query passed (NULL result as expected)" }
            }

            if ($actualResult -eq $ExpectedResult -or $actualResult.ToString() -eq $ExpectedResult) {
                return @{ Success = $true; Message = "Validation query passed. Result: $actualResult" }
            }
            else {
                return @{ Success = $false; Message = "Validation query failed. Expected: $ExpectedResult, Actual: $actualResult" }
            }
        }
        catch {
            return @{ Success = $false; Message = "Validation query execution failed: $($_.Exception.Message)" }
        }
        finally {
            $connection.Close()
            $connection.Dispose()
        }
    }
    catch {
        return @{ Success = $false; Message = "Validation query failed: $($_.Exception.Message)" }
    }
}

function Invoke-FeatureRollback {
    param(
        [array]$FeatureScripts,
        [string]$ApplicationName,
        [string]$FeatureName
    )

    Write-ScriptExecution "Invoking rollback for Feature: $ApplicationName.$FeatureName" "Rollback"

    # Sort scripts by rollback order (highest first)
    $rollbackScripts = $FeatureScripts | Where-Object {
        $_.Execution_Status -eq "Success" -and
        -not [string]::IsNullOrWhiteSpace($_.Rollback_script_path)
    } | Sort-Object { [int]$_.'Feature_Rollback_order' } -Descending

    $rollbackSuccess = $true

    foreach ($script in $rollbackScripts) {
        $rollbackPath = $script.Rollback_script_path

        if (Test-Path $rollbackPath) {
            Write-ScriptExecution "Executing rollback: $rollbackPath" "Info"

            # Get connection string from environment variable
            $connVarName = $script.ConnectionStringVar
            $connectionString = (Get-ChildItem Env:$connVarName -ErrorAction SilentlyContinue).Value

            if (-not $connectionString) {
                Write-ScriptExecution "Connection string variable '$connVarName' not set for rollback" "Failed"
                $rollbackSuccess = $false
                break
            }

            $rollbackResult = Invoke-SQLScript -ScriptPath $rollbackPath `
                -ConnectionString $connectionString `
                -DatabaseName $script.Database_Name `
                -TimeoutSeconds 0

            if ($rollbackResult.Success) {
                Write-ScriptExecution "Rollback completed successfully" "Success"
                $script.Execution_Status = "Rollback Success"
            }
            else {
                Write-ScriptExecution "Rollback failed: $($rollbackResult.ErrorMessage)" "Failed"
                $script.Execution_Status = "Rollback Failed"
                $script.Error_Message = "Rollback failed: $($rollbackResult.ErrorMessage)"
                $rollbackSuccess = $false
                break
            }
        }
        else {
            Write-ScriptExecution "Rollback script not found: $rollbackPath" "Warning"
            $rollbackSuccess = $false
            break
        }
    }

    if (-not $rollbackSuccess) {
        Write-ScriptExecution "Rollback failed for feature: $ApplicationName.$FeatureName" "Failed"
    }

    return $rollbackSuccess
}

function Execute-ScriptWithValidation {
    param(
        [object]$Script,
        [string]$ConnectionString
    )

    $scriptPath = $Script.SQL_Path
    $scriptName = Split-Path $scriptPath -Leaf
    $databaseName = $Script.Database_Name
    $serverName = $Script.Server_Name

    Write-ScriptExecution "Executing: $scriptName on $serverName.$databaseName" "Info"

    # Validate required fields
    if (-not $scriptPath) {
        Write-ScriptExecution "Script Path is empty. Cannot execute." "Failed"
        $Script.Execution_Status = "Failed"
        $Script.Error_Message = "Script path is empty"
        return $false
    }

    if (-not $databaseName) {
        Write-ScriptExecution "Database name is empty. Cannot execute." "Failed"
        $Script.Execution_Status = "Failed"
        $Script.Error_Message = "Database name is empty"
        return $false
    }

    if (-not $ConnectionString) {
        Write-ScriptExecution "Connection string is empty. Cannot execute." "Failed"
        $Script.Execution_Status = "Failed"
        $Script.Error_Message = "Connection string is empty"
        return $false
    }

    # Execute the script
    $executionResult = Invoke-SQLScript -ScriptPath $scriptPath `
        -ConnectionString $ConnectionString `
        -DatabaseName $databaseName `
        -TimeoutSeconds 0

    # Update script object with execution details
    $Script.Execution_Status = if ($executionResult.Success) { "Success" } else { "Failed" }
    $Script.Duration = $executionResult.ExecutionTime
    $Script.Rows_Affected = $executionResult.RowsAffected
    $Script.Error_Message = if ($executionResult.Success) { "" } else { $executionResult.ErrorMessage }
    $Script.Execution_Date = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Script.Executed_by = [System.Environment]::UserName
    $Script.Actual_Server = $executionResult.ActualServer
    $Script.Actual_Database = $executionResult.ActualDatabase
    $Script.Batches_Executed = $executionResult.BatchesExecuted
    $Script.Total_Batches = $executionResult.TotalBatches
    $Script.Failed_Batch = $executionResult.FailedBatch
    $Script.Transaction_Status = $executionResult.TransactionStatus
    $Script.Start_Time = $executionResult.StartTime
    $Script.End_Time = $executionResult.EndTime

    if ($executionResult.Success) {
        Write-ScriptExecution "Script execution completed successfully" "Success"

        # Run validation query if specified
        if (-not [string]::IsNullOrWhiteSpace($Script.Validation_Query)) {
            Write-ScriptExecution "Running validation query..." "Validation"
            $validationResult = Test-ValidationQuery -ValidationQuery $Script.Validation_Query `
                -ExpectedResult $Script.Expected_Result `
                -ConnectionString $ConnectionString `
                -DatabaseName $databaseName

            if ($validationResult.Success) {
                Write-ScriptExecution "Validation passed" "Success"
                $Script.Actual_Result = $Script.Expected_Result
            }
            else {
                Write-ScriptExecution "Validation failed: $($validationResult.Message)" "Failed"
                $Script.Execution_Status = "Failed"
                $Script.Error_Message = "Validation: $($validationResult.Message)"
                $Script.Actual_Result = "Failed"
            }
        }
    }
    else {
        Write-ScriptExecution "Script execution failed: $($executionResult.ErrorMessage)" "Failed"
    }

    # Add to global results tracking
    $Global:DeploymentResults += $Script

    return $executionResult.Success
}

function Set-SkippedStatus {
    param(
        [object]$Script,
        [string]$Reason
    )

    $Script.Execution_Status = "Skipped"
    $Script.Error_Message = $Reason
    $Script.Execution_Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Global:DeploymentResults += $Script
}

# A deployment target is one server/database. Failures are tracked per target, so one failing
# database of a group entry (e.g. WorkflowSecondaryServer) does not block its other databases.
function Get-TargetKey {
    param([object]$Script)
    return "$($Script.Server_Name)|$($Script.Database_Name)".ToLowerInvariant()
}

function Get-TargetLabel {
    param([object]$Script)
    return "client '$($Script.Client_Name)' ($($Script.Server_Name).$($Script.Database_Name))"
}

function Invoke-RollbackByFeature {
    param(
        [array]$Scripts,
        [string]$ApplicationName
    )

    # Roll back the latest feature first; Invoke-FeatureRollback orders the scripts inside a feature
    $featureGroups = @($Scripts | Group-Object -Property Feature_Name |
        Sort-Object -Property @{ Expression = { [int]$_.Group[0].Feature_Order } } -Descending)

    $allRolledBack = $true
    foreach ($featureGroup in $featureGroups) {
        $rolledBack = Invoke-FeatureRollback -FeatureScripts $featureGroup.Group `
            -ApplicationName $ApplicationName `
            -FeatureName $featureGroup.Name
        if (-not $rolledBack) { $allRolledBack = $false }
    }
    return $allRolledBack
}

function Execute-Feature {
    param(
        [array]$FeatureScripts,
        [string]$ApplicationName,
        [string]$FeatureName
    )

    Write-StageHeader "Feature: $ApplicationName > $FeatureName (Feature_Order $($FeatureScripts[0].Feature_Order), $($FeatureScripts.Count) script row(s))"

    $continueOnClientFailure = $ClientResilienceMode -eq "ContinueOnClientFailure"
    $featureSuccess = $true
    $featureFailedScripts = @()
    $featureFailedTargets = @()
    $featureSkippedTargets = @()
    $stopFeature = $false

    # Execution order inside a feature:
    #   1. Targets (server/database) ordered by Client_Name, then Server_Name / Database_Name
    #   2. Every script of a target runs in ascending Script_Order before the next target starts
    $targetGroups = @($FeatureScripts | Group-Object -Property { Get-TargetKey -Script $_ } | Sort-Object -Property `
        @{ Expression = { @($_.Group | Sort-Object -Property Client_Name)[0].Client_Name } },
        @{ Expression = { $_.Group[0].Server_Name } },
        @{ Expression = { $_.Group[0].Database_Name } })

    foreach ($targetGroup in $targetGroups) {
        $targetKey = $targetGroup.Name
        $targetScripts = @($targetGroup.Group | Sort-Object -Property @{ Expression = { [int]$_.Script_Order } }, Client_Name)
        $targetLabel = Get-TargetLabel -Script $targetScripts[0]

        Write-Host ""
        Write-ScriptExecution "Target: $targetLabel - $($targetScripts.Count) script(s)" "Info"

        # ContinueOnClientFailure: a target that failed in an earlier feature is not deployed again,
        # because later features usually depend on the earlier ones
        if ($continueOnClientFailure -and $Global:FailedTargets.ContainsKey($targetKey)) {
            $earlierFeature = $Global:FailedTargets[$targetKey]
            foreach ($script in $targetScripts) {
                Write-ScriptExecution "[SKIPPED] '$($script.Script_Name)' (Script_Order $($script.Script_Order)) for $targetLabel - it failed in earlier feature '$earlierFeature'" "Warning"
                Set-SkippedStatus -Script $script -Reason "Skipped: $targetLabel failed in earlier feature '$earlierFeature'"
            }
            $featureSuccess = $false
            $featureSkippedTargets += $targetLabel
            continue
        }

        $targetFailed = $false

        foreach ($script in $targetScripts) {
            # ContinueOnClientFailure: skip the rest of this feature for a target that already failed
            if ($targetFailed) {
                Write-ScriptExecution "[SKIPPED] '$($script.Script_Name)' (Script_Order $($script.Script_Order)) for $targetLabel - an earlier script failed in this feature" "Warning"
                Set-SkippedStatus -Script $script -Reason "Skipped: an earlier script failed for $targetLabel in feature '$FeatureName'"
                continue
            }

            # Get connection string from environment variable
            $connVarName = $script.ConnectionStringVar
            $connectionString = (Get-ChildItem Env:$connVarName -ErrorAction SilentlyContinue).Value

            if (-not $connectionString) {
                Write-ScriptExecution "Connection string variable '$connVarName' not set for $($script.SQL_Path)" "Failed"
                $script.Execution_Status = "Failed"
                $script.Error_Message = "Connection string variable '$connVarName' not found"
                $script.Execution_Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $Global:DeploymentResults += $script
                $scriptSuccess = $false
            }
            else {
                $scriptSuccess = Execute-ScriptWithValidation -Script $script -ConnectionString $connectionString
            }

            if ($scriptSuccess) {
                continue
            }

            $featureSuccess = $false
            $featureFailedScripts += $script

            if ($continueOnClientFailure) {
                $targetFailed = $true
                Write-ScriptExecution "ContinueOnClientFailure - $targetLabel failed on '$($script.Script_Name)'. Its remaining scripts are skipped; continuing with the next client." "Warning"
                continue
            }

            # StopOnFirstClientFailure: apply the configured rollback strategy and stop this feature
            switch ($RollbackStrategy) {
                'AtomicFeature' {
                    Write-ScriptExecution "AtomicFeature rollback triggered for all clients of feature '$FeatureName'" "Rollback"
                    $null = Invoke-FeatureRollback -FeatureScripts $FeatureScripts -ApplicationName $ApplicationName -FeatureName $FeatureName
                }
                'Progressive' {
                    Write-ScriptExecution "Progressive strategy - keeping completed scripts, stopping this feature" "Warning"
                }
                'CascadingApplication' {
                    Write-ScriptExecution "CascadingApplication rollback will be applied to application '$ApplicationName'" "Rollback"
                }
            }
            $stopFeature = $true
            break
        }

        if ($stopFeature) {
            break
        }

        if (-not $targetFailed) {
            continue
        }

        # ContinueOnClientFailure: remember the failure for later features and roll back ONLY this target
        $featureFailedTargets += $targetLabel
        $Global:FailedTargets[$targetKey] = $FeatureName

        switch ($RollbackStrategy) {
            'AtomicFeature' {
                Write-ScriptExecution "AtomicFeature rollback for $targetLabel in feature '$FeatureName' (other clients are not affected)" "Rollback"
                $null = Invoke-FeatureRollback -FeatureScripts $targetScripts -ApplicationName $ApplicationName -FeatureName $FeatureName
            }
            'CascadingApplication' {
                Write-ScriptExecution "CascadingApplication rollback for $targetLabel across application '$ApplicationName' (other clients are not affected)" "Rollback"
                $targetAppScripts = @($Global:DeploymentResults | Where-Object {
                        $_.Application_Name -eq $ApplicationName -and (Get-TargetKey -Script $_) -eq $targetKey
                    })
                $null = Invoke-RollbackByFeature -Scripts $targetAppScripts -ApplicationName $ApplicationName
            }
            'Progressive' {
                Write-ScriptExecution "Progressive strategy - completed scripts of $targetLabel stay applied" "Warning"
            }
        }
    }

    if (-not $featureSuccess) {
        $Global:FailedFeatures += @{
            ApplicationName = $ApplicationName
            FeatureName     = $FeatureName
            FailedScripts   = $featureFailedScripts
            FailedTargets   = $featureFailedTargets
            SkippedTargets  = $featureSkippedTargets
        }
    }

    if ($featureFailedTargets.Count -gt 0) {
        Write-ScriptExecution "Failed in feature '$FeatureName': $($featureFailedTargets -join ', ')" "Warning"
    }
    if ($featureSkippedTargets.Count -gt 0) {
        Write-ScriptExecution "Skipped in feature '$FeatureName' (failed in an earlier feature): $($featureSkippedTargets -join ', ')" "Warning"
    }

    return $featureSuccess
}

# ============================================================================
# Main execution block
# ============================================================================

# Targets (server|database) that failed, with the feature they failed in (ContinueOnClientFailure)
$Global:FailedTargets = @{}

Write-StageHeader "Feature-Based SQL Deployment"
Write-Host "Environment            : $Environment"
Write-Host "Release Version        : $ReleaseVersion"
Write-Host "Application Filter     : $ApplicationFilter"
Write-Host "Feature Filter         : $FeatureFilter"
Write-Host "Rollback Strategy      : $RollbackStrategy"
Write-Host "Client Resilience Mode : $ClientResilienceMode"

if ($ClientResilienceMode -eq "ContinueOnClientFailure") {
    Write-Host "A failed client database skips its remaining scripts and later features; '$RollbackStrategy' rollback applies only to that database. Other clients continue."
}

if (-not (Test-Path -Path $ArtifactsDirectory)) {
    New-Item -ItemType Directory -Path $ArtifactsDirectory -Force | Out-Null
}

# Read the execution plan produced by Parse_FeatureChecklist.ps1.
# The pipeline downloads the ExecutionPlan artifact into the working directory, so look there
# as well as in the artifacts directory.
$candidatePaths = @(
    (Join-Path $ArtifactsDirectory "execution_plan.csv"),
    (Join-Path (Get-Location).Path "execution_plan.csv")
) | Select-Object -Unique

try {
    $executionPlanPath = $candidatePaths | Where-Object { Test-Path -Path $_ } | Select-Object -First 1
    if (-not $executionPlanPath) {
        throw "execution_plan.csv not found. Searched: $($candidatePaths -join '; ')"
    }

    Write-Host "Reading execution plan from $executionPlanPath"
    $allScripts = @(Import-Csv -Path $executionPlanPath)
    Write-Host "Found $($allScripts.Count) execution plan row(s)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to read execution plan: $($_.Exception.Message)"
    Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]false"
    exit 1
}

# Apply filters if specified
if ($ApplicationFilter -ne 'all') {
    $allScripts = @($allScripts | Where-Object { $_.Application_Name -eq $ApplicationFilter })
    Write-Host "Filtered to application '$ApplicationFilter': $($allScripts.Count) row(s)" -ForegroundColor Green
}

if ($FeatureFilter -ne 'all') {
    $featureList = @($FeatureFilter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $allScripts = @($allScripts | Where-Object { $featureList -contains $_.Feature_Name })
    Write-Host "Filtered to feature(s) '$($featureList -join ', ')': $($allScripts.Count) row(s)" -ForegroundColor Green
}

if ($allScripts.Count -eq 0) {
    Write-Error "No execution plan rows after applying filters"
    Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]false"
    exit 1
}

foreach ($row in $allScripts) {
    Initialize-ResultFields -Row $row
}

# Features run in ascending Feature_Order (ties broken by application and feature name)
$sortedFeatureGroups = @($allScripts | Group-Object -Property Application_Name, Feature_Name | Sort-Object -Property `
    @{ Expression = { [int]$_.Group[0].Feature_Order } },
    @{ Expression = { $_.Group[0].Application_Name } },
    @{ Expression = { $_.Group[0].Feature_Name } })

Write-Host ""
Write-Host "Deployment Summary:" -ForegroundColor Yellow
Write-Host "  Total Features: $($sortedFeatureGroups.Count)" -ForegroundColor Yellow
Write-Host "  Total Execution Rows: $($allScripts.Count)" -ForegroundColor Yellow
Write-Host "  Unique Clients: $(@($allScripts | Select-Object -ExpandProperty Client_Name -Unique).Count)" -ForegroundColor Yellow
Write-Host "  Unique Servers: $(@($allScripts | Select-Object -ExpandProperty Server_Name -Unique).Count)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Feature execution order:" -ForegroundColor Yellow
$position = 0
foreach ($featureGroup in $sortedFeatureGroups) {
    $position++
    $first = $featureGroup.Group[0]
    $clients = @($featureGroup.Group | Select-Object -ExpandProperty Client_Name -Unique | Sort-Object) -join ', '
    Write-Host "  $position. [Feature_Order $($first.Feature_Order)] $($first.Application_Name) > $($first.Feature_Name) - clients: $clients" -ForegroundColor Yellow
}

# Execute deployment
try {
    $deploymentSuccess = $true

    foreach ($featureGroup in $sortedFeatureGroups) {
        $applicationName = $featureGroup.Group[0].Application_Name
        $featureName = $featureGroup.Group[0].Feature_Name

        $featureSuccess = Execute-Feature -FeatureScripts $featureGroup.Group `
            -ApplicationName $applicationName `
            -FeatureName $featureName

        if ($featureSuccess) {
            continue
        }

        $deploymentSuccess = $false

        # ContinueOnClientFailure: a failed feature never stops the next features
        if ($ClientResilienceMode -eq "ContinueOnClientFailure") {
            Write-ScriptExecution "Feature '$featureName' completed with client failures - moving on to the next feature" "Warning"
            continue
        }

        # StopOnFirstClientFailure + CascadingApplication: roll back the whole application and stop
        if ($RollbackStrategy -eq 'CascadingApplication') {
            Write-ScriptExecution "Cascading rollback for application: $applicationName" "Rollback"
            $appScripts = @($Global:DeploymentResults | Where-Object { $_.Application_Name -eq $applicationName })
            $null = Invoke-RollbackByFeature -Scripts $appScripts -ApplicationName $applicationName
            break
        }
    }

    # Rows that were never executed (stopped by an earlier failure) are reported as Skipped
    foreach ($row in $allScripts) {
        if ($row.Execution_Status -eq "Pending") {
            $row.Execution_Status = "Skipped"
            $row.Error_Message = "Not executed: deployment stopped after an earlier failure ($ClientResilienceMode / $RollbackStrategy)"
        }
    }

    # Generate results
    Write-StageHeader "Deployment Results"

    $executionTime = [math]::Round(((Get-Date) - $Global:ExecutionStartTime).TotalSeconds, 2)
    $successfulScripts = @($allScripts | Where-Object { $_.Execution_Status -eq "Success" }).Count
    $failedScripts = @($allScripts | Where-Object { $_.Execution_Status -eq "Failed" -or $_.Execution_Status -eq "Rollback Failed" }).Count
    $rolledBackScripts = @($allScripts | Where-Object { $_.Execution_Status -eq "Rollback Success" }).Count
    $skippedScripts = @($allScripts | Where-Object { $_.Execution_Status -eq "Skipped" }).Count
    $totalScripts = $allScripts.Count

    Write-Host "Successful Scripts: $successfulScripts" -ForegroundColor Green
    Write-Host "Failed Scripts: $failedScripts" -ForegroundColor Red
    Write-Host "Rolled Back Scripts: $rolledBackScripts" -ForegroundColor Magenta
    Write-Host "Skipped Scripts: $skippedScripts" -ForegroundColor Yellow
    Write-Host "Total Scripts: $totalScripts" -ForegroundColor Yellow
    Write-Host "Execution Time: $executionTime seconds" -ForegroundColor Yellow

    # Results in the order they were deployed: Feature_Order > Client > Script_Order
    $orderedResults = @($allScripts | Sort-Object -Property `
        @{ Expression = { [int]$_.Feature_Order } }, Application_Name, Feature_Name,
        Client_Name, Server_Name, Database_Name, @{ Expression = { [int]$_.Script_Order } })

    Write-Host ""
    Write-Host "Execution Details:" -ForegroundColor Yellow
    $orderedResults | Format-Table -AutoSize -Property @(
        @{ Label = "Feature"; Expression = { "$($_.Feature_Order). $($_.Feature_Name)" } },
        @{ Label = "Client"; Expression = { $_.Client_Name } },
        @{ Label = "Server"; Expression = { $_.Server_Name } },
        @{ Label = "Database"; Expression = { $_.Database_Name } },
        @{ Label = "Order"; Expression = { $_.Script_Order } },
        @{ Label = "Script"; Expression = { $_.Script_Name } },
        @{ Label = "Status"; Expression = { $_.Execution_Status } },
        @{ Label = "Transaction"; Expression = { $_.Transaction_Status } },
        @{ Label = "Batches"; Expression = { if ([int]$_.Total_Batches -gt 0) { "$($_.Batches_Executed)/$($_.Total_Batches)" } else { "" } } },
        @{ Label = "Duration(s)"; Expression = { $_.Duration } }
    ) | Out-String -Width 4096 | Write-Host

    # Export results: one row per planned script/database, in deployment order
    $buildId = $env:BUILD_BUILDID
    if ([string]::IsNullOrWhiteSpace($buildId)) { $buildId = "local" }
    $resultsPath = Join-Path $ArtifactsDirectory "executionsql-results-$buildId.csv"

    $orderedResults | Export-Csv -Path $resultsPath -NoTypeInformation -Force
    Write-Host "Results exported to: $resultsPath" -ForegroundColor Green

    # Report failed features
    if ($Global:FailedFeatures.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed Features:" -ForegroundColor Red
        foreach ($failedFeature in $Global:FailedFeatures) {
            Write-Host "  - $($failedFeature.ApplicationName).$($failedFeature.FeatureName)" -ForegroundColor Red
            foreach ($target in @($failedFeature.FailedTargets)) {
                if ($target) { Write-Host "      failed : $target" -ForegroundColor Red }
            }
            foreach ($target in @($failedFeature.SkippedTargets)) {
                if ($target) { Write-Host "      skipped: $target (failed in an earlier feature)" -ForegroundColor Yellow }
            }
        }
    }

    # Set pipeline variables
    Write-Host ""
    Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]$deploymentSuccess"
    Write-Host "##vso[task.setvariable variable=SuccessfulScripts;isOutput=true]$successfulScripts"
    Write-Host "##vso[task.setvariable variable=FailedScripts;isOutput=true]$failedScripts"
    Write-Host "##vso[task.setvariable variable=RolledBackScripts;isOutput=true]$rolledBackScripts"
    Write-Host "##vso[task.setvariable variable=SkippedScripts;isOutput=true]$skippedScripts"
    Write-Host "##vso[task.setvariable variable=TotalScripts;isOutput=true]$totalScripts"
    Write-Host "##vso[task.setvariable variable=ExecutionTime;isOutput=true]$executionTime"

    if ($deploymentSuccess) {
        Write-Host "[SUCCESS] Feature-based SQL Deployment completed successfully" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[FAILED] Feature-based SQL Deployment completed with failures" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Error "Deployment failed with exception: $($_.Exception.Message)"
    Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]false"
    exit 1
}

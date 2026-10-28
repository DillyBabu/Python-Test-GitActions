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

    [parameter(Mandatory = $false)]
    [string]$FeatureFilter = 'all',

    [parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory
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

function Execute-Feature {
    param(
        [array]$FeatureScripts,
        [string]$ApplicationName,
        [string]$FeatureName
    )

    Write-StageHeader "Feature: $ApplicationName > $FeatureName ($($FeatureScripts.Count) scripts)"

    $featureSuccess = $true
    $featureFailedScripts = @()

    # Sort scripts by script order
    $sortedScripts = $FeatureScripts | Sort-Object { [int]$_.Script_Order }

    foreach ($script in $sortedScripts) {
        # Get connection string from environment variable
        $connVarName = $script.ConnectionStringVar
        $connectionString = (Get-ChildItem Env:$connVarName -ErrorAction SilentlyContinue).Value

        if (-not $connectionString) {
            Write-ScriptExecution "Connection string variable '$connVarName' not set for $($script.SQL_Path)" "Failed"
            $script.Execution_Status = "Failed"
            $script.Error_Message = "Connection string variable '$connVarName' not found"
            $Global:DeploymentResults += $script
            $featureSuccess = $false
            $featureFailedScripts += $script
            continue
        }

        # Execute script with validation
        $scriptSuccess = Execute-ScriptWithValidation -Script $script -ConnectionString $connectionString

        if (-not $scriptSuccess) {
            $featureSuccess = $false
            $featureFailedScripts += $script

            # Handle rollback strategy
            switch ($RollbackStrategy) {
                'AtomicFeature' {
                    Write-ScriptExecution "AtomicFeature rollback triggered" "Rollback"
                    # Tracks clients that have already failed a script within this feature.
                    # In ContinueOnClientFailure mode, all subsequent scripts for a failed client
                    # are auto-skipped — preserving the prerequisite chain without blocking other clients.
                    $failedClients = [System.Collections.Generic.HashSet[string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase
                    )

                    # Sort scripts by script order (all scripts for Script_Order=1 run first, then =2, etc.)
                    $sortedScripts = $FeatureScripts | Sort-Object { [int]$_.Script_Order }

                    foreach ($script in $sortedScripts) {

                        # ── ContinueOnClientFailure: prerequisite guard ──────────────────────────
                        # If this client already failed an earlier script in this feature, skip all
                        # remaining scripts for it without executing — prerequisite chain is broken.
                        if ($ClientResilienceMode -eq "ContinueOnClientFailure" -and
                            $failedClients.Contains($script.Client_Name)) {

                            Write-ScriptExecution "[SKIPPED] '$($script.Script_Name)' for client '$($script.Client_Name)' - prerequisite script failed for this client" "Warning"
                            $script.Execution_Status = "Skipped"
                            $script.Error_Message = "Skipped: a prerequisite script failed for client '$($script.Client_Name)' in this feature"
                            $Global:DeploymentResults += $script
                            Write-Checkpoint -Script $script
                            $featureSuccess = $false
                            $featureFailedScripts += $script
                            continue
                        }

                        # ── Get connection string ────────────────────────────────────────────────
                        $connVarName = $script.ConnectionStringVar
                        $connectionString = (Get-ChildItem Env:$connVarName -ErrorAction SilentlyContinue).Value

                        if (-not $connectionString) {
                            Write-ScriptExecution "Connection string variable '$connVarName' not set for $($script.SQL_Path)" "Failed"
                            $script.Execution_Status = "Failed"
                            $script.Error_Message = "Connection string variable '$connVarName' not found"
                            $Global:DeploymentResults += $script
                            Write-Checkpoint -Script $script
                            $featureSuccess = $false
                            $featureFailedScripts += $script

                            if ($ClientResilienceMode -eq "ContinueOnClientFailure") {
                                # Mark client as failed so its subsequent scripts are auto-skipped
                                $failedClients.Add($script.Client_Name) | Out-Null
                            }
                            continue
                        }

                        # ── Execute script with validation ───────────────────────────────────────
                        $scriptSuccess = Execute-ScriptWithValidation -Script $script -ConnectionString $connectionString

                        if (-not $scriptSuccess) {
                            $featureSuccess = $false
                            $featureFailedScripts += $script

                            # ContinueOnClientFailure: mark client as failed, continue with next client
                            if ($ClientResilienceMode -eq "ContinueOnClientFailure") {
                                $failedClients.Add($script.Client_Name) | Out-Null
                                Write-ScriptExecution "ContinueOnClientFailure - client '$($script.Client_Name)' failed on '$($script.Script_Name)'. Subsequent scripts for this client will be skipped. Continuing with other clients." "Warning"
                                continue
                            }

                            # StopOnFirstClientFailure (default): apply the configured rollback strategy
                            switch ($RollbackStrategy) {
                                'AtomicFeature' {
                                    Write-ScriptExecution "AtomicFeature rollback triggered" "Rollback"
                                    Invoke-FeatureRollback -FeatureScripts $sortedScripts -ApplicationName $ApplicationName -FeatureName $FeatureName
                                    return $false
                                }
                                'Progressive' {
                                    Write-ScriptExecution "Progressive strategy - continuing with next script" "Warning"
                                    return $false
                                }
                                'CascadingApplication' {
                                    Write-ScriptExecution "CascadingApplication rollback triggered" "Rollback"
                                    return $false
                                }
                            }
                        }
                    }

                    # Track failed features
                    if (-not $featureSuccess) {
                        $Global:FailedFeatures += @{
                            ApplicationName = $ApplicationName
                            FeatureName     = $FeatureName
                            FailedScripts   = $featureFailedScripts
                        }
                    }

                    # Report any clients that had failures so they are visible in the summary
                    if ($failedClients.Count -gt 0) {
                        Write-ScriptExecution "Clients with failures in this feature: $($failedClients -join ', ')" "Warning"
                        Write-Host "Found $($allScripts.Count) execution plan row(s)" -ForegroundColor Green
                    }
                    catch {
                        Write-Error "Failed to read execution plan: $($_.Exception.Message)"
                        Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]false"
                        exit 1
                    }

                    # Apply filters if specified
                    if ($ApplicationFilter -ne 'all') {
                        $allScripts = $allScripts | Where-Object { $_.Application_Name -eq $ApplicationFilter }
                        Write-Host "Filtered to application: $($allScripts.Count) row(s)" -ForegroundColor Green
                    }

                    if ($FeatureFilter -ne 'all') {
                        $allScripts = $allScripts | Where-Object { $_.Feature_Name -eq $FeatureFilter }
                        Write-Host "Filtered to feature: $($allScripts.Count) row(s)" -ForegroundColor Green
                    }

                    if ($allScripts.Count -eq 0) {
                        Write-Error "No execution plan rows after applying filters"
                        Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]false"
                        exit 1
                    }

                    $allScripts = @($allScripts)
                    foreach ($row in $allScripts) {
                        Initialize-ResultFields -Row $row
                    }

                    # Group by application and feature for execution
                    $featureGroups = $allScripts | Group-Object -Property Application_Name, Feature_Name

                    Write-Host ""
                    Write-Host "Deployment Summary:" -ForegroundColor Yellow
                    Write-Host "  Total Features: $($featureGroups.Count)" -ForegroundColor Yellow
                    Write-Host "  Total Execution Rows: $($allScripts.Count)" -ForegroundColor Yellow
                    Write-Host "  Unique Clients: $(($allScripts | Select-Object -Unique Client_Name).Count)" -ForegroundColor Yellow
                    Write-Host "  Unique Servers: $(($allScripts | Select-Object -Unique Server_Name).Count)" -ForegroundColor Yellow

                    # Execute deployment
                    try {
                        $deploymentSuccess = $true

                        # Sort feature groups by Feature_Order for consistent execution
                        $sortedFeatureGroups = $featureGroups | ForEach-Object {
                            $featureOrder = [int]($_.Group[0].Feature_Order)
                            $_ | Add-Member -MemberType NoteProperty -Name SortOrder -Value $featureOrder -PassThru
                        } | Sort-Object { [int]$_.SortOrder }

                        foreach ($featureGroup in $sortedFeatureGroups) {
                            $groupParts = $featureGroup.Name -split ', '
                            $applicationName = $groupParts[0]
                            $featureName = $groupParts[1]
                            $featureScripts = $featureGroup.Group

                            $featureSuccess = Execute-Feature -FeatureScripts $featureScripts `
                                -ApplicationName $applicationName `
                                -FeatureName $featureName

                            if (-not $featureSuccess) {
                                $deploymentSuccess = $false

                                # Handle cascading rollback
                                if ($RollbackStrategy -eq 'CascadingApplication') {
                                    Write-ScriptExecution "Cascading rollback for application: $applicationName" "Rollback"
                                    # Rollback all features of this application
                                    $appScripts = $Global:DeploymentResults | Where-Object { $_.Application_Name -eq $applicationName }
                                    $appFeatureGroups = $appScripts | Group-Object -Property Feature_Name

                                    foreach ($appFeatureGroup in $appFeatureGroups) {
                                        Invoke-FeatureRollback -FeatureScripts $appFeatureGroup.Group `
                                            -ApplicationName $applicationName `
                                            -FeatureName $appFeatureGroup.Name
                                    }
                                    break
                                }
                            }
                        }

                        # Rows that were never executed (stopped by an earlier failure) are reported as Skipped
                        foreach ($row in $allScripts) {
                            if ($row.Execution_Status -eq "Pending") {
                                $row.Execution_Status = "Skipped"
                                $row.Error_Message = "Not executed: deployment stopped after an earlier failure ($RollbackStrategy strategy)"
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

                        Write-Host ""
                        Write-Host "Execution Details:" -ForegroundColor Yellow
                        $allScripts | Format-Table -AutoSize -Property @(
                            @{ Label = "Script"; Expression = { $_.Script_Name } },
                            @{ Label = "Client"; Expression = { $_.Client_Name } },
                            @{ Label = "Server"; Expression = { $_.Server_Name } },
                            @{ Label = "Database"; Expression = { $_.Database_Name } },
                            @{ Label = "Status"; Expression = { $_.Execution_Status } },
                            @{ Label = "Transaction"; Expression = { $_.Transaction_Status } },
                            @{ Label = "Batches"; Expression = { if ([int]$_.Total_Batches -gt 0) { "$($_.Batches_Executed)/$($_.Total_Batches)" } else { "" } } },
                            @{ Label = "Duration(s)"; Expression = { $_.Duration } }
                        ) | Out-String -Width 4096 | Write-Host

                        # Export results: one row per planned script/database, in plan order
                        $buildId = $env:BUILD_BUILDID
                        if ([string]::IsNullOrWhiteSpace($buildId)) { $buildId = "local" }
                        $resultsPath = Join-Path $ArtifactsDirectory "executionsql-results-$buildId.csv"

                        $allScripts | Export-Csv -Path $resultsPath -NoTypeInformation -Force
                        Write-Host "Results exported to: $resultsPath" -ForegroundColor Green

                        # Report failed features
                        if ($Global:FailedFeatures.Count -gt 0) {
                            Write-Host ""
                            Write-Host "Failed Features:" -ForegroundColor Red
                            $Global:FailedFeatures | ForEach-Object {
                                Write-Host "  - $($_.ApplicationName).$($_.FeatureName)" -ForegroundColor Red
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
                    }                # Export results: one row per planned script/database, in plan order
                    $buildId = $env:BUILD_BUILDID
                    if ([string]::IsNullOrWhiteSpace($buildId)) { $buildId = "local" }
                    $resultsPath = Join-Path $ArtifactsDirectory "executionsql-results-$buildId.csv"

                    $allScripts | Export-Csv -Path $resultsPath -NoTypeInformation -Force
                    Write-Host "Results exported to: $resultsPath" -ForegroundColor Green

                    # Report failed features
                    if ($Global:FailedFeatures.Count -gt 0) {
                        Write-Host ""
                        Write-Host "Failed Features:" -ForegroundColor Red
                        $Global:FailedFeatures | ForEach-Object {
                            Write-Host "  - $($_.ApplicationName).$($_.FeatureName)" -ForegroundColor Red
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
            }
        }
        catch {
            Write-Error "Deployment failed with exception: $($_.Exception.Message)"
            Write-Host "##vso[task.setvariable variable=DeploymentSuccess;isOutput=true]false"
            exit 1
        }
    }
}

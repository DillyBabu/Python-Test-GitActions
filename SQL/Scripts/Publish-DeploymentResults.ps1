param(
    [parameter(Mandatory = $true)]
    [string]$WorkingDirectory,

    [parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory,

    [parameter(Mandatory = $false)]
    [string]$Environment,

    [parameter(Mandatory = $false)]
    [string]$ReleaseVersion = "",

    [parameter(Mandatory = $false)]
    [bool]$GenerateDetailedReport = $true
)

function Write-StageHeader {
    param([string]$Message)
    Write-Host "$Message" -ForegroundColor Cyan
    Write-Host ("=" * $Message.Length) -ForegroundColor Cyan
}

function ConvertTo-HtmlText {
    param([object]$Value)

    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-DisplayValue {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return "-" }
    return [string]$Value
}

# Maps every status written by Deploy-FeatureBasedSQL.ps1 to one reporting category
function Get-StatusCategory {
    param([string]$Status)

    switch ($Status) {
        'Success'          { return 'Success' }
        'Failed'           { return 'Failed' }
        'Failure'          { return 'Failed' }
        'Rollback Success' { return 'RolledBack' }
        'Rollback Failed'  { return 'RollbackFailed' }
        'Skipped'          { return 'Skipped' }
        default            { return 'Other' }
    }
}

function Get-CategoryCount {
    param(
        [array]$Rows,
        [string]$Category
    )

    return @($Rows | Where-Object { (Get-StatusCategory $_.Execution_Status) -eq $Category }).Count
}

function Get-DurationSum {
    param([array]$Rows)

    $total = 0.0
    foreach ($row in $Rows) {
        $value = 0.0
        if ([double]::TryParse([string]$row.Duration, [ref]$value)) {
            $total += $value
        }
    }
    return [math]::Round($total, 2)
}

function Get-DeploymentStatistics {
    param([array]$Results)

    $stats = @{
        TotalScripts          = $Results.Count
        SuccessfulScripts     = Get-CategoryCount -Rows $Results -Category 'Success'
        FailedScripts         = Get-CategoryCount -Rows $Results -Category 'Failed'
        RolledBackScripts     = Get-CategoryCount -Rows $Results -Category 'RolledBack'
        RollbackFailedScripts = Get-CategoryCount -Rows $Results -Category 'RollbackFailed'
        SkippedScripts        = Get-CategoryCount -Rows $Results -Category 'Skipped'
        TotalDuration         = Get-DurationSum -Rows $Results
        AverageDuration       = 0
        Applications          = @($Results | Group-Object -Property Application_Name).Count
        Features              = @($Results | Group-Object -Property Application_Name, Feature_Name).Count
        Servers               = @($Results | Group-Object -Property Server_Name).Count
        Databases             = @($Results | Group-Object -Property Server_Name, Database_Name).Count
    }

    if ($stats.TotalScripts -gt 0) {
        $stats.AverageDuration = [math]::Round($stats.TotalDuration / $stats.TotalScripts, 2)
    }
    return $stats
}

function New-ExecutionSummary {
    param(
        [array]$Results,
        [hashtable]$Statistics,
        [string]$Environment,
        [string]$ReleaseVersion
    )

    $executedBy = $env:BUILD_REQUESTEDFOR
    if ([string]::IsNullOrWhiteSpace($executedBy)) { $executedBy = [System.Environment]::UserName }

    $failedTotal = $Statistics.FailedScripts + $Statistics.RollbackFailedScripts
    $status = if ($failedTotal -gt 0) { "Failed" }
    elseif (($Statistics.RolledBackScripts + $Statistics.SkippedScripts) -gt 0) { "Warning" }
    else { "Success" }

    $summary = @{
        Environment        = $Environment
        ReleaseVersion     = $ReleaseVersion
        ExecutionTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ExecutedBy         = $executedBy
        BuildNumber        = $env:BUILD_BUILDNUMBER
        Statistics         = $Statistics
        SuccessRate        = if ($Statistics.TotalScripts -gt 0) { [math]::Round(($Statistics.SuccessfulScripts / $Statistics.TotalScripts) * 100, 2) } else { 0 }
        Status             = $status
    }

    # Server / Database breakdown
    $summary.ServerBreakdown = @($Results | Group-Object -Property Server_Name, Database_Name | ForEach-Object {
            $rows = @($_.Group)
            [ordered]@{
                ServerName     = $rows[0].Server_Name
                DatabaseName   = $rows[0].Database_Name
                Clients        = (@($rows | Select-Object -ExpandProperty Client_Name -Unique) -join ', ')
                TotalScripts   = $rows.Count
                Successful     = Get-CategoryCount -Rows $rows -Category 'Success'
                Failed         = (Get-CategoryCount -Rows $rows -Category 'Failed') + (Get-CategoryCount -Rows $rows -Category 'RollbackFailed')
                RolledBack     = Get-CategoryCount -Rows $rows -Category 'RolledBack'
                Skipped        = Get-CategoryCount -Rows $rows -Category 'Skipped'
                Duration       = Get-DurationSum -Rows $rows
            }
        })

    # Application breakdown
    $summary.ApplicationBreakdown = @($Results | Group-Object -Property Application_Name | ForEach-Object {
            $rows = @($_.Group)
            [ordered]@{
                ApplicationName   = $_.Name
                Features          = @($rows | Select-Object -Property Feature_Name -Unique).Count
                TotalScripts      = $rows.Count
                SuccessfulScripts = Get-CategoryCount -Rows $rows -Category 'Success'
                FailedScripts     = (Get-CategoryCount -Rows $rows -Category 'Failed') + (Get-CategoryCount -Rows $rows -Category 'RollbackFailed')
                Duration          = Get-DurationSum -Rows $rows
            }
        })

    # Feature breakdown
    $summary.FeatureBreakdown = @($Results | Group-Object -Property Application_Name, Feature_Name | ForEach-Object {
            $rows = @($_.Group)
            $started = @($rows | Where-Object { $_.Start_Time } | Sort-Object -Property Start_Time)
            [ordered]@{
                ApplicationName   = $rows[0].Application_Name
                FeatureName       = $rows[0].Feature_Name
                TotalScripts      = $rows.Count
                SuccessfulScripts = Get-CategoryCount -Rows $rows -Category 'Success'
                FailedScripts     = (Get-CategoryCount -Rows $rows -Category 'Failed') + (Get-CategoryCount -Rows $rows -Category 'RollbackFailed')
                Duration          = Get-DurationSum -Rows $rows
                FirstExecuted     = if ($started.Count -gt 0) { $started[0].Start_Time } else { "" }
                LastExecuted      = if ($started.Count -gt 0) { $started[$started.Count - 1].End_Time } else { "" }
            }
        })

    return $summary
}

function New-FailureAnalysis {
    param([array]$FailedResults)

    $failedRows = @($FailedResults)

    if ($failedRows.Count -eq 0) {
        return @{
            HasFailures        = $false
            FailureCount       = 0
            FailureTypes       = @()
            RecommendedActions = @()
            FailedScripts      = @()
        }
    }

    $failureTypes = [ordered]@{}
    $recommendedActions = New-Object System.Collections.Generic.List[string]

    foreach ($failure in $failedRows) {
        $errorMsg = [string]$failure.Error_Message
        if ([string]::IsNullOrWhiteSpace($errorMsg)) {
            $errorMsg = "No error message provided."
        }

        if ($errorMsg -match "Connection string variable") {
            $type = "Configuration Issues"
            $action = "Check that every connectionStringVar in the environment config is defined in the variable group and mapped to the task."
        }
        elseif ($errorMsg -match "timeout|time out|timed out|deadlock") {
            $type = "Performance Issues"
            $action = "Investigate blocking, deadlocks or long-running statements, and review the command timeout."
        }
        elseif ($errorMsg -match "login|connection|network") {
            $type = "Network/Connection Issues"
            $action = "Check network connectivity, firewall rules, credentials and database server availability."
        }
        elseif ($errorMsg -match "permission|access denied") {
            $type = "Permission Issues"
            $action = "Verify that the deployment account has the necessary permissions on the target database."
        }
        elseif ($errorMsg -match "syntax|parsing|invalid") {
            $type = "Syntax Errors"
            $action = "Review and correct the SQL syntax or object names in the failed scripts."
        }
        else {
            $type = "Other Errors"
            $action = "Investigate the specific error message for each failed script to determine the root cause."
        }

        if ($failureTypes.Contains($type)) {
            $failureTypes[$type] = $failureTypes[$type] + 1
        }
        else {
            $failureTypes[$type] = 1
        }

        if (-not $recommendedActions.Contains($action)) {
            $recommendedActions.Add($action)
        }
    }

    return @{
        HasFailures        = $true
        FailureCount       = $failedRows.Count
        FailureTypes       = @($failureTypes.Keys | ForEach-Object { [ordered]@{ Type = $_; Count = $failureTypes[$_] } })
        RecommendedActions = @($recommendedActions)
        FailedScripts      = @($failedRows | Select-Object Script_Name, SQL_Path, Application_Name, Feature_Name, Client_Name, Server_Name, Database_Name, Execution_Status, Failed_Batch, Total_Batches, Transaction_Status, Error_Message)
    }
}

function Get-StatusBadge {
    param([string]$Status)

    $class = switch (Get-StatusCategory $Status) {
        'Success'        { 'ok' }
        'Failed'         { 'fail' }
        'RollbackFailed' { 'fail' }
        'RolledBack'     { 'warn' }
        default          { 'skip' }
    }
    return "<span class=""badge $class"">$(ConvertTo-HtmlText (Get-DisplayValue $Status))</span>"
}

function Get-TransactionBadge {
    param([string]$TransactionStatus)

    if ([string]::IsNullOrWhiteSpace($TransactionStatus)) { return "-" }

    $class = switch ($TransactionStatus) {
        'Committed'        { 'ok' }
        'RolledBack'       { 'warn' }
        'NotUsed'          { 'skip' }
        'NotStarted'       { 'skip' }
        default            { 'fail' }   # RollbackFailed, EndedByServer, PartiallyApplied, Open
    }
    return "<span class=""badge $class"">$(ConvertTo-HtmlText $TransactionStatus)</span>"
}

# Planned value, plus the value actually reported by the SQL connection when it differs
function Get-TargetCell {
    param(
        [string]$Planned,
        [string]$Actual
    )

    $cell = ConvertTo-HtmlText (Get-DisplayValue $Planned)
    if (-not [string]::IsNullOrWhiteSpace($Actual) -and $Actual -ne $Planned) {
        $cell += "<div class=""note"">connected: $(ConvertTo-HtmlText $Actual)</div>"
    }
    return $cell
}

function New-HtmlReport {
    param(
        [hashtable]$Summary,
        [hashtable]$FailureAnalysis,
        [array]$Results
    )

    $stats = $Summary.Statistics
    $sb = New-Object System.Text.StringBuilder

    $overallClass = switch ($Summary.Status) {
        'Success' { 'ok' }
        'Warning' { 'warn' }
        default   { 'fail' }
    }

    [void]$sb.Append(@"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>SQL Deployment Report - $(ConvertTo-HtmlText $Summary.Environment) - $(ConvertTo-HtmlText $Summary.ReleaseVersion)</title>
<style>
    body { font-family: "Segoe UI", Arial, sans-serif; margin: 20px; color: #222; }
    h1 { margin: 0 0 8px 0; }
    h2 { margin-top: 32px; border-bottom: 2px solid #e0e0e0; padding-bottom: 4px; }
    .header { background: #f5f5f5; padding: 12px 16px; border-radius: 6px; }
    .header table td { border: none; padding: 2px 24px 2px 0; }
    .metrics { display: flex; flex-wrap: wrap; gap: 12px; }
    .metric { border: 1px solid #ddd; border-radius: 6px; padding: 10px 16px; min-width: 110px; }
    .metric .value { font-size: 24px; font-weight: bold; }
    .metric .label { color: #666; font-size: 12px; }
    table { border-collapse: collapse; margin-top: 8px; font-size: 13px; }
    th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
    th { background: #f0f0f0; }
    tr.row-fail { background: #fff4f4; }
    .num { text-align: right; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 12px; font-weight: bold; white-space: nowrap; }
    .ok   { background: #e3f6e5; color: #1b6e2a; }
    .fail { background: #fde4e4; color: #a11111; }
    .warn { background: #fff1d6; color: #8a5a00; }
    .skip { background: #ececec; color: #555555; }
    .t-ok { color: #1b6e2a; } .t-fail { color: #a11111; } .t-warn { color: #8a5a00; } .t-skip { color: #555555; }
    .note { color: #a11111; font-size: 11px; }
    .path { color: #777; font-size: 11px; }
    .error { white-space: pre-wrap; font-family: Consolas, monospace; font-size: 12px; max-width: 560px; }
</style>
</head>
<body>
<div class="header">
    <h1>SQL Deployment Report</h1>
    <table>
        <tr><td><strong>Environment</strong></td><td>$(ConvertTo-HtmlText $Summary.Environment)</td>
            <td><strong>Release Version</strong></td><td>$(ConvertTo-HtmlText $Summary.ReleaseVersion)</td></tr>
        <tr><td><strong>Build</strong></td><td>$(ConvertTo-HtmlText (Get-DisplayValue $Summary.BuildNumber))</td>
            <td><strong>Requested By</strong></td><td>$(ConvertTo-HtmlText $Summary.ExecutedBy)</td></tr>
        <tr><td><strong>Report Generated</strong></td><td>$(ConvertTo-HtmlText $Summary.ExecutionTimestamp)</td>
            <td><strong>Overall Status</strong></td><td><span class="badge $overallClass">$(ConvertTo-HtmlText $Summary.Status)</span></td></tr>
    </table>
</div>

<h2>Summary</h2>
<div class="metrics">
"@)

    $metrics = @(
        @{ Label = 'Total Scripts'; Value = $stats.TotalScripts; Class = '' },
        @{ Label = 'Succeeded'; Value = $stats.SuccessfulScripts; Class = 't-ok' },
        @{ Label = 'Failed'; Value = $stats.FailedScripts; Class = 't-fail' },
        @{ Label = 'Rolled Back (feature)'; Value = $stats.RolledBackScripts; Class = 't-warn' },
        @{ Label = 'Rollback Failed'; Value = $stats.RollbackFailedScripts; Class = 't-fail' },
        @{ Label = 'Skipped'; Value = $stats.SkippedScripts; Class = 't-skip' },
        @{ Label = 'Success Rate'; Value = "$($Summary.SuccessRate)%"; Class = '' },
        @{ Label = 'Servers / Databases'; Value = "$($stats.Servers) / $($stats.Databases)"; Class = '' },
        @{ Label = 'Total Duration'; Value = "$($stats.TotalDuration)s"; Class = '' }
    )
    foreach ($metric in $metrics) {
        [void]$sb.AppendLine("<div class=""metric""><div class=""value $($metric.Class)"">$(ConvertTo-HtmlText $metric.Value)</div><div class=""label"">$($metric.Label)</div></div>")
    }
    [void]$sb.AppendLine("</div>")

    # Server / Database summary
    [void]$sb.AppendLine(@"
<h2>Server / Database Summary</h2>
<table>
    <tr><th>Server</th><th>Database</th><th>Client(s)</th><th>Scripts</th><th>Succeeded</th><th>Failed</th><th>Rolled Back</th><th>Skipped</th><th>Duration (s)</th></tr>
"@)
    foreach ($server in $Summary.ServerBreakdown) {
        $rowClass = if ($server.Failed -gt 0) { ' class="row-fail"' } else { '' }
        [void]$sb.AppendLine("<tr$rowClass><td>$(ConvertTo-HtmlText $server.ServerName)</td><td>$(ConvertTo-HtmlText $server.DatabaseName)</td><td>$(ConvertTo-HtmlText $server.Clients)</td><td class=""num"">$($server.TotalScripts)</td><td class=""num t-ok"">$($server.Successful)</td><td class=""num t-fail"">$($server.Failed)</td><td class=""num t-warn"">$($server.RolledBack)</td><td class=""num t-skip"">$($server.Skipped)</td><td class=""num"">$($server.Duration)</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # Application summary
    [void]$sb.AppendLine(@"
<h2>Application Summary</h2>
<table>
    <tr><th>Application</th><th>Features</th><th>Scripts</th><th>Succeeded</th><th>Failed</th><th>Duration (s)</th></tr>
"@)
    foreach ($app in $Summary.ApplicationBreakdown) {
        [void]$sb.AppendLine("<tr><td>$(ConvertTo-HtmlText $app.ApplicationName)</td><td class=""num"">$($app.Features)</td><td class=""num"">$($app.TotalScripts)</td><td class=""num t-ok"">$($app.SuccessfulScripts)</td><td class=""num t-fail"">$($app.FailedScripts)</td><td class=""num"">$($app.Duration)</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # Every script execution
    [void]$sb.AppendLine(@"
<h2>Execution Details (all scripts)</h2>
<table>
    <tr><th>#</th><th>Application / Feature</th><th>Client</th><th>Script</th><th>Server</th><th>Database</th><th>Status</th><th>Transaction</th><th>Batches</th><th>Rows</th><th>Duration (s)</th><th>Started</th><th>Error / Notes</th></tr>
"@)
    $index = 0
    foreach ($r in $Results) {
        $index++
        $category = Get-StatusCategory $r.Execution_Status
        $rowClass = if ($category -eq 'Failed' -or $category -eq 'RollbackFailed') { ' class="row-fail"' } else { '' }

        $batches = "-"
        if ([int]$r.Total_Batches -gt 0) {
            $batches = "$($r.Batches_Executed) / $($r.Total_Batches)"
            if (-not [string]::IsNullOrWhiteSpace($r.Failed_Batch)) {
                $batches += "<div class=""note"">failed at batch $(ConvertTo-HtmlText $r.Failed_Batch)</div>"
            }
        }

        [void]$sb.AppendLine(@"
    <tr$rowClass>
        <td class="num">$index</td>
        <td>$(ConvertTo-HtmlText $r.Application_Name)<div class="path">$(ConvertTo-HtmlText $r.Feature_Name)</div></td>
        <td>$(ConvertTo-HtmlText (Get-DisplayValue $r.Client_Name))</td>
        <td><strong>$(ConvertTo-HtmlText (Get-DisplayValue $r.Script_Name))</strong><div class="path">$(ConvertTo-HtmlText $r.SQL_Path)</div></td>
        <td>$(Get-TargetCell -Planned $r.Server_Name -Actual $r.Actual_Server)</td>
        <td>$(Get-TargetCell -Planned $r.Database_Name -Actual $r.Actual_Database)</td>
        <td>$(Get-StatusBadge $r.Execution_Status)</td>
        <td>$(Get-TransactionBadge $r.Transaction_Status)</td>
        <td>$batches</td>
        <td class="num">$(ConvertTo-HtmlText (Get-DisplayValue $r.Rows_Affected))</td>
        <td class="num">$(ConvertTo-HtmlText (Get-DisplayValue $r.Duration))</td>
        <td>$(ConvertTo-HtmlText (Get-DisplayValue $r.Start_Time))</td>
        <td><div class="error">$(ConvertTo-HtmlText $r.Error_Message)</div></td>
    </tr>
"@)
    }
    [void]$sb.AppendLine("</table>")

    # Failure analysis
    if ($FailureAnalysis.HasFailures) {
        [void]$sb.AppendLine("<h2>Failure Analysis</h2><h3>Failure Types</h3><ul>")
        foreach ($failureType in $FailureAnalysis.FailureTypes) {
            [void]$sb.AppendLine("<li><strong>$(ConvertTo-HtmlText $failureType.Type):</strong> $($failureType.Count) occurrence(s)</li>")
        }
        [void]$sb.AppendLine("</ul><h3>Recommended Actions</h3><ul>")
        foreach ($action in $FailureAnalysis.RecommendedActions) {
            [void]$sb.AppendLine("<li>$(ConvertTo-HtmlText $action)</li>")
        }
        [void]$sb.AppendLine("</ul>")

        [void]$sb.AppendLine(@"
<h3>Failed Scripts</h3>
<table>
    <tr><th>Script</th><th>Client</th><th>Server</th><th>Database</th><th>Status</th><th>Failed Batch</th><th>Transaction</th><th>Error Message</th></tr>
"@)
        foreach ($failed in $FailureAnalysis.FailedScripts) {
            $failedBatch = if ([string]::IsNullOrWhiteSpace($failed.Failed_Batch)) { "-" } else { "$($failed.Failed_Batch) of $($failed.Total_Batches)" }
            [void]$sb.AppendLine(@"
    <tr class="row-fail">
        <td><strong>$(ConvertTo-HtmlText $failed.Script_Name)</strong><div class="path">$(ConvertTo-HtmlText $failed.SQL_Path)</div></td>
        <td>$(ConvertTo-HtmlText (Get-DisplayValue $failed.Client_Name))</td>
        <td>$(ConvertTo-HtmlText $failed.Server_Name)</td>
        <td>$(ConvertTo-HtmlText $failed.Database_Name)</td>
        <td>$(Get-StatusBadge $failed.Execution_Status)</td>
        <td>$(ConvertTo-HtmlText $failedBatch)</td>
        <td>$(Get-TransactionBadge $failed.Transaction_Status)</td>
        <td><div class="error">$(ConvertTo-HtmlText $failed.Error_Message)</div></td>
    </tr>
"@)
        }
        [void]$sb.AppendLine("</table>")
    }

    [void]$sb.AppendLine("</body></html>")
    return $sb.ToString()
}

Write-StageHeader "Publishing Deployment Results Summary"
$buildId = $env:BUILD_BUILDID
if ([string]::IsNullOrWhiteSpace($buildId)) { $buildId = "local" }

# To avoid pipeline failures, ensure the artifacts directory exists
if ( -not (Test-Path -Path $ArtifactsDirectory)) {
    New-Item -ItemType Directory -Path $ArtifactsDirectory | Out-Null
}

if (-not (Test-Path -Path $WorkingDirectory)) {
    Write-Host "Working directory '$WorkingDirectory' does not exist." -ForegroundColor Red
    exit 1
}

# Find deployment result files
$resultFiles = @(Get-ChildItem -Path $ArtifactsDirectory -Filter "executionsql-results-$buildId.csv" -File)

if ($resultFiles.Count -eq 0) {
    Write-Host "No deployment result files found in '$ArtifactsDirectory' for build ID '$buildId'." -ForegroundColor Red
    exit 1
}

# Get the most recent result file based on LastWriteTime
$latestResults = $resultFiles | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
Write-Host "Processing deployment results from file: '$($latestResults.FullName)'" -ForegroundColor Green

try {
    $deploymentResults = @(Import-Csv -Path $latestResults.FullName)
    Write-Host "Imported $($deploymentResults.Count) deployment result records." -ForegroundColor Green
}
catch {
    Write-Warning "Failed to import CSV file '$($latestResults.FullName)': $($_.Exception.Message)"
    $deploymentResults = @()
}

if ($deploymentResults.Count -gt 0) {
    $statistics = Get-DeploymentStatistics -Results $deploymentResults
    $summary = New-ExecutionSummary -Results $deploymentResults -Statistics $statistics -Environment $Environment -ReleaseVersion $ReleaseVersion

    $failedResults = @($deploymentResults | Where-Object {
            $category = Get-StatusCategory $_.Execution_Status
            $category -eq 'Failed' -or $category -eq 'RollbackFailed'
        })
    $failureAnalysis = New-FailureAnalysis -FailedResults $failedResults

    # Display summary in console
    Write-Host ""
    Write-Host "Deployment Summary:" -ForegroundColor Cyan
    Write-Host "Overall Status: " -NoNewline
    if ($summary.Status -eq 'Success') {
        Write-Host "$($summary.Status)" -ForegroundColor Green
    }
    else {
        Write-Host "$($summary.Status)" -ForegroundColor Red
    }

    Write-Host "Total Scripts: $($statistics.TotalScripts)" -ForegroundColor White
    Write-Host "Successful Scripts: $($statistics.SuccessfulScripts)" -ForegroundColor Green
    Write-Host "Failed Scripts: $($statistics.FailedScripts)" -ForegroundColor Red
    Write-Host "Rolled Back Scripts: $($statistics.RolledBackScripts)" -ForegroundColor Magenta
    Write-Host "Rollback Failed Scripts: $($statistics.RollbackFailedScripts)" -ForegroundColor Red
    Write-Host "Skipped Scripts: $($statistics.SkippedScripts)" -ForegroundColor Yellow
    Write-Host "Success Rate: $($summary.SuccessRate)%" -ForegroundColor Green
    Write-Host "Total Duration: $($statistics.TotalDuration)s" -ForegroundColor White
    Write-Host "Applications: $($statistics.Applications) | Features: $($statistics.Features) | Servers: $($statistics.Servers) | Databases: $($statistics.Databases)" -ForegroundColor White

    Write-Host ""
    Write-Host "Server / Database Summary:" -ForegroundColor Cyan
    $summary.ServerBreakdown | ForEach-Object { [PSCustomObject]$_ } |
        Format-Table -AutoSize -Property ServerName, DatabaseName, Clients, TotalScripts, Successful, Failed, RolledBack, Skipped, Duration |
        Out-String -Width 4096 | Write-Host

    if ($failureAnalysis.HasFailures) {
        Write-Host "Failure Analysis:" -ForegroundColor Red
        foreach ($failureType in $failureAnalysis.FailureTypes) {
            Write-Host "  $($failureType.Type): $($failureType.Count)" -ForegroundColor Red
        }
        Write-Host "Recommended Actions:" -ForegroundColor Yellow
        foreach ($action in $failureAnalysis.RecommendedActions) {
            Write-Host "  - $action" -ForegroundColor Yellow
        }
    }

    if ($GenerateDetailedReport) {
        # Detailed JSON report
        $detailedReport = @{
            Summary         = $summary
            FailureAnalysis = $failureAnalysis
            AllResults      = $deploymentResults
        }

        $jsonReportPath = Join-Path -Path $ArtifactsDirectory "deployment-analysis.json"
        $detailedReport | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonReportPath -Encoding UTF8
        Write-Host "Detailed JSON report generated at: $jsonReportPath" -ForegroundColor Cyan

        # HTML report
        $htmlReportPath = Join-Path -Path $ArtifactsDirectory "deployment-report-$buildId.html"
        New-HtmlReport -Summary $summary -FailureAnalysis $failureAnalysis -Results $deploymentResults |
            Out-File -FilePath $htmlReportPath -Encoding UTF8
        Write-Host "HTML report generated at: $htmlReportPath" -ForegroundColor Cyan
    }

    # Set pipeline variables for Azure DevOps
    Write-Host "##vso[task.setvariable variable=DeploymentStatus;isOutput=true]$($summary.Status)"
    Write-Host "##vso[task.setvariable variable=SuccessRate;isOutput=true]$($summary.SuccessRate)"
    Write-Host "##vso[task.setvariable variable=FailedScripts;isOutput=true]$($statistics.FailedScripts + $statistics.RollbackFailedScripts)"
    Write-Host "##vso[task.setvariable variable=TotalScripts;isOutput=true]$($statistics.TotalScripts)"
}

# List all artifacts created
Write-StageHeader "Artifacts Created"
Get-ChildItem -Path $ArtifactsDirectory -File | ForEach-Object {
    $sizeKB = [math]::Round($_.Length / 1KB, 2)
    Write-Host "File: $($_.Name) | Size: $sizeKB KB" -ForegroundColor Green
}

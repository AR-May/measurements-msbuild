<#
.SYNOPSIS
    Consolidates MSBuild perf JSON files into a single data.json for the dashboard.

.DESCRIPTION
    Walks data/{branch}/{buildId}/{machine}/{test}.json, extracts build-time and
    evaluation-time, and writes data.json at the repo root as a flat JSON array.

.PARAMETER DataDir
    Source folder containing branch/buildId/machine/test.json hierarchy. Default: data/ under repo root.

.PARAMETER OutFile
    Output JSON file path. Default: data.json under repo root.

.EXAMPLE
    .\build-dashboard.ps1
#>
[CmdletBinding()]
param(
    [string]$DataDir  = (Join-Path $PSScriptRoot "data"),
    [string]$OutFile  = (Join-Path $PSScriptRoot "data.json")
)

$ErrorActionPreference = "Stop"

$records = [System.Collections.Generic.List[object]]::new()
$skipped = 0

$branchDirs = Get-ChildItem -Path $DataDir -Directory | Sort-Object Name

foreach ($branchDir in $branchDirs) {
    $branch = $branchDir.Name

    $buildDirs = Get-ChildItem -Path $branchDir.FullName -Directory | Sort-Object Name

    foreach ($buildDir in $buildDirs) {
        $buildId = $buildDir.Name
        # Validate buildId format (YYYYMMDD.N)
        if ($buildId -notmatch '^\d{8}\.\d+$') { continue }

        $machineDirs = Get-ChildItem -Path $buildDir.FullName -Directory

        foreach ($machineDir in $machineDirs) {
            $machine = $machineDir.Name
            $jsonFiles = Get-ChildItem -Path $machineDir.FullName -Filter "*.json"

            foreach ($jsonFile in $jsonFiles) {
                $testName = [System.IO.Path]::GetFileNameWithoutExtension($jsonFile.Name)

                try {
                    $json = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
                    $results = $json.jobResults.jobs.application.results

                    $exitCode = $null
                    if ($results.PSObject.Properties['exit-code']) {
                        $exitCode = $results.'exit-code'
                    }

                    $buildTime = $null
                    $evalTime  = $null

                    if ($results.PSObject.Properties['build-time']) {
                        $val = $results.'build-time'
                        if ($null -ne $val -and $val -ne '') {
                            $buildTime = [double]$val
                        }
                    }
                    if ($results.PSObject.Properties['evaluation-time']) {
                        $val = $results.'evaluation-time'
                        if ($null -ne $val -and $val -ne '') {
                            $evalTime = [double]$val
                        }
                    }

                    if ($null -ne $exitCode -and $exitCode -ne 0) {
                        $skipped++
                    }

                    $records.Add([PSCustomObject]@{
                        branch    = $branch
                        buildId   = $buildId
                        machine   = $machine
                        test      = $testName
                        buildTime = $buildTime
                        evalTime  = $evalTime
                        exitCode  = $exitCode
                    })
                }
                catch {
                    Write-Warning "Failed to parse $($jsonFile.FullName): $_"
                }
            }
        }
    }
}

$records | ConvertTo-Json -Depth 3 | Set-Content -Path $OutFile -Encoding UTF8

Write-Host "Wrote $($records.Count) records to $OutFile ($skipped skipped due to non-zero exit code)" -ForegroundColor Green

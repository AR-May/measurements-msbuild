<#
.SYNOPSIS
    Downloads MSBuild performance JSON data from Azure DevOps pipeline artifacts.

.DESCRIPTION
    Retrieves CrankAssetsPERFLIN and CrankAssetsPERFWIN artifacts from the MSBuild
    performance pipeline (definition 25429) and copies JSON files into the data/main/ folder.

    Only builds from the main branch are fetched (test runs from other branches are
    excluded). All main-branch builds that produced perf artifacts are included regardless
    of overall pipeline result (some tests fail while perf data is still valid).

    Data is organized by build date sequence (e.g. data/main/20260223.1/PERFWIN/).
    Already-downloaded builds are skipped, so the script is safe to re-run incrementally.

.PARAMETER DataDir
    Destination folder for JSON files. Default: data/main/ under the repo root.

.PARAMETER Days
    Only fetch builds from the last N days. Default: 0 (all builds).

.EXAMPLE
    .\fetch-perf-data.ps1
    .\fetch-perf-data.ps1 -Days 7
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path $PSScriptRoot "data" "main"),
    [int]$Days = 0
)

$ErrorActionPreference = "Stop"

$Organization = "https://dev.azure.com/devdiv"
$Project      = "DevDiv"
$DefinitionId = 25429
$ArtifactNames = @("CrankAssetsPERFLIN", "CrankAssetsPERFWIN")

# Compute cutoff date if Days is specified
$cutoffDate = $null
if ($Days -gt 0) {
    $cutoffDate = (Get-Date).AddDays(-$Days).ToString("yyyyMMdd")
    Write-Host "Filtering to builds from the last $Days days (>= $cutoffDate)" -ForegroundColor Cyan
}

# Ensure az devops defaults are configured
az devops configure --defaults organization=$Organization project=$Project 2>&1 | Out-Null

Write-Host "Fetching builds from pipeline $DefinitionId ..." -ForegroundColor Cyan

# az pipelines build list caps at 500 per call, which is enough for this pipeline.
# If the pipeline ever exceeds 500 builds, add pagination via --continuation-token.
$builds = az pipelines build list `
    --definition-ids $DefinitionId `
    --branch refs/heads/main `
    --top 500 `
    --query "[].{id:id, buildNumber:buildNumber, result:result}" `
    -o json 2>&1 | ConvertFrom-Json

if (-not $builds) {
    Write-Error "No builds found. Make sure you are logged in to Azure DevOps (az login)."
    exit 1
}

Write-Host "Found $($builds.Count) builds. Scanning for perf artifacts ..." -ForegroundColor Cyan

$downloaded = 0

foreach ($build in $builds) {
    $buildId = $build.id
    # Extract date.seq from buildNumber (format: YYYYMMDD.N.s_...)
    $buildDateSeq = $build.buildNumber -replace '^(\d{8}\.\d+)\..*', '$1'

    # Skip builds older than cutoff
    if ($cutoffDate) {
        $buildDate = $buildDateSeq -replace '\..*', ''
        if ($buildDate -lt $cutoffDate) {
            Write-Host "  [skip] $buildDateSeq older than $Days days" -ForegroundColor DarkGray
            continue
        }
    }

    # List artifacts for this build
    $artifacts = az pipelines runs artifact list `
        --run-id $buildId `
        --query "[].name" `
        -o json 2>&1 | ConvertFrom-Json

    if (-not $artifacts) { continue }

    foreach ($artifactName in $ArtifactNames) {
        if ($artifactName -notin $artifacts) { continue }

        # Derive machine name (PERFLIN / PERFWIN) from artifact name
        $machine = $artifactName -replace '^CrankAssets', ''

        $destDir = Join-Path $DataDir (Join-Path $buildDateSeq $machine)

        if (Test-Path $destDir) {
            Write-Host "  [skip] $buildDateSeq/$machine already exists" -ForegroundColor DarkGray
            continue
        }

        Write-Host "  Downloading $artifactName from build $buildId ($buildDateSeq, $($build.result)) ..." -ForegroundColor Yellow

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "perf_artifact_$buildId_$machine"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        az pipelines runs artifact download `
            --run-id $buildId `
            --artifact-name $artifactName `
            --path $tempDir 2>&1 | Out-Null

        # Find JSON files inside the randomly-named subdirectory
        $jsonFiles = Get-ChildItem -Path $tempDir -Filter "*.json" -Recurse |
            Where-Object { $_.DirectoryName -notlike "*_manifest*" }

        if ($jsonFiles.Count -eq 0) {
            Write-Warning "  No JSON files found in $artifactName for build $buildId"
            Remove-Item $tempDir -Recurse -Force
            continue
        }

        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        foreach ($f in $jsonFiles) {
            Copy-Item $f.FullName -Destination $destDir
        }

        Write-Host "  [done] $($jsonFiles.Count) JSON files -> data/main/$buildDateSeq/$machine" -ForegroundColor Green
        $downloaded++

        Remove-Item $tempDir -Recurse -Force
    }
}

Write-Host "`nFinished. Downloaded artifacts for $downloaded build/machine combinations into $DataDir" -ForegroundColor Cyan

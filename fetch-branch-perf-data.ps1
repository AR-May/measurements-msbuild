<#
.SYNOPSIS
    Downloads MSBuild performance JSON data from branch-based pipeline 25430 artifacts.

.DESCRIPTION
    Pipeline 25430 is a perf runner triggered by pipeline 27260 (MSBuild-ExpPerf).
    It runs from main but tests MSBuild built from a perf/ or exp/ branch.

    This script downloads CrankAssetsPERFLIN and CrankAssetsPERFWIN artifacts and
    saves them to data/<branch_flat>/<date.seq>/PERFLIN|PERFWIN/, where slashes in
    the branch name are replaced with underscores to keep it as a single folder.

    The branch name comes from triggerInfo.branch on each 25430 build, which is the
    source branch of the triggering 27260 build.

    Already-downloaded directories are skipped, so the script is safe to re-run.

.PARAMETER DataDir
    Destination folder for JSON files. Default: data/ under the repo root.

.EXAMPLE
    .\fetch-branch-perf-data.ps1
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path $PSScriptRoot "data")
)

$ErrorActionPreference = "Stop"

$Organization  = "https://dev.azure.com/devdiv"
$Project       = "DevDiv"
$DefinitionId  = 25430
$ArtifactNames = @("CrankAssetsPERFLIN", "CrankAssetsPERFWIN")

az devops configure --defaults organization=$Organization project=$Project 2>&1 | Out-Null

Write-Host "Fetching all builds from pipeline $DefinitionId ..." -ForegroundColor Cyan

$builds = az pipelines build list `
    --definition-ids $DefinitionId `
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

    # Get triggerInfo to find the source branch from the dependency pipeline
    $buildDetail = az pipelines build show --id $buildId `
        --query "{triggerBranch:triggerInfo.branch, buildNumber:buildNumber}" `
        -o json 2>&1 | ConvertFrom-Json

    $triggerBranch = $buildDetail.triggerBranch
    if (-not $triggerBranch) {
        Write-Warning "  Build $buildId has no triggerInfo.branch, skipping"
        continue
    }

    # Strip refs/heads/ prefix and replace slashes with underscores to keep it as a single folder
    $branchName = ($triggerBranch -replace '^refs/heads/', '') -replace '/', '_'

    # Extract date.seq from buildNumber (e.g. "20260223.1" from "20260223.1.t_...")
    $buildDateSeq = $build.buildNumber -replace '^(\d{8}\.\d+)\..*', '$1'

    # List artifacts for this build
    $artifacts = az pipelines runs artifact list `
        --run-id $buildId `
        --query "[].name" `
        -o json 2>&1 | ConvertFrom-Json

    if (-not $artifacts) { continue }

    foreach ($artifactName in $ArtifactNames) {
        if ($artifactName -notin $artifacts) { continue }

        $machine = $artifactName -replace '^CrankAssets', ''
        $destDir = Join-Path $DataDir (Join-Path $branchName (Join-Path $buildDateSeq $machine))

        if (Test-Path $destDir) {
            Write-Host "  [skip] $branchName/$buildDateSeq/$machine already exists" -ForegroundColor DarkGray
            continue
        }

        Write-Host "  Downloading $artifactName from build $buildId ($branchName, $buildDateSeq, $($build.result)) ..." -ForegroundColor Yellow

        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "perf_branch_artifact_$($buildId)_$machine"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        az pipelines runs artifact download `
            --run-id $buildId `
            --artifact-name $artifactName `
            --path $tempDir 2>&1 | Out-Null

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

        Write-Host "  [done] $($jsonFiles.Count) JSON files -> $branchName/$buildDateSeq/$machine" -ForegroundColor Green
        $downloaded++

        Remove-Item $tempDir -Recurse -Force
    }
}

Write-Host "`nFinished. Downloaded artifacts for $downloaded build/machine combinations into $DataDir" -ForegroundColor Cyan

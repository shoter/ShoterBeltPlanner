<#
.SYNOPSIS
    Builds the mod and installs it into the local Factorio mods folder.

.DESCRIPTION
    Runs build.ps1, removes any ShoterBeltPlanner already sitting in the mods
    folder (zipped or unpacked, any version) and copies the freshly built zip in
    its place, so Factorio never has two versions to choose between.

    Factorio picks up a mod it has not seen before automatically and enables it,
    so mod-list.json is left alone. The game reads the mods folder once at
    startup: restart it after publishing.

.PARAMETER ModsDir
    Where to install. Defaults to %APPDATA%\Factorio\mods.

.PARAMETER KeepOldVersions
    Copy the new zip in without removing older ShoterBeltPlanner entries.

.PARAMETER Force
    Publish even while Factorio is running. The removal step will most likely
    fail, because the running game holds its mod zips open.

.EXAMPLE
    .\publish_local.ps1
    .\publish_local.ps1 -WhatIf
    .\publish_local.ps1 -ModsDir 'D:\factorio-portable\mods'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ModsDir = (Join-Path $env:APPDATA 'Factorio\mods'),
    [switch]$KeepOldVersions,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$ModName = 'ShoterBeltPlanner'

if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) {
    throw "Factorio mods folder not found at '$ModsDir'. Pass -ModsDir to point at the right one."
}

$running = @(Get-Process -Name 'factorio' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if (-not $Force) {
        throw "Factorio is running (PID $($running.Id -join ', ')). Close it first, or pass -Force."
    }
    Write-Warning 'Factorio is running. Removing its open mod zips will probably fail.'
}

# build.ps1 writes its progress with Write-Host and emits the zip on the pipeline.
$zip = & (Join-Path $PSScriptRoot 'build.ps1')
if (-not $zip) {
    throw 'build.ps1 did not produce a zip.'
}

# Anything the mods folder already holds for this mod: '<name>', '<name>.zip',
# '<name>_<version>' and '<name>_<version>.zip'. The underscore keeps the match
# from spilling onto a differently-named mod that merely starts the same way.
$stale = @(
    Get-ChildItem -LiteralPath $ModsDir -Force | Where-Object {
        $_.FullName -ne $zip.FullName -and (
            $_.Name -eq $ModName -or
            $_.Name -eq "$ModName.zip" -or
            $_.Name -like "${ModName}_*"
        )
    }
)

if ($KeepOldVersions) {
    if ($stale.Count -gt 0) {
        Write-Host "Leaving $($stale.Count) existing $ModName item(s) in place (-KeepOldVersions)."
    }
}
elseif ($stale.Count -gt 0) {
    foreach ($item in $stale) {
        if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove')) {
            Write-Host "Removing $($item.Name)" -ForegroundColor DarkYellow
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
    }
}

$target = Join-Path $ModsDir $zip.Name
if ($PSCmdlet.ShouldProcess($target, 'Install')) {
    Copy-Item -LiteralPath $zip.FullName -Destination $target -Force
    Write-Host "Published $($zip.Name) to $ModsDir" -ForegroundColor Green
    Write-Host 'Restart Factorio to load it.'
}

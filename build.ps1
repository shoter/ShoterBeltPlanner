<#
.SYNOPSIS
    Packs the mod into ./dist/ShoterBeltPlanner_<version>.zip

.DESCRIPTION
    Reads the version from info.json, copies the repository contents into a
    temporary staging folder named ShoterBeltPlanner (skipping everything
    matched by the ignore lists below) and compresses it into ./dist.

    Emits the resulting zip as a FileInfo on the pipeline, so publish_local.ps1
    can pick it up without recomputing the name.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Verbose
#>
[CmdletBinding()]
param(
    # Extra items to skip on top of the built-in lists (names or wildcards).
    [string[]]$AdditionalIgnore = @()
)

$ErrorActionPreference = 'Stop'

# A caller running under -WhatIf (publish_local.ps1) would otherwise inherit the preference
# into here and skip the staging copies while still writing the zip. Building only ever
# touches ./dist, so there is nothing to preview: always do it for real.
$WhatIfPreference = $false

# --------------------------------------------------------------------------
# Ignore lists - names or wildcard patterns, matched against the path relative
# to the repository root (using '/' as separator) and against the item name.
# --------------------------------------------------------------------------
$IgnoreDirectories = @(
    'dist'
    '.git'
    '.github'
    '.vscode'
    '.idea'
    '.claude'
    'node_modules'
)

$IgnoreFiles = @(
    '*.ps1'
    '*.ps1xml'
    '.gitignore'
    '.gitattributes'
    '*.zip'
    'Thumbs.db'
    '.DS_Store'
)

$IgnoreFiles += $AdditionalIgnore

# --------------------------------------------------------------------------

$RootDir    = $PSScriptRoot
$ModName    = 'ShoterBeltPlanner'
$DistDir    = Join-Path $RootDir 'dist'
$InfoPath   = Join-Path $RootDir 'info.json'

if (-not (Test-Path -LiteralPath $InfoPath)) {
    throw "info.json not found at $InfoPath"
}

$info = Get-Content -LiteralPath $InfoPath -Raw | ConvertFrom-Json

$version = $info.version
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "No 'version' field found in $InfoPath"
}

# The zip filename must agree with info.json exactly or Factorio ignores the mod.
if ($info.name -ne $ModName) {
    throw "info.json declares name '$($info.name)' but this script packs '$ModName'. They must match."
}

$zipName = "${ModName}_${version}.zip"
$zipPath = Join-Path $DistDir $zipName

function Test-Ignored {
    param(
        [Parameter(Mandatory)][System.IO.FileSystemInfo]$Item
    )

    $relative = $Item.FullName.Substring($RootDir.Length).TrimStart('\', '/').Replace('\', '/')
    $patterns = if ($Item.PSIsContainer) { $IgnoreDirectories } else { $IgnoreFiles }

    foreach ($pattern in $patterns) {
        if ($Item.Name -like $pattern -or $relative -like $pattern) {
            return $true
        }
    }
    return $false
}

function Copy-Tree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if (Test-Ignored -Item $item) {
            Write-Verbose "skip   $($item.FullName)"
            continue
        }

        $target = Join-Path $Destination $item.Name

        if ($item.PSIsContainer) {
            Copy-Tree -Source $item.FullName -Destination $target
        }
        else {
            Write-Verbose "add    $($item.FullName)"
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

# Staging folder: <temp>\<guid>\ShoterBeltPlanner
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$stagingMod  = Join-Path $stagingRoot $ModName

try {
    Write-Host "Packing $ModName $version ..."
    Copy-Tree -Source $RootDir -Destination $stagingMod

    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Compress-Archive -Path $stagingMod -DestinationPath $zipPath -CompressionLevel Optimal -Force

    $sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    Write-Host "Created dist/$zipName ($sizeKb KB)" -ForegroundColor Green

    Get-Item -LiteralPath $zipPath
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

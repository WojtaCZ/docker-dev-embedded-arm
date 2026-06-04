<#
.SYNOPSIS
    WSL shim — delegates to scripts/dev-up.sh running inside WSL2.
.EXAMPLE
    .\scripts\dev-up.ps1
    .\scripts\dev-up.ps1 -Workspace C:\code\firmware -Rebuild
#>
[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path,
    [switch]$NoBuild,
    [switch]$NoPull,
    [switch]$Rebuild
)

$env:DEV_NO_BUILD = if ($NoBuild)  { "1" } else { "0" }
$env:DEV_NO_PULL  = if ($NoPull)   { "1" } else { "0" }
$env:DEV_REBUILD  = if ($Rebuild)  { "1" } else { "0" }

$wslWorkspace = wsl --exec wslpath -a $Workspace
wsl --cd "$PSScriptRoot/.." -- bash scripts/dev-up.sh $wslWorkspace

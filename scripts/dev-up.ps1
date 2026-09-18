<#
.SYNOPSIS
    WSL shim — delegates to scripts/dev-up.sh running inside WSL2.

.DESCRIPTION
    USB probe passthrough requires Linux device nodes, so the real work happens
    in WSL2. Attach the probe to WSL first with usbipd:

        usbipd list
        usbipd bind   --busid <busid>
        usbipd attach --wsl --busid <busid>

    Then run this script. The probe must be attached BEFORE the container
    starts — /dev/bus/usb is bind-mounted once, at container start.

.EXAMPLE
    .\scripts\dev-up.ps1
    .\scripts\dev-up.ps1 -Workspace C:\code\firmware -Rebuild
    .\scripts\dev-up.ps1 -Doctor
    .\scripts\dev-up.ps1 -Channel stable
#>
[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path,
    [switch]$NoBuild,
    [switch]$NoPull,
    [switch]$Rebuild,
    [switch]$NoCacheVolumes,
    [switch]$SkipUpdate,
    [switch]$Doctor,
    [ValidateSet("latest", "stable")]
    [string]$Channel = "latest",
    [string]$Probe
)

$ErrorActionPreference = "Stop"

$env:DEV_NO_BUILD         = if ($NoBuild)         { "1" } else { "0" }
$env:DEV_NO_PULL          = if ($NoPull)          { "1" } else { "0" }
$env:DEV_REBUILD          = if ($Rebuild)         { "1" } else { "0" }
$env:DEV_NO_CACHE_VOLUMES = if ($NoCacheVolumes)  { "1" } else { "0" }
$env:DEV_SKIP_UPDATE      = if ($SkipUpdate)      { "1" } else { "0" }
$env:DEV_DOCTOR           = if ($Doctor)          { "1" } else { "0" }
$env:DEV_CHANNEL          = $Channel
if ($Probe) { $env:DEV_PROBE = $Probe }

# WSLENV makes these visible to the Linux side of the call.
$env:WSLENV = "DEV_NO_BUILD:DEV_NO_PULL:DEV_REBUILD:DEV_NO_CACHE_VOLUMES:" +
              "DEV_SKIP_UPDATE:DEV_DOCTOR:DEV_CHANNEL:DEV_PROBE"

$wslWorkspace = wsl --exec wslpath -a $Workspace
if ($LASTEXITCODE -ne 0) { throw "could not translate '$Workspace' to a WSL path" }

wsl --cd "$PSScriptRoot/.." -- bash scripts/dev-up.sh $wslWorkspace

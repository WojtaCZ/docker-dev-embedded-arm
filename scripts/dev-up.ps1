<#
.SYNOPSIS
    WSL shim — delegates to scripts/dev-up.sh running inside WSL2.

.DESCRIPTION
    USB probe passthrough requires Linux device nodes, so the real work happens
    in WSL2. Attach the probe to WSL first with usbipd:

        usbipd list
        usbipd bind   --busid <busid>
        usbipd attach --wsl --busid <busid>

    Then run this script. /dev/bus/usb and /dev/input are both bind-mounted
    live with a wildcard device-cgroup rule, so probes and touch/HID input
    devices attached to WSL AFTER the container is already running — a second
    board, a touch panel, a hotplug replug — are picked up with no container
    restart. /dev/hidraw* nodes are the exception: they're flat in /dev with
    no directory to mount live, so a device that only exposes hidraw (no
    input handler) needs dev-up.sh re-run after it's plugged in. usbipd attach
    is still needed once per device per WSL boot; that step is what gets it
    into WSL's kernel at all and is outside the container's control.

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

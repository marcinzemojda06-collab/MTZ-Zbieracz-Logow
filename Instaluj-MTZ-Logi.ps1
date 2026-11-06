#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# Both entry points use the same staged installation, backup and app lock.
& (Join-Path $PSScriptRoot 'Launch-MTZ.ps1') -NoLaunch:$NoLaunch

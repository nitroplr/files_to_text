#.\deploy.ps1 -Clean
#.\deploy.ps1 -Clean
<#
  deploy.ps1 (streaming output version)
  Builds Flutter Windows Release and compiles Inno Setup installer in one command.

  Usage:
    .\deploy.ps1
    .\deploy.ps1 -Clean
    .\deploy.ps1 -ISCC "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
#>

[CmdletBinding()]
param(
    [ValidateSet("Release","Profile","Debug")]
    [string]$Config = "Release",

    [string]$InnoScript = ".\inno_script.iss",

    [string]$ISCC = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",

    [switch]$Clean
)

$ErrorActionPreference = "Stop"

function Exec {
    param(
        [Parameter(Mandatory=$true)][string]$File,
        [string[]]$Args = @()
    )

    $safeArgs = @($Args | Where-Object { $_ -ne $null -and $_ -ne "" })
    $argText = if ($safeArgs.Count -gt 0) { $safeArgs -join ' ' } else { "" }

    Write-Host ""
    Write-Host "==> $File $argText" -ForegroundColor Cyan

    # Run directly so stdout/stderr streams live (no "looks hung" issue)
    & $File @safeArgs
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        throw "Command failed with exit code ${code}: $File $argText"
        # alternatively:
        # throw ("Command failed with exit code {0}: {1} {2}" -f $code, $File, $argText)
    }
}

function Resolve-ISCC([string]$Provided) {
    if ($Provided -and (Test-Path $Provided)) { return (Resolve-Path $Provided).Path }

    $cmd = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$Env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "$Env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$Env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    throw @"
Could not find ISCC.exe.
- Install Inno Setup 6, OR
- Pass -ISCC "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
- Or add ISCC.exe to PATH.
"@
}

function Ensure-ProjectRoot {
    if (-not (Test-Path ".\pubspec.yaml")) {
        throw "Run this script from the Flutter project root (where pubspec.yaml is)."
    }
    if (-not (Test-Path $InnoScript)) {
        throw "Inno script not found: $InnoScript"
    }
}

# ------------------ main ------------------

Ensure-ProjectRoot

Exec "flutter" @("--version")

if ($Clean) { Exec "flutter" @("clean") }

Exec "flutter" @("pub", "get")

$flutterBuildArgs = @("build", "windows")
switch ($Config) {
    "Release" { $flutterBuildArgs += @("--release") }
    "Profile" { $flutterBuildArgs += @("--profile") }
    "Debug"   { $flutterBuildArgs += @("--debug") }
}
Exec "flutter" $flutterBuildArgs

$releaseDir = ".\build\windows\x64\runner\Release"
if (-not (Test-Path $releaseDir)) {
    throw "Expected build output not found: $releaseDir`nYour Inno script points to: build\windows\x64\runner\Release\*"
}

$resolvedISCC = Resolve-ISCC $ISCC
Write-Host ""
Write-Host "Using ISCC: $resolvedISCC" -ForegroundColor DarkCyan

# Compile the installer
Exec $resolvedISCC @($InnoScript)

Write-Host ""
Write-Host "✅ Done." -ForegroundColor Green
Write-Host "Look in: .\installer_out" -ForegroundColor Green
Write-Host "Expected filename: Setup_Files to Text_1.0.0.exe (based on your .iss)" -ForegroundColor Green

# Switchboard: one-time build toolchain for the Windows app (works on Windows on ARM and x64).
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1 [-Root $env:USERPROFILE\dev] [-Check]
#
# Installs, per user where possible:
#   - MinGit (portable Git, no installer)        -> <Root>\mingit
#   - Flutter SDK, stable channel                -> <Root>\flutter
#   - Visual Studio 2022 Build Tools, C++ (MSVC for this machine's CPU + Windows SDK) -> needs admin, ~8-10 GB
# and puts Git + Flutter on the user PATH. Safe to run again: anything already there is skipped.
# -Check only reports free disk space and what is installed, and changes nothing.
#
# Undo: delete <Root>\flutter and <Root>\mingit, remove them from the user PATH, and uninstall
# "Visual Studio Build Tools 2022" in Settings > Apps.
param(
  [string]$Root = "$env:USERPROFILE\dev",
  [switch]$Check
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
$NeedGB = 20

$arm = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'
$drive = (Split-Path -Qualifier $Root).TrimEnd(':')
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcComponent = if ($arm) { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
# ATL: flutter_secure_storage_windows + flutter_local_notifications_windows include atlbase.h/atlstr.h
$atlComponent = if ($arm) { 'Microsoft.VisualStudio.Component.VC.ATL.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.ATL' }
$vsComponents = @($vcComponent, 'Microsoft.VisualStudio.Component.VC.ATL', $atlComponent) | Select-Object -Unique
function Test-VS {
  if (-not (Test-Path $vswhere)) { return $false }
  [bool](& $vswhere -products * -requires $vsComponents -property installationPath)
}
function Get-VSPath {
  if (-not (Test-Path $vswhere)) { return $null }
  & $vswhere -products * -requires $vcComponent -property installationPath | Select-Object -First 1
}

Write-Host "CPU: $env:PROCESSOR_ARCHITECTURE   free on ${drive}: $freeGB GB"
Write-Host "Git:     $(if (Test-Path "$Root\mingit\cmd\git.exe") { 'installed' } else { 'missing' })"
Write-Host "Flutter: $(if (Test-Path "$Root\flutter\bin\flutter.bat") { 'installed' } else { 'missing' })"
Write-Host "VS C++:  $(if (Test-VS) { 'installed' } else { 'missing' })"
if ($Check) { return }
if ($freeGB -lt $NeedGB -and -not (Test-VS)) { throw "Need about $NeedGB GB free on ${drive}: (have $freeGB GB)" }

New-Item -ItemType Directory -Force $Root | Out-Null
$tmp = Join-Path $env:TEMP 'switchboard-setup'
New-Item -ItemType Directory -Force $tmp | Out-Null

# --- Git (portable MinGit from the official Git for Windows release)
if (-not (Test-Path "$Root\mingit\cmd\git.exe")) {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
  $want = if ($arm) { 'MinGit-*-arm64.zip' } else { 'MinGit-*-64-bit.zip' }
  $asset = $rel.assets | Where-Object { $_.name -like $want -and $_.name -notlike '*busybox*' } | Select-Object -First 1
  Write-Host "Downloading $($asset.name)"
  Invoke-WebRequest $asset.browser_download_url -OutFile "$tmp\mingit.zip"
  Expand-Archive "$tmp\mingit.zip" "$Root\mingit" -Force
}
$env:Path = "$Root\mingit\cmd;$env:Path"

# --- Flutter (stable). The first `flutter` run downloads the Dart SDK for this CPU.
if (-not (Test-Path "$Root\flutter\bin\flutter.bat")) {
  Write-Host 'Cloning Flutter (stable)'
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$Root\flutter"
}
$env:Path = "$Root\flutter\bin;$env:Path"

# --- User PATH (persisted)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($p in "$Root\mingit\cmd", "$Root\flutter\bin") {
  if (($userPath -split ';') -notcontains $p) { $userPath = "$p;$userPath" }
}
[Environment]::SetEnvironmentVariable('Path', $userPath, 'User')

# --- Visual Studio Build Tools (C++ desktop). Needs an elevated (admin) session.
if (-not (Test-VS)) {
  $adds = @('--add', 'Microsoft.VisualStudio.Workload.VCTools') + ($vsComponents | ForEach-Object { '--add', $_ }) +
          @('--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621')
  $existing = Get-VSPath
  if ($existing) {
    # Build Tools already there but missing a component (e.g. ATL): modify in place
    Write-Host "Adding missing C++ components to $existing"
    $vsArgs = @('modify', '--installPath', "`"$existing`"", '--quiet', '--norestart') + $adds
    $p = Start-Process "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" -ArgumentList $vsArgs -Wait -PassThru
  } else {
    Write-Host 'Installing Visual Studio 2022 Build Tools (C++), this takes a while'
    Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile "$tmp\vs_buildtools.exe"
    $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache') + $adds + @('--includeRecommended')
    $p = Start-Process "$tmp\vs_buildtools.exe" -ArgumentList $vsArgs -Wait -PassThru
  }
  # 3010 = installed, restart recommended
  if ($p.ExitCode -notin 0, 3010) { throw "Build Tools installer failed: exit $($p.ExitCode)" }
  if ($p.ExitCode -eq 3010) { Write-Host 'Build Tools installed (Windows asks for a restart when convenient)' }
  if (-not (Test-VS)) { throw 'Build Tools still missing a C++ component after install' }
}

flutter config --no-analytics | Out-Null
flutter config --enable-windows-desktop | Out-Null
flutter --disable-analytics | Out-Null
flutter doctor -v

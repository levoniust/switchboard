# Switchboard: build the Windows app and install it for this user.
#
#   powershell -ExecutionPolicy Bypass -File build.ps1 [-Src <repo>\app] [-BuildName 1.2.2] [-BuildNumber 11] [-NoInstall]
#
# Builds a release with Flutter (setup.ps1 installs the toolchain), then copies it to
# %LOCALAPPDATA%\Programs\Switchboard and adds a Start menu shortcut "Switchboard".
# Pairing, settings and the saved bridge stay where Windows keeps app data, so reinstalling keeps them.
# Undo: delete %LOCALAPPDATA%\Programs\Switchboard and the Start menu shortcut.
param(
  [string]$Src = (Join-Path $PSScriptRoot '..\..\app'),
  [string]$BuildName,
  [string]$BuildNumber,
  [switch]$NoInstall
)
$ErrorActionPreference = 'Stop'
$dev = "$env:USERPROFILE\dev"
foreach ($p in "$dev\mingit\cmd", "$dev\flutter\bin") { if (Test-Path $p) { $env:Path = "$p;$env:Path" } }

$Src = (Resolve-Path $Src).Path
Push-Location $Src
try {
  flutter pub get
  if ($LASTEXITCODE) { throw 'flutter pub get failed' }
  $flags = @('build', 'windows', '--release')
  if ($BuildName) { $flags += @('--build-name', $BuildName) }
  if ($BuildNumber) { $flags += @('--build-number', $BuildNumber) }
  flutter @flags
  if ($LASTEXITCODE) { throw 'flutter build windows failed' }
} finally { Pop-Location }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$out = Join-Path $Src "build\windows\$arch\runner\Release"
if (-not (Test-Path "$out\switchboard.exe")) { throw "No switchboard.exe in $out" }
Write-Host "Built: $out"
if ($NoInstall) { return }

$dest = "$env:LOCALAPPDATA\Programs\Switchboard"
Get-Process switchboard -ErrorAction SilentlyContinue | Stop-Process -Force   # replace a running copy
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Copy-Item -Recurse $out $dest

$lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Switchboard.lnk"
$sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sh.TargetPath = "$dest\switchboard.exe"
$sh.WorkingDirectory = $dest
$sh.Description = 'Switchboard: Claude Code chats on Powerhouse'
$sh.Save()
Write-Host "Installed: $dest (Start menu: Switchboard)"

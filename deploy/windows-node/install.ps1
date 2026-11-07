# Switchboard node for Windows (x64 or ARM64): installs or updates the node + sbkeeper for the current user.
# Run from a folder that holds the repo's bridge\ and hooks\ folders (e.g. a copy of the repo), in an ELEVATED
# PowerShell (the firewall rule needs admin; everything else is per user):
#   powershell -ExecutionPolicy Bypass -File deploy\windows-node\install.ps1 -Hosts 192.168.1.20,100.x.y.z
# Options:
#   -Hosts         addresses the node listens on (LAN and/or Tailscale). Default: this PC's IPv4 addresses.
#   -Dir           install folder (default C:\switchboard-node)
#   -Python        python.exe to build the venv from (default: newest native py launcher match)
#   -ClaudeConfig  Claude Code config folder(s) whose settings.json get the Switchboard hooks
#                  (default: %USERPROFILE%\.claude). Comma-separated for several.
#   -NoTasks       copy + venv + config only (no Scheduled Tasks, no start)
# Updating = run it again: files are replaced, config/devices/cert are kept. sbkeeper is restarted ONLY when its
# file changed, because restarting it ends every open chat.
param(
  [string[]]$Hosts = @(),
  [string]$Dir = "C:\switchboard-node",
  [string]$Python = "",
  [string[]]$ClaudeConfig = @("$env:USERPROFILE\.claude"),
  [int]$Port = 8095,
  [switch]$NoTasks
)
$ErrorActionPreference = "Stop"
# powershell -File passes "a,b" as one string: split lists ourselves
$Hosts = @($Hosts | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$ClaudeConfig = @($ClaudeConfig | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$Src = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # repo root
if (-not (Test-Path "$Src\bridge\switchboard.py")) { throw "run this from inside a Switchboard repo copy ($Src has no bridge\)" }
$Home_ = Join-Path $env:LOCALAPPDATA "switchboard"

# ---- files
New-Item -ItemType Directory -Force $Dir, "$Dir\hooks", $Home_ | Out-Null
$keeperOld = if (Test-Path "$Dir\sbkeeper.py") { (Get-FileHash "$Dir\sbkeeper.py").Hash } else { "" }
Copy-Item "$Src\bridge\switchboard.py", "$Src\bridge\sbcore.py", "$Src\bridge\sbwin.py", "$Src\bridge\sbkeeper.py", "$Src\bridge\sbrun.py" $Dir -Force
Copy-Item "$Src\hooks\switchboard-hook" "$Dir\hooks\switchboard-hook" -Force
$keeperChanged = $keeperOld -ne (Get-FileHash "$Dir\sbkeeper.py").Hash

# ---- python venv
if (-not (Test-Path "$Dir\venv\Scripts\python.exe")) {
  if (-not $Python) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "-arm64" } else { "-64" }
    $Python = (& py -V:3.14$arch -c "import sys;print(sys.executable)" 2>$null)
    if (-not $Python) { $Python = (& py -3 -c "import sys;print(sys.executable)") }
  }
  Write-Host "venv from $Python"
  & $Python -m venv "$Dir\venv"
}
$Py = "$Dir\venv\Scripts\python.exe"; $PyW = "$Dir\venv\Scripts\pythonw.exe"
& $Py -m pip install -q --disable-pip-version-check --only-binary=:all: "aiohttp>=3.9,<4" "segno>=1.6" "cryptography>=42" "psutil>=5.9" "pywinpty>=2.0" "pyte>=0.8"
if ($LASTEXITCODE) { throw "pip install failed" }

# ---- config (kept on update)
$initArgs = @("$Dir\switchboard.py", "init", "--port", $Port)
if ($Hosts.Count) { $initArgs += @("--hosts", ($Hosts -join ",")) }
& $Py @initArgs
& $Py "$Dir\sbkeeper.py" --init
# owner-only access to the config folder (it holds the cert key, device hashes and the keeper/hook keys)
icacls $Home_ /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null

# ---- Claude Code hooks (backup, then add ours next to whatever is there)
$hookCmd = ("$Py".Replace('\', '/')) + " " + ("$Dir\hooks\switchboard-hook".Replace('\', '/'))
foreach ($cc in $ClaudeConfig) {
  New-Item -ItemType Directory -Force $cc | Out-Null
  $f = Join-Path $cc "settings.json"
  if (Test-Path $f) { Copy-Item $f "$f.bak-switchboard" -Force }
  & $Py -c @"
import json, os, sys
f, cmd = sys.argv[1], sys.argv[2]
s = json.load(open(f, encoding='utf-8')) if os.path.exists(f) else {}
hooks = s.setdefault('hooks', {})
for ev in ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd']:
    groups = hooks.setdefault(ev, [])
    groups[:] = [g for g in groups if not any('switchboard-hook' in h.get('command', '') for h in g.get('hooks', []))]
    g = {'hooks': [{'type': 'command', 'command': cmd, 'timeout': 5}]}
    if ev in ('PreToolUse', 'PermissionRequest', 'PostToolUse'):
        g['matcher'] = '*'
    groups.insert(0, g)
json.dump(s, open(f, 'w', encoding='utf-8'), indent=2)
print('hooks ->', f)
"@ $f $hookCmd
}

if ($NoTasks) { return }

# ---- firewall: the node port on private networks and Tailscale only
Get-NetFirewallRule -DisplayName "Switchboard node*" -EA SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "Switchboard node (private)" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Private,Domain | Out-Null
if (Get-NetAdapter -Name "Tailscale" -EA SilentlyContinue) {
  New-NetFirewallRule -DisplayName "Switchboard node (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -InterfaceAlias "Tailscale" | Out-Null
}

# ---- Scheduled Tasks: start at logon, hidden, restart on failure, no time limit
$Me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name   # MACHINE\user (USERDOMAIN is WORKGROUP over SSH)
function Set-SbTask($name, $script, $argsText) {
  # sbrun.py restarts the program whenever it exits (Task Scheduler only retries a task that fails to START)
  $act = New-ScheduledTaskAction -Execute $PyW -Argument "`"$Dir\sbrun.py`" `"$Dir\$script`" $argsText" -WorkingDirectory $Dir
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $Me
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
           -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  $pr = New-ScheduledTaskPrincipal -UserId $Me -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -Principal $pr -Force | Out-Null
}
Set-SbTask "Switchboard keeper" "sbkeeper.py" ""
Set-SbTask "Switchboard node" "switchboard.py" "serve"

function Restart-SbTask($name, $script) {
  Stop-ScheduledTask -TaskName $name -EA SilentlyContinue
  # ending the task ends sbrun, not always its child: stop the program itself too
  Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
    Where-Object { $_.CommandLine -like "*$Dir\$script*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
  Start-Sleep -Milliseconds 1500
  Start-ScheduledTask -TaskName $name
}
$keeperRunning = (Get-ScheduledTask -TaskName "Switchboard keeper").State -eq "Running"
if ($keeperChanged -or -not $keeperRunning) { Restart-SbTask "Switchboard keeper" "sbkeeper.py"; Write-Host "sbkeeper (re)started" }
else { Write-Host "sbkeeper unchanged: left running (open chats kept)" }
Restart-SbTask "Switchboard node" "switchboard.py"
$up = $false
for ($i = 0; $i -lt 20 -and -not $up; $i++) { Start-Sleep -Milliseconds 500; $up = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue) }
if ($up) { Write-Host "node is up on port $Port. Pair a device: $Py `"$Dir\switchboard.py`" pair" -ForegroundColor Green }
else { Write-Host "node is not listening yet: see $Home_\switchboard.log" -ForegroundColor Yellow }

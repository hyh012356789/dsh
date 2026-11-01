#!/usr/bin/env pwsh
<#
.SYNOPSIS
Manage a local dsh-superagent service on Windows (one DSH profile, default `superagent`).

.DESCRIPTION
The POSIX sibling script `dsh-superagent` uses tmux, fcntl and ps, none of which exist on Windows. This script starts the
profile as a detached process, records its node PID, and reads health from the management API instead of tmux.

Exit codes: 0 runs normally; 1 stopped, duplicated, unreachable, or a runtime error (a restart may fix it); 2 a component
other than the runtime reports an error (a restart does not fix it); 3 runs and waits for setup.
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'restart', 'status')]
  [string]$Action = 'status',
  [string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }),
  [string]$Url = $(if ($env:DSH_SUPERAGENT_URL) { $env:DSH_SUPERAGENT_URL } else { 'http://127.0.0.1:3082' }),
  [double]$Timeout = 60,
  [Alias('stop-timeout')]
  [double]$StopTimeout = 300,
  [Alias('respect-stop')]
  [switch]$RespectStop
)

$ErrorActionPreference = 'Stop'
if ($Profile -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { throw '--profile must be a DSH profile name' }
if ($Timeout -le 0 -or $StopTimeout -le 0) { throw '--timeout and --stop-timeout must be positive' }

$Root = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Root '.artifacts'
$Control = Join-Path $Artifacts (Join-Path 'control\profiles' $Profile)
New-Item -ItemType Directory -Force -Path $Control | Out-Null
$PidFile = Join-Path $Control 'service.pid'
$StopMarker = Join-Path $Control 'manually-stopped'

function Get-DshProcesses {
  $escaped = [regex]::Escape($Profile)
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and $_.CommandLine -notmatch '\splugin\s' -and
      ($_.CommandLine -match "(^|\s)--profile(\s+|=)$escaped(\s|$)" -or $_.CommandLine -match "bin\.js([`"']?)\s+$escaped(\s|$)")
    } | ForEach-Object { [int]$_.ProcessId }
}

function Get-StateDir {
  # proper-lockfile locks `<stateDir>.lock`; a force-kill leaves that directory behind and the plugin refuses to start
  # until it turns stale (30 s). The path is not a script option, so read it from the profile's patch configuration.
  $dir = Join-Path $HOME ".dsh\profiles\$Profile"
  if (-not (Test-Path $dir)) { return $null }
  foreach ($file in Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue) {
    $entry = $false
    foreach ($line in Get-Content $file.FullName -ErrorAction SilentlyContinue) {
      if ($line -match '^\s*-\s*id:\s*[''"]?dsh-superagent[''"]?\s*$') { $entry = $true; continue }
      if ($line -match '^\s*-\s*id:') { $entry = $false }
      if ($entry -and $line -match '^\s+stateDir:\s*[''"]?([^''"\s#]+)') { return $Matches[1] }
    }
  }
  return $null
}

function Get-RecordedPid {
  if (-not (Test-Path $PidFile)) { return $null }
  $value = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue)
  if ($value -match '^\s*(\d+)\s*$') { return [int]$Matches[1] }
  return $null
}

function Get-State {
  try {
    $headers = @{ 'x-orchestrator-request' = '1' }
    return Invoke-RestMethod -Uri ($Url.TrimEnd('/') + '/orchestrator/api/state') -Headers $headers -TimeoutSec 5
  } catch { return $null }
}

function Get-Outcome($pids, $state) {
  if ($pids.Count -ne 1 -or -not $state) { return 1 }
  $runtime = $state.health.runtime.state
  if ($runtime -ne 'ready' -and $runtime -ne 'paused') { return 1 }
  if ($state.setup -and $state.setup.problem) { return 3 }
  $errors = $state.health.PSObject.Properties | Where-Object { $_.Name -ne 'runtime' -and $_.Value.state -eq 'error' }
  if ($errors) { return 2 }
  return 0
}

function Show-Status {
  $pids = @(Get-DshProcesses)
  $state = $null
  if ($pids.Count -gt 0) { $state = Get-State }
  $errors = $null
  $setup = $null
  $feishu = $null
  $health = $null
  if ($state) {
    $health = @{}
    foreach ($entry in $state.health.PSObject.Properties) { $health[$entry.Name] = $entry.Value.state }
    $errors = @{}
    foreach ($entry in $state.health.PSObject.Properties) { if ($entry.Value.state -eq 'error') { $errors[$entry.Name] = [string]$entry.Value.detail } }
    if ($state.setup) { $setup = $state.setup.problem; $feishu = $state.setup.feishuProblem }
  }
  [ordered]@{ pids = $pids; cwd = $Root; url = $Url; manually_stopped = (Test-Path $StopMarker);
    health = $health; errors = $errors; setup = $setup; feishu = $feishu } | ConvertTo-Json -Depth 8 | Out-Host
  return (Get-Outcome $pids $state)
}

function Start-Service {
  $pids = @(Get-DshProcesses)
  if ($pids.Count -gt 1) { throw 'Multiple dsh-superagent processes found; refusing to start another.' }
  if ($pids.Count -eq 0) {
    $dsh = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if (-not $dsh) { $dsh = Get-Command dsh -ErrorAction SilentlyContinue }
    if (-not $dsh) { throw 'dsh must be on PATH.' }
    if (Get-State) { throw 'An existing orchestrator answers at this URL; refusing duplicate startup.' }
    # Nothing for this profile is running, so any lock directory left under the state path is orphaned.
    $stateDir = Get-StateDir
    if ($stateDir -and (Test-Path "$stateDir.lock")) {
      Remove-Item "$stateDir.lock" -Recurse -Force
      Write-Host "Removed stale state lock: $stateDir.lock"
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
      $gitBin = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin'
      if (Test-Path $gitBin) { $env:Path = $env:Path + ';' + $gitBin }
    }
    if (-not $env:GH_CONFIG_DIR) { $env:GH_CONFIG_DIR = Join-Path $HOME '.config\gh-agent' }
    if (-not $env:LARKSUITE_CLI_CONFIG_DIR) { $env:LARKSUITE_CLI_CONFIG_DIR = Join-Path $HOME '.lark-cli-dsh-superagent' }
    New-Item -ItemType Directory -Force -Path $Artifacts | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $Artifacts "dsh-superagent-$Profile-$stamp-$PID.log"
    $errLog = "$log.err"
    $process = Start-Process -FilePath $dsh.Source -ArgumentList @('--profile', $Profile, '--no-open') `
      -RedirectStandardOutput $log -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
    Write-Host "Log: $log"
    # Record the node process the dsh launcher spawns, so stopping targets the service rather than cmd.exe.
    $nodePid = $null
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id) AND Name='node.exe'" -ErrorAction SilentlyContinue |
        Select-Object -First 1
      if ($child) { $nodePid = [int]$child.ProcessId; break }
    }
    if ($nodePid) { Set-Content -Path $PidFile -Value $nodePid -Encoding ascii }
  } else {
    Set-Content -Path $PidFile -Value $pids[0] -Encoding ascii
    Write-Host "dsh-superagent already running (PID $($pids[0])); no duplicate started."
  }
  Remove-Item $StopMarker -ErrorAction SilentlyContinue
  $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
  while ([DateTime]::UtcNow -lt $deadline) {
    $state = Get-State
    if ($state -and $state.health.runtime.state -in @('ready', 'paused') -and @(Get-DshProcesses).Count -eq 1) {
      $code = Show-Status
      if ($state.setup -and $state.setup.problem) { Write-Host ('dsh-superagent is waiting for setup: ' + $state.setup.problem.detail) }
      if ($state.setup -and $state.setup.feishuProblem) { Write-Host ('dsh-superagent runs without Feishu: ' + $state.setup.feishuProblem.detail) }
      foreach ($entry in $state.health.PSObject.Properties) {
        if ($entry.Name -ne 'runtime' -and $entry.Value.state -eq 'error') { Write-Host "$($entry.Name) reports an error, which a restart does not fix: $($entry.Value.detail)" }
      }
      return $code
    }
    Start-Sleep -Seconds 1
  }
  Show-Status | Out-Null
  throw 'Startup health check timed out; inspect the log. Any running process was left intact.'
}

function Stop-Service {
  $pids = @(Get-DshProcesses)
  if ($pids.Count -gt 1) { throw 'Multiple dsh-superagent processes found; refusing to choose one.' }
  if ($Action -eq 'stop') { Set-Content -Path $StopMarker -Value ((Get-Date).ToString('o')) -Encoding ascii }
  foreach ($processId in $pids) {
    & cmd.exe /c "taskkill /PID $processId /T >nul 2>&1"
  }
  # Windows has no graceful console signal for a detached node process: taskkill without /F is a no-op. Allow a short
  # grace window in case a signal-aware child exits on its own, then force-terminate the tree.
  $grace = [DateTime]::UtcNow.AddSeconds([Math]::Min(10, $StopTimeout))
  while (@(Get-DshProcesses).Count -gt 0 -and [DateTime]::UtcNow -lt $grace) { Start-Sleep -Milliseconds 500 }
  if (@(Get-DshProcesses).Count -gt 0) {
    Write-Host 'Windows cannot signal this process gracefully; forcing stop after 10 s.'
    foreach ($processId in $pids) { & cmd.exe /c "taskkill /PID $processId /T /F >nul 2>&1" }
  }
  $deadline = [DateTime]::UtcNow.AddSeconds($StopTimeout)
  while (@(Get-DshProcesses).Count -gt 0) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Stop timed out; the process did not exit. Check status.' }
    Start-Sleep -Milliseconds 500
  }
  Remove-Item $PidFile -ErrorAction SilentlyContinue
  if ($Action -eq 'stop') { Write-Host 'dsh-superagent stopped. Automatic recovery is paused until start/restart.' }
  else { Write-Host 'dsh-superagent stopped.' }
}

if ($RespectStop -and $Action -in @('start', 'restart') -and (Test-Path $StopMarker)) {
  Write-Host 'Intentional stop is active; automatic recovery skipped.'
  exit 0
}

try {
  switch ($Action) {
    'status' { $code = Show-Status; exit $code }
    'stop' { Stop-Service; exit 0 }
    'restart' { Stop-Service; $code = Start-Service; exit $code }
    'start' { $code = Start-Service; exit $code }
  }
} catch {
  Write-Host $_.Exception.Message
  exit 1
}

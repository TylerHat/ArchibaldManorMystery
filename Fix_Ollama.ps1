# Fix_Ollama.ps1
# ---------------------------------------------------------------------------
# Fixes two things on this machine:
#
#   1. A zombie second Ollama app instance that has been respawning a doomed
#      server process every ~1.1 seconds for 27+ hours (15,532 restarts, all
#      failing with "bind: Only one usage of each socket address").
#
#   2. Sets the four Ollama environment variables that let Archibald Manor
#      keep one KV-cache slot per suspect instead of sharing a single one.
#
# Run it by RIGHT-CLICKING the file and choosing "Run with PowerShell".
# Do NOT run it as Administrator - see the note at the bottom for why.
#
# It does not delete any files. It stops Ollama processes, sets four user-level
# environment variables, and starts Ollama again.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

function Section($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }

# --- Guard: refuse to run elevated -----------------------------------------
# Running elevated is what caused the bug in the first place. The Ollama app
# checks for an existing instance by sending it a window message; Windows
# blocks that message across privilege levels ("Access is denied." in app.log),
# so an elevated launch does not see the normal one and starts a second server.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Write-Host "This script is running as Administrator." -ForegroundColor Red
    Write-Host "Close this window and run it normally (right-click -> Run with PowerShell)."
    Write-Host "Mixing elevated and non-elevated Ollama launches is the exact cause of the"
    Write-Host "restart loop this script is meant to fix."
    Read-Host "Press Enter to exit"
    exit 1
}

# --- 1. Show what is running ------------------------------------------------
Section "What is running right now"

$procs = Get-Process -Name 'ollama', 'ollama app', 'ollama_llama_server' -ErrorAction SilentlyContinue
if ($procs) {
    $procs | Select-Object Id, ProcessName, StartTime | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host ("Found {0} Ollama process(es)." -f $procs.Count)
} else {
    Write-Host "No Ollama processes running."
}

Write-Host ""
Write-Host "Who currently holds port 11434:"
$conns = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    foreach ($c in $conns) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        Write-Host ("  PID {0}  {1}" -f $c.OwningProcess, $(if ($p) { $p.ProcessName } else { 'unknown' }))
    }
} else {
    Write-Host "  nobody"
}

# --- 2. Stop everything -----------------------------------------------------
Section "Stopping all Ollama processes"

# 'ollama app' is the tray application (the supervisor doing the respawning).
# 'ollama' is the server. 'ollama_llama_server' is the model runner child.
# Stop the supervisor FIRST, or it will just respawn the server again.
foreach ($name in @('ollama app', 'ollama', 'ollama_llama_server')) {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host ("Stopping {0} ({1} process(es))..." -f $name, $p.Count)
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
    }
}

Start-Sleep -Seconds 2

$left = Get-Process -Name 'ollama', 'ollama app', 'ollama_llama_server' -ErrorAction SilentlyContinue
if ($left) {
    Write-Host "Some processes did not stop:" -ForegroundColor Yellow
    $left | Select-Object Id, ProcessName | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "You may need to end them from Task Manager." -ForegroundColor Yellow
} else {
    Write-Host "All Ollama processes stopped." -ForegroundColor Green
}

# --- 3. Set the environment variables --------------------------------------
Section "Setting Ollama environment variables (user scope)"

# These four are what let the game keep a separate KV cache per suspect.
#
#   NUM_PARALLEL    4      -> four cache slots, so switching suspects in a Hall
#                             meetup no longer re-reads the whole conversation
#   FLASH_ATTENTION 1      -> required for the q8_0 cache type below
#   KV_CACHE_TYPE   q8_0   -> halves cache memory; without it, 4 slots need
#                             3.58 GB and will not fit in the 4050's ~5 GB
#   KEEP_ALIVE      -1     -> never unload the model (cold reload costs 60 s)
$vars = [ordered]@{
    'OLLAMA_NUM_PARALLEL'    = '4'
    'OLLAMA_FLASH_ATTENTION' = '1'
    'OLLAMA_KV_CACHE_TYPE'   = 'q8_0'
    'OLLAMA_KEEP_ALIVE'      = '-1'
}

foreach ($k in $vars.Keys) {
    $old = [Environment]::GetEnvironmentVariable($k, 'User')
    [Environment]::SetEnvironmentVariable($k, $vars[$k], 'User')
    # Also set it in this session so the launch below picks it up immediately.
    Set-Item -Path "Env:$k" -Value $vars[$k]
    $shown = if ([string]::IsNullOrEmpty($old)) { '(was unset)' } else { "(was '$old')" }
    Write-Host ("  {0,-24} = {1,-6} {2}" -f $k, $vars[$k], $shown)
}

# --- 4. Start exactly one instance -----------------------------------------
Section "Starting Ollama"

$appPath = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
if (-not (Test-Path $appPath)) {
    $appPath = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
}

if (Test-Path $appPath) {
    Write-Host "Launching: $appPath"
    Start-Process -FilePath $appPath
    Start-Sleep -Seconds 6
} else {
    Write-Host "Could not find Ollama at the usual location." -ForegroundColor Yellow
    Write-Host "Start it yourself from the Start menu, then re-run the check below."
}

# --- 5. Verify --------------------------------------------------------------
Section "Verifying"

$procs = Get-Process -Name 'ollama', 'ollama app' -ErrorAction SilentlyContinue
Write-Host ("Ollama processes now running: {0}" -f $(if ($procs) { $procs.Count } else { 0 }))

try {
    $v = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 10
    Write-Host ("Server responding. Version {0}" -f $v.version) -ForegroundColor Green
} catch {
    Write-Host "Server is not responding yet - give it a few more seconds and try:" -ForegroundColor Yellow
    Write-Host "  Invoke-RestMethod http://127.0.0.1:11434/api/version"
}

Section "Next step"
Write-Host @"
Play the game for a few minutes, then check that the loop is gone:

  Select-String -Path "`$env:LOCALAPPDATA\Ollama\app.log" -Pattern "ollama exited" |
      Measure-Object | Select-Object Count

It was 15,532. After this it should stay at 0 (the log rotates on restart).

And confirm the new cache slots took effect - after your first question in-game:

  Select-String -Path "`$env:LOCALAPPDATA\Ollama\server.log" -Pattern "n_slots|n_ctx_slot" |
      Select-Object -First 3

You want n_slots = 4. If n_ctx_slot comes out as 2048 instead of 8192, Ollama
divided the context instead of multiplying it - in that case set
OLLAMA_NUM_PARALLEL to 3 and re-run this script.

One more thing: your app.log shows Ollama 0.32.11 and 0.32.12 were downloaded
but never installed, probably because the two fighting instances blocked it.
You are on 0.32.9. Now that there is only one instance, it should update on its
own - or grab the installer from ollama.com and run it.
"@

Write-Host ""
Read-Host "Press Enter to close"

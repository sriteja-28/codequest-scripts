<#
.SYNOPSIS
  CodeQuest local development helper (Windows PowerShell 5.1+ and PowerShell 7+).

.DESCRIPTION
  .\scripts\dev.ps1 <command> [options]

  setup         check prerequisites, create .env files (random secrets), create the
                Python virtualenvs, install dependencies, start the dev infrastructure,
                migrate, seed sample data, build the judge language images
  dev           start infrastructure + API :8000 + judge worker + frontend :3000
                (-NoWorker / -NoFrontend to skip parts)
  stop [name]   stop the app processes and the dev containers (data is kept);
                with a name (backend | worker | frontend) stop only that process
  status        containers, app processes and /api/health/
  logs [name]   last log lines of backend | worker | frontend (-Follow to stream)
  test          backend + judge unit tests, frontend type-check and lint
  migrate       apply Django migrations to the DEV database
  seed          load the sample data (idempotent)
  manage ...    any manage.py command, e.g.  .\scripts\dev.ps1 manage grant_role you@example.com ADMIN

  Destructive (each asks you to type a confirmation word; -Yes skips the prompt):
  reset-data    delete the dev Postgres/Redis/RabbitMQ data, then migrate + seed again
  cleanup-old   remove the OLD compose containers (project "infra": codequest_postgres,
                codequest_redis, codequest_rabbitmq). Their volumes are KEPT unless you
                also pass -IncludeVolumes (separate confirmation).

  Scope: only this repository's dev stack (compose project "codequest-dev", ports
  5433/6380/5673/15673) and the app processes this script started (.dev\pids).
  Databases or services you run yourself (e.g. Postgres on 5432) are never touched.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
    [switch]$Follow,
    [switch]$IncludeVolumes,
    [switch]$Yes,
    [switch]$SkipImages,
    [switch]$NoFrontend,
    [switch]$NoWorker,
    [switch]$Reinstall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
# Python children print UTF-8 (seed output has emoji; Windows consoles default to cp1252).
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$Root        = Split-Path -Parent $PSScriptRoot
$BackendDir  = Join-Path $Root "backend"
$JudgeDir    = Join-Path $Root "judge"
$FrontendDir = Join-Path $Root "frontend"
$ComposeFile = Join-Path $Root "infra\docker-compose.dev.yml"
$DevDir      = Join-Path $Root ".dev"
$LogDir      = Join-Path $DevDir "logs"
$PidDir      = Join-Path $DevDir "pids"
$Project     = "codequest-dev"
$BackendPort = 8000
$FrontendPort = 3000

$JudgeImages = @(
    @{ Name = "codequest-python"; Dir = "python" },
    @{ Name = "codequest-cpp";    Dir = "cpp" },
    @{ Name = "codequest-java";   Dir = "java" },
    @{ Name = "codequest-js";     Dir = "javascript" }
)
$OldContainers = @("codequest_postgres", "codequest_redis", "codequest_rabbitmq")
$OldVolumes    = @("infra_postgres_data", "infra_redis_data", "infra_rabbitmq_data")

# --- helpers ------------------------------------------------------------------

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn2([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkDir = $Root)
    Push-Location $WorkDir
    # PS 5.1: redirected native stderr becomes error records that abort under
    # ErrorActionPreference=Stop (pip/npm progress lines). Relax it for the call.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @Arguments
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        Pop-Location
    }
    if ($code -ne 0) { throw "Command failed (exit $code): $Exe $($Arguments -join ' ')" }
}

function Invoke-Native {
    # Runs a native command quietly and returns @{ Code; Out }. Windows PowerShell 5.1
    # turns redirected stderr lines into errors, which ErrorActionPreference=Stop would
    # make terminating; relax it just for this call and report the exit code instead.
    param([string]$Exe, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Exe @Arguments 2>$null
        return @{ Code = $LASTEXITCODE; Out = $out }
    } catch {
        return @{ Code = 1; Out = $null }
    } finally { $ErrorActionPreference = $previous }
}

function Invoke-Relaxed {
    # Runs a native command with ErrorActionPreference relaxed (PS 5.1 turns
    # redirected stderr into terminating errors under EAP=Stop); streams live.
    param([string]$Exe, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Exe @Arguments; return $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
}

function Invoke-Compose {
    param([string[]]$Arguments)
    # Merge stderr into stdout via cmd: PS 5.1 turns redirected native stderr
    # (compose progress writes there) into error records that abort the script.
    & cmd.exe /d /c "docker compose -p $Project -f `"$ComposeFile`" $($Arguments -join ' ') 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
}

function Test-PortOpen([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(300)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Get-PortOwner([int]$Port) {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $null }
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return "$($proc.ProcessName) (PID $($conn.OwningProcess))" }
    return "PID $($conn.OwningProcess)"
}

function New-Secret([int]$Bytes = 32) {
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buffer)
    $rng.Dispose()
    return (($buffer | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-EnvValue([string]$File, [string]$Key) {
    if (-not (Test-Path $File)) { return $null }
    foreach ($line in Get-Content $File) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

function Set-EnvValue([string]$File, [string]$Key, [string]$Value) {
    $lines = @(Get-Content $File)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") { $lines[$i] = "$Key=$Value"; $found = $true }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    # UTF-8 without BOM so python-decouple and Next.js read it identically.
    [System.IO.File]::WriteAllLines($File, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Confirm-Typed([string]$Word, [string]$What) {
    if ($Yes) { return }
    Write-Host ""
    Write-Host $What -ForegroundColor Yellow
    $answer = Read-Host "Type $Word to continue (anything else cancels)"
    if ($answer -cne $Word) { throw "Cancelled: nothing was changed." }
}

function Get-FreeCommitMB {
    try { return [int]((Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory / 1024) } catch { return -1 }
}

# --- prerequisites ------------------------------------------------------------

function Get-BasePython {
    foreach ($candidate in @(@("py", "-3"), @("python"), @("python3"))) {
        $exe = $candidate[0]
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        $prefix = @()
        if ($candidate.Count -gt 1) { $prefix = @($candidate[1..($candidate.Count - 1)]) }
        $probe = Invoke-Native $exe ($prefix + @("-c", "import sys; print('%d.%d' % sys.version_info[:2])"))
        if ($probe.Code -ne 0 -or -not $probe.Out) { continue }
        $version = ([string]($probe.Out | Select-Object -First 1)).Trim()
        if ($version -notmatch '^\d+\.\d+$') { continue }
        $parts = $version.Split(".")
        if ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 10) {
            return @{ Exe = $exe; Prefix = $prefix; Version = $version }
        }
    }
    throw "Python 3.10+ not found. Install it from https://www.python.org/downloads/ and re-run setup."
}

function Assert-Prerequisites {
    Write-Step "Checking prerequisites"
    $py = Get-BasePython
    Write-Ok "Python $($py.Version)"

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js 20+ not found (https://nodejs.org)." }
    $nodeVersion = (& node --version).Trim().TrimStart("v")
    if ([int]($nodeVersion.Split(".")[0]) -lt 20) { throw "Node.js 20+ required, found $nodeVersion." }
    Write-Ok "Node $nodeVersion"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker not found. Install Docker Desktop and start it." }
    $info = Invoke-Native "docker" @("info", "--format", "{{.ServerVersion}}")
    if ($info.Code -ne 0) { throw "Docker is installed but not running. Start Docker Desktop and re-run." }
    Write-Ok "Docker $(([string]($info.Out | Select-Object -First 1)).Trim())"

    $free = Get-FreeCommitMB
    if ($free -ge 0 -and $free -lt 2048) {
        Write-Warn2 "Only $free MB of memory is free. Close other apps if installs or builds fail."
    }
    return $py
}

# --- virtualenvs --------------------------------------------------------------

function Find-VenvPython([string]$Dir, [string[]]$Names) {
    foreach ($name in $Names) {
        $venv = Join-Path $Dir $name
        $python = Join-Path $venv "Scripts\python.exe"
        # pyvenv.cfg distinguishes a real venv from an editor stub (e.g. judge\.venv).
        if ((Test-Path $python) -and (Test-Path (Join-Path $venv "pyvenv.cfg"))) { return $python }
    }
    return $null
}

function Get-BackendPython { return Find-VenvPython $BackendDir @(".venv", "leet_venv", "venv") }
function Get-JudgePython   { return Find-VenvPython $JudgeDir @("venv", ".venv") }

function Initialize-Venv([string]$Dir, [string[]]$Names, [string]$NewName, $BasePython) {
    $python = Find-VenvPython $Dir $Names
    if ($python) { Write-Ok "using $python"; return $python }
    $target = Join-Path $Dir $NewName
    Write-Ok "creating $target"
    $exe = $BasePython.Exe
    $prefix = $BasePython.Prefix
    & $exe @prefix -m venv $target
    if ($LASTEXITCODE -ne 0) { throw "Could not create virtualenv $target" }
    return (Join-Path $target "Scripts\python.exe")
}

function Require-BackendPython {
    $python = Get-BackendPython
    if (-not $python) { throw "Backend virtualenv missing. Run: .\scripts\dev.ps1 setup" }
    return $python
}

# --- env files ----------------------------------------------------------------

function Initialize-EnvFiles {
    Write-Step "Environment files"
    $backendEnv = Join-Path $BackendDir ".env"
    $judgeEnv = Join-Path $JudgeDir ".env"
    $frontendEnv = Join-Path $FrontendDir ".env.local"

    $judgeKey = Get-EnvValue $backendEnv "JUDGE_INTERNAL_API_KEY"
    if (-not (Test-Path $backendEnv)) {
        Copy-Item (Join-Path $BackendDir ".env.example") $backendEnv
        Set-EnvValue $backendEnv "SECRET_KEY" (New-Secret 32)
        $judgeKey = New-Secret 24
        Set-EnvValue $backendEnv "JUDGE_INTERNAL_API_KEY" $judgeKey
        Write-Ok "created backend\.env (random SECRET_KEY and judge key)"
    } else { Write-Ok "backend\.env exists (kept)" }

    if (-not (Test-Path $judgeEnv)) {
        Copy-Item (Join-Path $JudgeDir ".env.example") $judgeEnv
        if ($judgeKey) { Set-EnvValue $judgeEnv "JUDGE_INTERNAL_API_KEY" $judgeKey }
        Write-Ok "created judge\.env (judge key shared with backend)"
    } else {
        Write-Ok "judge\.env exists (kept)"
        if ($judgeKey -and (Get-EnvValue $judgeEnv "JUDGE_INTERNAL_API_KEY") -ne $judgeKey) {
            Write-Warn2 "JUDGE_INTERNAL_API_KEY differs between backend\.env and judge\.env: judge callbacks will be rejected."
        }
    }

    if (-not (Test-Path $frontendEnv)) {
        Copy-Item (Join-Path $FrontendDir ".env.local.example") $frontendEnv
        Write-Ok "created frontend\.env.local"
    } else { Write-Ok "frontend\.env.local exists (kept)" }
}

# --- infrastructure -----------------------------------------------------------

function Start-Infra {
    Write-Step "Starting dev infrastructure (project $Project)"
    foreach ($port in 5433, 6380, 5673, 15673) {
        if ((Test-PortOpen $port) -and -not (Test-InfraRunning)) {
            throw "Port $port is already used by $(Get-PortOwner $port). Free it or change CQ_DEV_*_PORT (see infra\docker-compose.dev.yml)."
        }
    }
    Invoke-Compose @("up", "-d", "--wait")
    Write-Ok "postgres 127.0.0.1:5433  redis 127.0.0.1:6380  rabbitmq 127.0.0.1:5673 (UI http://localhost:15673)"
}

function Test-InfraRunning {
    $ps = Invoke-Native "docker" @("compose", "-p", $Project, "-f", $ComposeFile, "ps", "-q", "--status", "running")
    return [bool]$ps.Out
}

function Build-JudgeImages {
    Write-Step "Judge language images"
    foreach ($image in $JudgeImages) {
        $present = (Invoke-Native "docker" @("image", "inspect", $image.Name)).Code -eq 0
        if ($present -and -not $Reinstall) { Write-Ok "$($image.Name) present"; continue }
        Write-Ok "building $($image.Name) (first build can take several minutes)"
        Invoke-Checked "docker" @("build", "-t", $image.Name, (Join-Path $JudgeDir "languages\$($image.Dir)"))
    }
}

# --- app processes ------------------------------------------------------------

function Get-AppPid([string]$Name) {
    # The pid file stores "PID|StartTimeTicks": a PID is only trusted while the
    # process with that PID still has the same start time (Windows reuses PIDs).
    $file = Join-Path $PidDir "$Name.pid"
    if (-not (Test-Path $file)) { return $null }
    $parts = ([string](Get-Content $file -TotalCount 1)).Split("|")
    $appPid = [int]$parts[0]
    $proc = Get-Process -Id $appPid -ErrorAction SilentlyContinue
    if ($proc -and $parts.Count -eq 2) {
        try { if ($proc.StartTime.Ticks -eq [long]$parts[1]) { return $appPid } } catch { }
    }
    Remove-Item $file -Force
    return $null
}

function Start-App([string]$Name, [string]$CommandLine, [string]$WorkDir) {
    New-Item -ItemType Directory -Force -Path $LogDir, $PidDir | Out-Null
    $existing = Get-AppPid $Name
    if ($existing) { Write-Ok "$Name already running (PID $existing)"; return }
    $log = Join-Path $LogDir "$Name.log"
    # cmd /s /c "...": one console-less process tree whose stdout+stderr go to one log file.
    $inner = "$CommandLine > `"$log`" 2>&1"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/d /s /c `"$inner`"" -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru
    Set-Content -Path (Join-Path $PidDir "$Name.pid") -Value "$($proc.Id)|$($proc.StartTime.Ticks)"
    Write-Ok "$Name started (PID $($proc.Id)), log: .dev\logs\$Name.log"
}

function Stop-App([string]$Name) {
    $appPid = Get-AppPid $Name
    if (-not $appPid) { Write-Ok "$Name not running"; return }
    Invoke-Native "taskkill.exe" @("/T", "/F", "/PID", "$appPid") | Out-Null
    Remove-Item (Join-Path $PidDir "$Name.pid") -Force -ErrorAction SilentlyContinue
    Write-Ok "$Name stopped"
}

function Wait-Http([string]$Url, [int]$TimeoutSeconds, [string]$Label) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            # Generous per-request timeout: the first Next.js page compile is slow.
            $res = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
            if ($res.StatusCode -lt 500) { Write-Ok "$Label is up ($Url)"; return $true }
        } catch {
            $response = $null
            if ($_.Exception.PSObject.Properties["Response"]) { $response = $_.Exception.Response }
            if ($response -and [int]$response.StatusCode -lt 500) { Write-Ok "$Label is up ($Url)"; return $true }
        }
        Start-Sleep -Seconds 2
    }
    Write-Warn2 "$Label did not answer within $TimeoutSeconds s. Check: .\scripts\dev.ps1 logs $($Label.ToLower())"
    return $false
}

function Assert-PortFree([int]$Port, [string]$Name) {
    if ((Get-AppPid $Name)) { return }
    if (Test-PortOpen $Port) {
        throw "Port $Port is in use by $(Get-PortOwner $Port). Stop that process first (it is not managed by this script)."
    }
}

# --- commands -----------------------------------------------------------------

function Invoke-Setup {
    $basePython = Assert-Prerequisites
    Initialize-EnvFiles

    Write-Step "Backend virtualenv + dependencies"
    $py = Initialize-Venv $BackendDir @(".venv", "leet_venv", "venv") ".venv" $basePython
    Invoke-Checked $py @("-m", "pip", "install", "--disable-pip-version-check", "-q", "-r", "requirements.txt") $BackendDir

    Write-Step "Judge virtualenv + dependencies"
    $jpy = Initialize-Venv $JudgeDir @("venv", ".venv") "venv" $basePython
    Invoke-Checked $jpy @("-m", "pip", "install", "--disable-pip-version-check", "-q", "-r", "requirements.txt", "-r", "requirements-dev.txt") $JudgeDir

    Write-Step "Frontend dependencies"
    if ($Reinstall -or -not (Test-Path (Join-Path $FrontendDir "node_modules"))) {
        Invoke-Checked "npm" @("ci", "--no-audit", "--no-fund") $FrontendDir
    } else { Write-Ok "node_modules present (use -Reinstall for a clean npm ci)" }

    Start-Infra
    Invoke-Migrate
    Invoke-Seed
    if (-not $SkipImages) { Build-JudgeImages }

    Write-Host ""
    Write-Step "Setup complete. Start everything with:  .\scripts\dev.ps1 dev"
}

function Invoke-Migrate {
    Write-Step "Applying migrations (dev database)"
    Invoke-Checked (Require-BackendPython) @("manage.py", "migrate", "--noinput") $BackendDir
}

function Invoke-Seed {
    Write-Step "Seeding sample data"
    Invoke-Checked (Require-BackendPython) @("manage.py", "seed_data") $BackendDir
}

function Invoke-Dev {
    if (-not (Test-Path (Join-Path $BackendDir ".env"))) { throw "backend\.env missing. Run: .\scripts\dev.ps1 setup" }
    $py = Require-BackendPython
    $free = Get-FreeCommitMB
    if ($free -ge 0 -and $free -lt 2048) { Write-Warn2 "Only $free MB of memory is free; the frontend dev server needs ~1-2 GB." }

    Start-Infra
    Assert-PortFree $BackendPort "backend"
    if (-not $NoFrontend) { Assert-PortFree $FrontendPort "frontend" }

    Write-Step "Starting app processes"
    Start-App "backend" "set PYTHONUNBUFFERED=1&& `"$py`" -m uvicorn config.asgi:application --host 127.0.0.1 --port $BackendPort --reload --reload-dir apps --reload-dir config" $BackendDir
    if (-not $NoWorker) {
        $jpy = Get-JudgePython
        if ($jpy) {
            Start-App "worker" "set PYTHONUNBUFFERED=1&& `"$jpy`" worker.py" $JudgeDir
        } else { Write-Warn2 "judge virtualenv missing: submissions will stay queued. Run setup." }
    }
    if (-not $NoFrontend) {
        Start-App "frontend" "set NEXT_TELEMETRY_DISABLED=1&& npm run dev -- --port $FrontendPort" $FrontendDir
    }

    Wait-Http "http://localhost:$BackendPort/api/health/?live=1" 90 "Backend" | Out-Null
    if (-not $NoFrontend) { Wait-Http "http://localhost:$FrontendPort/" 180 "Frontend" | Out-Null }

    Write-Host ""
    Write-Step "Ready"
    Write-Host "    App           http://localhost:$FrontendPort"
    Write-Host "    API           http://localhost:$BackendPort/api/   (health: /api/health/)"
    Write-Host "    Django admin  http://localhost:$BackendPort/django-admin/"
    Write-Host "    RabbitMQ UI   http://localhost:15673  (codequest / codequest_dev)"
    Write-Host "    Logs          .\scripts\dev.ps1 logs backend|worker|frontend -Follow"
    Write-Host "    Stop          .\scripts\dev.ps1 stop"
}

function Invoke-Stop {
    # `stop` = everything; `stop frontend` (or backend/worker) = just that process.
    $valid = @("frontend", "worker", "backend")
    if ($Rest.Count -gt 0) {
        foreach ($name in $Rest) {
            if ($valid -notcontains $name) { throw "Unknown component '$name' (use: $($valid -join ', '))" }
            Stop-App $name
        }
        return
    }
    Write-Step "Stopping app processes"
    foreach ($name in $valid) { Stop-App $name }
    Write-Step "Stopping dev containers (data kept)"
    Invoke-Compose @("stop")
}

function Invoke-Status {
    Write-Step "Containers ($Project)"
    $rows = Invoke-Native "docker" @("compose", "-p", $Project, "-f", $ComposeFile, "ps", "--format", "table {{.Service}}\t{{.State}}\t{{.Status}}")
    if ($rows.Out) { $rows.Out | ForEach-Object { Write-Host "    $_" } }
    Write-Step "App processes"
    foreach ($name in "backend", "worker", "frontend") {
        $appPid = Get-AppPid $name
        if ($appPid) { Write-Ok "$name running (PID $appPid)" } else { Write-Warn2 "$name not running" }
    }
    Write-Step "Health"
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$BackendPort/api/health/" -TimeoutSec 5
        $line = ($health.checks.PSObject.Properties | ForEach-Object { "$($_.Name)=$(if ($_.Value.ok) { 'ok' } else { 'DOWN' })" }) -join "  "
        Write-Ok "$($health.status): $line"
    } catch { Write-Warn2 "API not reachable on http://localhost:$BackendPort" }
}

function Invoke-Logs {
    $names = @("backend", "worker", "frontend")
    if ($Rest.Count -gt 0) { $names = @($Rest[0]) }
    foreach ($name in $names) {
        $log = Join-Path $LogDir "$name.log"
        if (-not (Test-Path $log)) { Write-Warn2 "no log yet for $name"; continue }
        Write-Step "$name ($log)"
        if ($Follow -and $names.Count -eq 1) { Get-Content $log -Tail 40 -Wait } else { Get-Content $log -Tail 25 }
    }
}

function Invoke-Test {
    $failed = @()
    Write-Step "Backend tests"
    $py = Require-BackendPython
    $saved = $env:DJANGO_SETTINGS_MODULE
    Remove-Item Env:DJANGO_SETTINGS_MODULE -ErrorAction SilentlyContinue
    Push-Location $BackendDir
    try { if ((Invoke-Relaxed $py @("-m", "pytest", "-q")) -ne 0) { $failed += "backend" } } finally {
        Pop-Location
        if ($saved) { $env:DJANGO_SETTINGS_MODULE = $saved }
    }

    Write-Step "Judge tests (unit; Docker tests run when the daemon and images are available)"
    $jpy = Get-JudgePython
    if ($jpy) {
        Push-Location $JudgeDir
        try { if ((Invoke-Relaxed $jpy @("-m", "pytest", "-q")) -ne 0) { $failed += "judge" } } finally { Pop-Location }
    } else { Write-Warn2 "judge virtualenv missing (run setup)"; $failed += "judge(missing venv)" }

    Write-Step "Frontend type-check + lint"
    Push-Location $FrontendDir
    try {
        if ((Invoke-Relaxed "npx.cmd" @("--no-install", "tsc", "--noEmit")) -ne 0) { $failed += "frontend-tsc" }
        if ((Invoke-Relaxed "npm.cmd" @("run", "--silent", "lint")) -ne 0) { $failed += "frontend-lint" }
    } finally { Pop-Location }

    Write-Host ""
    if ($failed.Count -eq 0) { Write-Step "All checks passed" } else { Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
}

function Invoke-Manage {
    if ($Rest.Count -eq 0) { throw "Usage: .\scripts\dev.ps1 manage <command> [args]" }
    Invoke-Checked (Require-BackendPython) (@("manage.py") + $Rest) $BackendDir
}

function Invoke-ResetData {
    Confirm-Typed "RESET" "This deletes ALL data of the dev stack (compose project '$Project': Postgres, Redis, RabbitMQ volumes), then recreates it with sample data. Nothing else is touched."
    foreach ($name in "frontend", "worker", "backend") { Stop-App $name }
    Write-Step "Removing dev containers and volumes ($Project)"
    Invoke-Compose @("down", "-v", "--remove-orphans")
    Start-Infra
    Invoke-Migrate
    Invoke-Seed
    Write-Step "Dev data reset complete"
}

function Invoke-CleanupOld {
    Write-Step "Looking for the old 'infra' compose stack"
    $found = @()
    foreach ($name in $OldContainers) {
        # Parse JSON instead of --format templates (PowerShell 5.1 strips embedded quotes).
        $inspect = Invoke-Native "docker" @("inspect", $name)
        if ($inspect.Code -ne 0 -or -not $inspect.Out) { continue }
        $labels = (($inspect.Out | Out-String) | ConvertFrom-Json)[0].Config.Labels
        if ($labels -and $labels.PSObject.Properties["com.docker.compose.project"] -and
            $labels."com.docker.compose.project" -eq "infra") { $found += $name }
    }
    if ($found.Count -eq 0) { Write-Ok "no old containers found" } else {
        $listing = Invoke-Native "docker" @("ps", "-a", "--filter", "label=com.docker.compose.project=infra", "--format", "table {{.Names}}\t{{.Image}}\t{{.Status}}")
        if ($listing.Out) { $listing.Out | ForEach-Object { Write-Host "    $_" } }
        Confirm-Typed "REMOVE" "Remove these old containers? Their data volumes are kept."
        foreach ($name in $found) {
            if ((Invoke-Native "docker" @("rm", "-f", $name)).Code -eq 0) { Write-Ok "removed container $name" }
            else { Write-Warn2 "could not remove $name" }
        }
    }

    if (-not $IncludeVolumes) {
        Write-Ok "volumes kept: $($OldVolumes -join ', ') (pass -IncludeVolumes to delete them)"
        return
    }
    $volumes = @()
    foreach ($volume in $OldVolumes) {
        $inspect = Invoke-Native "docker" @("volume", "inspect", $volume)
        if ($inspect.Code -ne 0 -or -not $inspect.Out) { continue }
        $labels = (($inspect.Out | Out-String) | ConvertFrom-Json)[0].Labels
        if ($labels -and $labels.PSObject.Properties["com.docker.compose.project"] -and
            $labels."com.docker.compose.project" -eq "infra") { $volumes += $volume }
    }
    if ($volumes.Count -eq 0) { Write-Ok "no old volumes found"; return }
    Confirm-Typed "DELETE-VOLUMES" "PERMANENTLY delete these volumes and all data in them: $($volumes -join ', ')"
    foreach ($volume in $volumes) {
        if ((Invoke-Native "docker" @("volume", "rm", $volume)).Code -eq 0) { Write-Ok "deleted volume $volume" }
        else { Write-Warn2 "could not delete $volume (in use?)" }
    }
}

function Show-Help { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host }

switch ($Command.ToLower()) {
    "setup"       { Invoke-Setup }
    "dev"         { Invoke-Dev }
    "start"       { Invoke-Dev }
    "stop"        { Invoke-Stop }
    "status"      { Invoke-Status }
    "logs"        { Invoke-Logs }
    "test"        { Invoke-Test }
    "migrate"     { Invoke-Migrate }
    "seed"        { Invoke-Seed }
    "manage"      { Invoke-Manage }
    "reset-data"  { Invoke-ResetData }
    "cleanup-old" { Invoke-CleanupOld }
    default       { Show-Help }
}

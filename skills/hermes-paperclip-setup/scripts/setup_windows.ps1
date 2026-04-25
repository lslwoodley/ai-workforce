#Requires -Version 5.1
# setup_windows.ps1 — Idempotent setup for the Hermes + Paperclip AI workforce stack
#
# Designed to be run multiple times safely:
#   - Already-installed software is detected and skipped
#   - Already-running services are left untouched
#   - Existing .env is never overwritten
#   - Each step reports DONE / SKIP / FAIL clearly
#
# Prerequisites: Windows 10 build 19041+ or Windows 11
# Run in PowerShell (NOT as Administrator unless Docker Desktop install is needed)
#
# Usage:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\scripts\setup_windows.ps1

[CmdletBinding()]
param(
    [switch]$Force,      # Force rebuild even if images exist
    [switch]$SkipBuild   # Skip docker compose build (use existing images)
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ══════════════════════════════════════════════════════════════════════════════
# Colour output helpers
# ══════════════════════════════════════════════════════════════════════════════

function Write-Step  { param($msg) Write-Host "`n[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Done  { param($msg) Write-Host "  [DONE] $msg" -ForegroundColor Green;  $script:StepLog += "[DONE] $msg" }
function Write-Skip  { param($msg) Write-Host "  [SKIP] $msg" -ForegroundColor DarkCyan; $script:StepLog += "[SKIP] $msg" }
function Write-Info  { param($msg) Write-Host "        $msg" -ForegroundColor DarkGray }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:StepLog += "[WARN] $msg" }

function Write-Fail {
    param($msg, $Fix = $null)
    Write-Host ""
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    if ($Fix) {
        Write-Host ""
        Write-Host "  Fix:" -ForegroundColor Yellow
        Write-Host "    $Fix" -ForegroundColor Yellow
    }
    Write-Summary
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Global error trap
# ══════════════════════════════════════════════════════════════════════════════

$script:StepLog = @()

trap {
    $err = $_.Exception.Message
    $pos = $_.InvocationInfo.PositionMessage
    Write-Host ""
    Write-Host "════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  UNEXPECTED ERROR" -ForegroundColor Red
    Write-Host "════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  Error  : $err" -ForegroundColor Red
    Write-Host "  Where  : $pos" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Diagnostics:" -ForegroundColor Yellow
    Write-Host "    docker compose logs --tail 30"
    Write-Host "    docker compose ps"
    Write-Host ""
    Write-Host "  Reference docs: references\windows.md" -ForegroundColor Yellow
    Write-Summary
    exit 1
}

function Write-Summary {
    if ($script:StepLog.Count -eq 0) { return }
    Write-Host ""
    Write-Host "════════════ Run Summary ════════════" -ForegroundColor Cyan
    foreach ($s in $script:StepLog) { Write-Host "  $s" }
    Write-Host "════════════════════════════════════" -ForegroundColor Cyan
}

# ══════════════════════════════════════════════════════════════════════════════
# Path setup
# ══════════════════════════════════════════════════════════════════════════════

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillDir  = Split-Path -Parent $ScriptDir
$DockerDir = Join-Path $SkillDir "docker"
$ComposeFile = Join-Path $DockerDir "docker-compose.yml"
$EnvFile     = Join-Path $DockerDir ".env"
$EnvExample  = Join-Path $DockerDir ".env.example"

# ══════════════════════════════════════════════════════════════════════════════
# Helper functions
# ══════════════════════════════════════════════════════════════════════════════

function Test-CommandExists { param($cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Test-DockerRunning {
    try { docker info 2>&1 | Out-Null; return $LASTEXITCODE -eq 0 } catch { return $false }
}

function Test-PortInUse {
    param([int]$Port)
    $result = netstat -ano 2>$null | Select-String ":$Port\s"
    return [bool]$result
}

function Test-PortOwnedByOurStack {
    param([int]$Port, [string]$ServiceName)
    try {
        $ps = docker compose -f $ComposeFile ps --format json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        return ($ps | Where-Object { $_.Name -like "*$ServiceName*" -and $_.State -eq "running" }).Count -gt 0
    } catch { return $false }
}

function Assert-Port {
    param([int]$Port, [string]$ServiceName, [string]$EnvVarName)
    if (Test-PortInUse $Port) {
        if (Test-PortOwnedByOurStack $Port $ServiceName) {
            Write-Skip "Port $Port in use by our $ServiceName container — OK"
        } else {
            $proc = netstat -ano 2>$null | Select-String ":$Port\s" | Select-Object -First 1
            Write-Fail "Port $Port is already in use." "Change $EnvVarName in $EnvFile, then re-run.`n    In use by: $proc"
        }
    }
}

function Wait-ForUrl {
    param([string]$Url, [string]$Label, [int]$MaxAttempts = 24, [int]$IntervalSec = 5)
    Write-Info "Waiting for $Label..."
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return }
        } catch {}
        if ($i -eq $MaxAttempts) {
            Write-Fail "$Label did not respond after $($MaxAttempts * $IntervalSec)s." "Run: docker compose logs --tail 30"
        }
        Write-Info "  Attempt $i/$MaxAttempts..."
        Start-Sleep $IntervalSec
    }
}

function Invoke-DockerCompose {
    param([string[]]$Args)
    $result = & docker compose -f $ComposeFile @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $result -ForegroundColor Red
        Write-Fail "docker compose $($Args -join ' ') failed (exit $LASTEXITCODE)."
    }
    return $result
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Hermes + Paperclip — Stack Setup (Windows)  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Docker dir : $DockerDir"
Write-Host "  User       : $env:USERNAME"
Write-Host "  OS         : $([System.Environment]::OSVersion.VersionString)"
Write-Host ""

# ── Step 1: Windows version ───────────────────────────────────────────────────
Write-Step "Checking Windows version"
$build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
if ([int]$build -lt 19041) {
    Write-Fail "Windows build $build is too old. Need build 19041+ (Windows 10 20H1 or Windows 11)."
}
Write-Done "Windows build $build — supported"

# ── Step 2: WSL2 ─────────────────────────────────────────────────────────────
Write-Step "Checking WSL2"
try {
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Skip "WSL2 already installed"
    } else { throw }
} catch {
    Write-Warn "WSL2 not detected. Installing..."
    try {
        wsl --install --no-distribution 2>&1
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "  ║  ACTION REQUIRED: WSL2 installed — REBOOT required.  ║" -ForegroundColor Yellow
        Write-Host "  ║  After reboot, re-run this script to continue.       ║" -ForegroundColor Yellow
        Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Summary
        exit 0
    } catch {
        Write-Fail "Could not install WSL2 automatically." "Run PowerShell as Administrator and try: wsl --install`nOr see: https://learn.microsoft.com/en-us/windows/wsl/install"
    }
}

# ── Step 3: Docker Desktop ────────────────────────────────────────────────────
Write-Step "Checking Docker Desktop"
$dockerInstalled = Test-CommandExists "docker"
$dockerDesktopPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$dockerDesktopExists = Test-Path $dockerDesktopPath

if ($dockerInstalled -and $dockerDesktopExists) {
    Write-Skip "Docker Desktop already installed ($(docker --version 2>$null))"
} elseif (-not $dockerDesktopExists) {
    Write-Warn "Docker Desktop not found."
    $choice = Read-Host "  Download and install Docker Desktop now? [Y/n]"
    if ($choice -eq "n") {
        Write-Fail "Docker Desktop is required." "Download from: https://www.docker.com/products/docker-desktop/"
    }

    $installer = "$env:TEMP\DockerDesktopInstaller.exe"
    $url = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"

    if (-not (Test-Path $installer)) {
        Write-Info "Downloading Docker Desktop installer (~600 MB)..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
        } catch {
            Write-Fail "Download failed: $_" "Download manually from: $url"
        }
    } else {
        Write-Info "Installer already downloaded at $installer — reusing"
    }

    Write-Info "Running installer (accept any UAC prompt)..."
    try {
        Start-Process $installer -ArgumentList "install --quiet --accept-license" -Wait -Verb RunAs
    } catch {
        Write-Fail "Installer failed: $_" "Run the installer manually: $installer"
    }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║  Docker Desktop installed — RESTART required.        ║" -ForegroundColor Yellow
    Write-Host "  ║  After restart, re-run this script.                  ║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Summary
    exit 0
}

# ── Step 4: Docker daemon running ─────────────────────────────────────────────
Write-Step "Checking Docker daemon"
if (Test-DockerRunning) {
    Write-Skip "Docker daemon already running"
} else {
    Write-Info "Starting Docker Desktop..."
    try { Start-Process $dockerDesktopPath } catch {
        Write-Fail "Could not start Docker Desktop." "Start it manually from the Start menu, then re-run."
    }

    Write-Info "Waiting for Docker to start (up to 90 seconds)..."
    $attempts = 0
    while (-not (Test-DockerRunning)) {
        $attempts++
        if ($attempts -ge 18) {
            Write-Fail "Docker daemon did not start within 90 seconds." "Open Docker Desktop manually, wait for the whale icon in the taskbar, then re-run."
        }
        Start-Sleep 5
        Write-Info "  Attempt $attempts/18..."
    }
    Write-Done "Docker daemon started"
}

# ── Step 5: Docker Compose ────────────────────────────────────────────────────
Write-Step "Checking Docker Compose"
try {
    docker compose version 2>&1 | Out-Null
    Write-Skip "Docker Compose available"
} catch {
    Write-Fail "Docker Compose not found." "Update Docker Desktop to the latest version — it bundles Docker Compose."
}

# ── Step 6: Git ───────────────────────────────────────────────────────────────
Write-Step "Checking Git"
if (Test-CommandExists "git") {
    Write-Skip "Git already installed ($(git --version 2>$null))"
} else {
    Write-Fail "Git not found." "Install from: https://git-scm.com/download/win"
}

# ── Step 7: Docker Desktop file sharing ───────────────────────────────────────
Write-Step "Checking Docker Desktop file sharing"
$driveLetter = Split-Path -Qualifier $DockerDir
Write-Warn "Docker Desktop must share the drive containing this project."
Write-Host ""
Write-Host "  Verify in Docker Desktop → Settings → Resources → File Sharing:"
Write-Host "  Drive to share: $driveLetter" -ForegroundColor Cyan
Write-Host ""
Write-Host "  If $driveLetter is not listed: add it, click 'Apply & Restart', then re-run."
Read-Host "  Press Enter when file sharing is confirmed"
Write-Done "File sharing confirmed by user"

# ── Step 8: Environment file ──────────────────────────────────────────────────
Write-Step "Checking environment file"

if (-not (Test-Path $EnvExample)) {
    Write-Fail ".env.example not found at $EnvExample" "Are you running from the skill directory?"
}

if (Test-Path $EnvFile) {
    Write-Skip ".env already exists — not overwriting"
} else {
    Copy-Item $EnvExample $EnvFile
    Write-Host ""
    Write-Host "  ╔═════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║  ACTION REQUIRED: Edit .env with your API keys.     ║" -ForegroundColor Yellow
    Write-Host "  ║                                                     ║" -ForegroundColor Yellow
    Write-Host "  ║  Add at least one of:                               ║" -ForegroundColor Yellow
    Write-Host "  ║    OPENROUTER_API_KEY=sk-or-...                     ║" -ForegroundColor Yellow
    Write-Host "  ║    ANTHROPIC_API_KEY=sk-ant-...                     ║" -ForegroundColor Yellow
    Write-Host "  ║    OPENAI_API_KEY=sk-...                            ║" -ForegroundColor Yellow
    Write-Host "  ╚═════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Info "Opening .env in Notepad..."
    Start-Process notepad -ArgumentList $EnvFile -Wait
}

# ── Step 9: Validate .env ─────────────────────────────────────────────────────
Write-Step "Validating .env"
$envContent = Get-Content $EnvFile -Raw
$keyFound = $false
foreach ($key in @("OPENROUTER_API_KEY","ANTHROPIC_API_KEY","OPENAI_API_KEY")) {
    if ($envContent -match "(?m)^${key}=sk-\S+") {
        Write-Done "$key is set"
        $keyFound = $true
    }
}
if (-not $keyFound) {
    Write-Warn "No model API key found. Agents will fail to execute tasks."
    $script:StepLog += "[WARN] No model API key - add one to $EnvFile"
}

# Load .env values
$envVars = @{}
Get-Content $EnvFile | Where-Object { $_ -match "^[^#].*=.*" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $envVars[$parts[0].Trim()] = $parts[1].Trim()
}
$PaperclipPort = if ($envVars["PAPERCLIP_PORT"]) { $envVars["PAPERCLIP_PORT"] } else { "3100" }
$McpPort       = if ($envVars["MCP_SERVER_PORT"]) { $envVars["MCP_SERVER_PORT"] } else { "8765" }

# ── Step 10: Port availability ────────────────────────────────────────────────
Write-Step "Checking port availability"
Assert-Port -Port ([int]$PaperclipPort) -ServiceName "paperclip"  -EnvVarName "PAPERCLIP_PORT"
Assert-Port -Port ([int]$McpPort)       -ServiceName "mcp-server" -EnvVarName "MCP_SERVER_PORT"
Write-Skip "Ports $PaperclipPort and $McpPort are available"

# ── Step 11: Build images ─────────────────────────────────────────────────────
Write-Step "Checking Docker images"
Push-Location $DockerDir

$needsBuild = $Force

if (-not $SkipBuild) {
    foreach ($svc in @("hermes-worker", "mcp-server", "paperclip")) {
        $img = docker compose -f $ComposeFile images -q $svc 2>$null
        if (-not $img) {
            Write-Info "Image for '$svc' not found — will build"
            $needsBuild = $true
        } else {
            Write-Skip "Image for '$svc' already built"
        }
    }

    if ($needsBuild) {
        Write-Info "Building images (first build: 5-10 minutes)..."
        $buildArgs = @("compose", "-f", $ComposeFile, "build", "--progress=plain")
        if ($Force) { $buildArgs += "--no-cache" }

        & docker @buildArgs 2>&1 | ForEach-Object {
            if ($_ -match "(Step|Successfully|ERROR|error)") {
                Write-Host "        $_" -ForegroundColor DarkGray
            }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "docker compose build failed." "Run manually with: docker compose build --no-cache"
        }
        Write-Done "Images built"
    }
}

# ── Step 12: Start the stack ──────────────────────────────────────────────────
Write-Step "Starting the stack"
$running = docker compose -f $ComposeFile ps --status running 2>$null | Measure-Object -Line | Select-Object -ExpandProperty Lines
# subtract 1 for header line
$runningCount = [Math]::Max(0, $running - 1)

if ($runningCount -ge 3) {
    Write-Skip "All 3 services already running"
} else {
    Write-Info "Starting containers..."
    Invoke-DockerCompose @("up", "-d", "--remove-orphans")
    Write-Done "Stack started"
}

Pop-Location

# ── Step 13: Wait for health ──────────────────────────────────────────────────
Write-Step "Waiting for services to be healthy"
Wait-ForUrl "http://localhost:$PaperclipPort/api/health" "Paperclip" 24 5
Wait-ForUrl "http://localhost:$McpPort/health" "MCP server" 12 5
Write-Done "All services healthy"

# ── Step 14: Final verification ───────────────────────────────────────────────
Write-Step "Running verification"
try {
    $verifyOut = bash (Join-Path $ScriptDir "verify.sh") 2>&1
    if ($verifyOut -match "All checks passed") {
        Write-Done "All verification checks passed"
    } else {
        Write-Warn "Some verification checks may have failed. Run verify.sh for details."
        $script:StepLog += "[WARN] Verification had issues"
    }
} catch {
    Write-Warn "verify.sh requires WSL or Git Bash. Run it manually: bash scripts/verify.sh"
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║        Setup complete — stack is running          ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Paperclip UI   http://localhost:$PaperclipPort" -ForegroundColor Cyan
Write-Host "  MCP server     http://localhost:$McpPort" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Useful commands:"
Write-Host "    docker compose logs -f                  # live logs"
Write-Host "    docker compose logs hermes-worker -f    # agent activity"
Write-Host "    docker compose restart hermes-worker    # restart workers"
Write-Host "    docker compose down                     # stop stack"
Write-Host "    docker compose down -v                  # stop + wipe data"
Write-Host ""
Write-Summary

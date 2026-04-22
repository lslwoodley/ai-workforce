#Requires -Version 5.1
# init_github.ps1 - One-time setup: initialise git, create the private GitHub repo,
# configure branch protection, and push everything.
#
# Usage (from the project root):
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\scripts\init_github.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function step { param($m) Write-Host "`n[>>] $m" -ForegroundColor Cyan }
function ok   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function warn { param($m) Write-Host "  [!!] $m" -ForegroundColor Yellow }
function info { param($m) Write-Host "       $m" -ForegroundColor DarkGray }
function fail {
    param($m, $fix = "")
    Write-Host "`n  [XX] $m" -ForegroundColor Red
    if ($fix) { Write-Host "  Fix: $fix" -ForegroundColor Yellow }
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "Checking prerequisites"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    fail "git not found." "Install from: https://git-scm.com/download/win"
}
ok "$(git --version)"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    fail "GitHub CLI not found." "Install: winget install GitHub.cli  Then open a new PowerShell and run: gh auth login"
}
ok "$(gh --version | Select-Object -First 1)"

$authCheck = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    fail "Not logged into GitHub CLI." "Run: gh auth login"
}
$GithubUser = (gh api user --jq .login).Trim()
ok "Authenticated as: $GithubUser"

# ── Step 2: Repo name ─────────────────────────────────────────────────────────
step "Repository configuration"

$RepoName = (Read-Host "  Repository name [Enter for 'ai-workforce']").Trim()
if (-not $RepoName) { $RepoName = "ai-workforce" }

$RepoDesc = (Read-Host "  Description [Enter for default]").Trim()
if (-not $RepoDesc) { $RepoDesc = "Private AI company infrastructure: Hermes Agent + Paperclip" }

$RepoFull = "$GithubUser/$RepoName"
ok "Will create: github.com/$RepoFull (private)"

# ── Step 3: git init ──────────────────────────────────────────────────────────
step "Initialising local git repository"
Push-Location $RepoRoot

$alreadyGit    = Test-Path (Join-Path $RepoRoot ".git")
$alreadyRemote = $false

if ($alreadyGit) {
    try {
        $null = & git remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0) { $alreadyRemote = $true }
    } catch { $alreadyRemote = $false }
}

if ($alreadyGit) {
    ok "git already initialised - skipping"
} else {
    git init -b main
    ok "Initialised git (branch: main)"
}

# ── Step 4: Initial commit ────────────────────────────────────────────────────
step "Creating initial commit"

# Re-normalise line endings now that .gitattributes is in place.
# This fixes the LF->CRLF warnings and ensures shell scripts stay LF.
git add .gitattributes
git add -A
git rm --cached -r . -q 2>$null
git reset --hard 2>$null
git add -A

# Check if there is already a commit (fails on a brand-new empty repo)
$hasCommit = $false
try {
    $null = & git rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $hasCommit = $true }
} catch { $hasCommit = $false }

if ($hasCommit) {
    $staged = (git diff --cached --name-only | Measure-Object -Line).Lines
    if ($staged -gt 0) {
        git commit -m "chore: add $staged new/updated files"
        ok "Committed $staged file(s)"
    } else {
        ok "Nothing new to commit - working tree clean"
    }
} else {
    git commit -m "feat: initial AI workforce infrastructure"
    ok "Created initial commit"
}

# ── Step 5: Create GitHub repo ────────────────────────────────────────────────
step "Creating private GitHub repository"

if ($alreadyRemote) {
    $existingRemote = (git remote get-url origin).Trim()
    ok "Remote 'origin' already set to: $existingRemote - skipping"
} else {
    $repoCheck = gh repo view $RepoFull 2>&1
    $repoExists = ($LASTEXITCODE -eq 0)

    if (-not $repoExists) {
        gh repo create $RepoFull --private --description $RepoDesc --disable-wiki
        ok "Created: https://github.com/$RepoFull"
    } else {
        warn "Repo $RepoFull already exists on GitHub - skipping creation"
    }

    git remote add origin "https://github.com/$RepoFull.git"
    ok "Remote 'origin' set to: https://github.com/$RepoFull.git"
}

# ── Step 6: Push ──────────────────────────────────────────────────────────────
step "Pushing to GitHub"
git push -u origin main
ok "Pushed to: https://github.com/$RepoFull"

# ── Step 7: Branch protection ─────────────────────────────────────────────────
step "Configuring branch protection on 'main'"

$tmpJson = Join-Path $env:TEMP "gh-protection.json"
'{"required_status_checks":{"strict":true,"contexts":[]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":1,"dismiss_stale_reviews":true},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' | Set-Content $tmpJson -Encoding utf8
$protectOut = gh api --method PUT "/repos/$RepoFull/branches/main/protection" --input $tmpJson 2>&1
Remove-Item $tmpJson -ErrorAction SilentlyContinue

if ($LASTEXITCODE -eq 0) {
    ok "Branch protection enabled on 'main'"
} else {
    warn "Branch protection skipped (may need a paid plan)"
    warn "Enable manually: https://github.com/$RepoFull/settings/branches"
}

# ── Step 8: Labels ────────────────────────────────────────────────────────────
step "Creating labels"

$labelOut = gh label create "agent-work" --color "0075ca" --description "Work committed by an AI agent - requires human review" --repo $RepoFull 2>&1
if ($LASTEXITCODE -eq 0) {
    ok "Label 'agent-work' created"
} else {
    ok "Label 'agent-work' already exists"
}

# ── Step 9: Secrets guidance ──────────────────────────────────────────────────
step "GitHub Actions secrets needed"

Write-Host ""
Write-Host "  Add these at:" -ForegroundColor White
Write-Host "  https://github.com/$RepoFull/settings/secrets/actions" -ForegroundColor Cyan
Write-Host ""
Write-Host "  GHCR_TOKEN      - GitHub PAT with write:packages scope" -ForegroundColor White
Write-Host "    Create at: https://github.com/settings/tokens/new" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  AGENT_GIT_TOKEN - Fine-grained PAT: Contents read+write on this repo only" -ForegroundColor White
Write-Host "    Create at: https://github.com/settings/personal-access-tokens/new" -ForegroundColor DarkGray
Write-Host ""

$openBrowser = (Read-Host "  Open secrets settings in browser? [Y/n]").Trim()
if ($openBrowser -ne "n") {
    Start-Process "https://github.com/$RepoFull/settings/secrets/actions"
}

# ── Step 10: Patch .env ───────────────────────────────────────────────────────
step "Updating .env with agent git configuration"

$envFile = Join-Path $RepoRoot "skills\hermes-paperclip-setup\docker\.env"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile -Raw
    if ($envContent -notmatch "AGENT_GIT_TOKEN") {
        $agentVars = @"

# Agent GitHub workspace
AGENT_GIT_TOKEN=
AGENT_GIT_USER=ai-workforce-bot
AGENT_GIT_EMAIL=agents@localhost
AGENT_REPO_URL=https://github.com/$RepoFull
AGENT_WORKSPACE_PATH=../../../

# CI/CD image registry
GITHUB_USERNAME=$GithubUser
"@
        Add-Content $envFile $agentVars
        ok "Added agent git vars to .env - fill in AGENT_GIT_TOKEN"
    } else {
        ok "Agent git vars already in .env"
    }
} else {
    warn ".env not found at $envFile - run the setup script first"
}

Pop-Location

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Repository ready!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Repo     https://github.com/$RepoFull" -ForegroundColor Cyan
Write-Host "  Actions  https://github.com/$RepoFull/actions" -ForegroundColor Cyan
Write-Host "  Secrets  https://github.com/$RepoFull/settings/secrets/actions" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Add GHCR_TOKEN secret  -> CI builds images on every push to main"
Write-Host "  2. Add AGENT_GIT_TOKEN and fill it into .env -> agents can commit work"
Write-Host "  3. git push origin main   -> triggers the first CI run"
Write-Host ""
Write-Host "  Useful commands:"
Write-Host "  git push origin main           - push changes + trigger CI"
Write-Host "  gh run list                    - check CI status"
Write-Host "  gh pr list --label agent-work  - see agent PRs awaiting review"

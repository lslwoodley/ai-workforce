#!/usr/bin/env bash
# init_github.sh — One-time setup: initialise git, create the private GitHub repo,
#                  configure branch protection, and push everything.
#
# Run this ONCE from the project root on your local machine (not inside a container).
# After this, normal git push / pull workflows apply.
#
# Prerequisites:
#   - git installed
#   - gh (GitHub CLI) installed: https://cli.github.com/
#   - Logged into gh: gh auth login
#
# Usage:
#   chmod +x scripts/init_github.sh
#   ./scripts/init_github.sh

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${BOLD}${CYAN}[>>]${NC} $1"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }
ask()   { echo -e "  ${YELLOW}?${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Idempotency guard ─────────────────────────────────────────────────────────
# Track what we've done so re-running is safe
ALREADY_HAS_GIT=false
ALREADY_HAS_REMOTE=false
[[ -d "$REPO_ROOT/.git" ]] && ALREADY_HAS_GIT=true
git -C "$REPO_ROOT" remote get-url origin &>/dev/null 2>&1 && ALREADY_HAS_REMOTE=true

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   AI Workforce — GitHub Repository Setup     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "Checking prerequisites"

command -v git &>/dev/null || fail "git not found. Install from: https://git-scm.com/"
ok "git $(git --version | grep -oP '\d+\.\d+\.\d+')"

if ! command -v gh &>/dev/null; then
    fail "GitHub CLI (gh) not found.\n  Install from: https://cli.github.com/\n  Then run: gh auth login"
fi
ok "gh $(gh --version | head -1 | grep -oP '\d+\.\d+\.\d+')"

if ! gh auth status &>/dev/null; then
    fail "Not logged into GitHub CLI.\n  Run: gh auth login\n  Choose: GitHub.com → HTTPS → Paste an authentication token"
fi
GITHUB_USER=$(gh api user --jq .login)
ok "Authenticated as: $GITHUB_USER"

# ── Step 2: Repository name ───────────────────────────────────────────────────
step "Repository configuration"
ask "Repository name (press Enter for 'ai-workforce'):"
read -r REPO_NAME
REPO_NAME="${REPO_NAME:-ai-workforce}"

ask "Repository description (press Enter for default):"
read -r REPO_DESC
REPO_DESC="${REPO_DESC:-Private AI company infrastructure: Hermes Agent + Paperclip}"

REPO_FULL="${GITHUB_USER}/${REPO_NAME}"
ok "Will create: github.com/${REPO_FULL} (private)"

# ── Step 3: git init ──────────────────────────────────────────────────────────
step "Initialising local git repository"
cd "$REPO_ROOT"

if [[ "$ALREADY_HAS_GIT" == "true" ]]; then
    ok "git already initialised — skipping"
else
    git init -b main
    ok "Initialised git repository (branch: main)"
fi

# ── Step 4: Initial commit ────────────────────────────────────────────────────
step "Creating initial commit"

git add -A

# Check if there's already a commit
if git rev-parse HEAD &>/dev/null 2>&1; then
    STAGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
    if [[ "$STAGED" -gt 0 ]]; then
        git commit -m "chore: add $STAGED new/updated files"
        ok "Committed $STAGED file(s)"
    else
        ok "Nothing new to commit — working tree clean"
    fi
else
    git commit -m "feat: initial AI workforce infrastructure

- Architecture decision record (ADR-001)
- hermes-paperclip skill: manage Hermes + Paperclip integration
- hermes-paperclip-setup skill: Docker setup for Windows and Ubuntu
- GitHub Actions: build images to ghcr.io, agent workspace PRs
- Agent workspace directory structure"
    ok "Created initial commit"
fi

# ── Step 5: Create GitHub repo ────────────────────────────────────────────────
step "Creating private GitHub repository"

if [[ "$ALREADY_HAS_REMOTE" == "true" ]]; then
    EXISTING_REMOTE=$(git remote get-url origin)
    ok "Remote 'origin' already set to: $EXISTING_REMOTE — skipping repo creation"
else
    # Check if repo already exists on GitHub
    if gh repo view "$REPO_FULL" &>/dev/null 2>&1; then
        warn "Repository $REPO_FULL already exists on GitHub"
    else
        gh repo create "$REPO_FULL" \
            --private \
            --description "$REPO_DESC" \
            --disable-wiki \
            --disable-issues=false
        ok "Created: https://github.com/${REPO_FULL}"
    fi

    git remote add origin "https://github.com/${REPO_FULL}.git"
    ok "Remote 'origin' set to: https://github.com/${REPO_FULL}.git"
fi

# ── Step 6: Push ──────────────────────────────────────────────────────────────
step "Pushing to GitHub"

git push -u origin main
ok "Pushed to https://github.com/${REPO_FULL}"

# ── Step 7: Branch protection ─────────────────────────────────────────────────
step "Configuring branch protection for 'main'"

# Protect main: require PR review, prevent direct agent pushes to main
gh api \
  --method PUT \
  "/repos/${REPO_FULL}/branches/main/protection" \
  --field required_status_checks='{"strict":true,"contexts":[]}' \
  --field enforce_admins=false \
  --field required_pull_request_reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true}' \
  --field restrictions=null \
  --field allow_force_pushes=false \
  --field allow_deletions=false \
  2>/dev/null && ok "Branch protection enabled on 'main'" || \
  warn "Branch protection requires a paid plan or org. Enable manually: Settings → Branches → Add rule"

# ── Step 8: Repository labels ─────────────────────────────────────────────────
step "Creating labels"

# Create the 'agent-work' label used by the workflow
gh label create "agent-work" \
    --color "0075ca" \
    --description "Work committed by an AI agent — requires human review" \
    --repo "$REPO_FULL" \
    2>/dev/null && ok "Label 'agent-work' created" || \
    ok "Label 'agent-work' already exists"

# ── Step 9: GitHub Actions secret setup guidance ──────────────────────────────
step "GitHub Actions secrets"

echo ""
echo -e "  The CI/CD workflow needs these repository secrets."
echo -e "  ${BOLD}Set them at:${NC} https://github.com/${REPO_FULL}/settings/secrets/actions"
echo ""
echo -e "  ${BOLD}Required for image publishing:${NC}"
echo -e "    ${CYAN}GHCR_TOKEN${NC}  — GitHub PAT with 'write:packages' scope"
echo -e "    Create at: https://github.com/settings/tokens/new"
echo -e "    Select scopes: write:packages, read:packages, delete:packages"
echo ""
echo -e "  ${BOLD}Required for agent workspace commits:${NC}"
echo -e "    ${CYAN}AGENT_GIT_TOKEN${NC}  — Fine-grained PAT, repo write access only"
echo -e "    Create at: https://github.com/settings/personal-access-tokens/new"
echo -e "    Repository access: Only this repo → Contents: Read & Write"
echo ""

read -rp "  Open the secrets settings page in your browser now? [Y/n] " open_browser
if [[ "$open_browser" != "n" ]]; then
    # Try common ways to open a browser on Linux/macOS
    URL="https://github.com/${REPO_FULL}/settings/secrets/actions"
    xdg-open "$URL" 2>/dev/null || open "$URL" 2>/dev/null || \
        echo "  Open manually: $URL"
fi

# ── Step 10: Add secrets to .env reminder ────────────────────────────────────
step "Update your local .env"

ENV_FILE="$REPO_ROOT/skills/hermes-paperclip-setup/docker/.env"
if [[ -f "$ENV_FILE" ]]; then
    # Check if agent git vars already present
    if ! grep -q "AGENT_GIT_TOKEN" "$ENV_FILE"; then
        cat >> "$ENV_FILE" <<EOF

# ── Agent GitHub workspace ────────────────────────────────────────────────────
AGENT_GIT_TOKEN=           # Fine-grained PAT for agent commits (repo write)
AGENT_GIT_USER=ai-workforce-bot
AGENT_GIT_EMAIL=agents@localhost
AGENT_REPO_URL=https://github.com/${REPO_FULL}
AGENT_WORKSPACE_PATH=../../../  # Path to repo root (relative to docker-compose.yml)

# ── CI/CD image registry ──────────────────────────────────────────────────────
GITHUB_USERNAME=${GITHUB_USER}
EOF
        ok "Added agent git vars to .env — fill in AGENT_GIT_TOKEN"
    else
        ok "Agent git vars already in .env"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Repository ready!                                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Repo:${NC}       https://github.com/${REPO_FULL}"
echo -e "  ${BOLD}Actions:${NC}    https://github.com/${REPO_FULL}/actions"
echo -e "  ${BOLD}Secrets:${NC}    https://github.com/${REPO_FULL}/settings/secrets/actions"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "  1. Add GHCR_TOKEN secret → CI will build images on next push"
echo "  2. Add AGENT_GIT_TOKEN secret + fill it in .env → agents can commit"
echo "  3. docker compose ... up -d  → stack uses ghcr.io images in production"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "  git push origin main          # push changes + trigger CI"
echo "  gh run list                   # check CI status"
echo "  gh pr list --label agent-work # see agent PRs awaiting review"

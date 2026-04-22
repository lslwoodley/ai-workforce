#!/usr/bin/env bash
# setup_ubuntu.sh — Idempotent setup for the Hermes + Paperclip AI workforce stack
#
# Designed to be run multiple times safely:
#   - Already-installed software is detected and skipped
#   - Already-running services are left untouched
#   - Existing .env is never overwritten
#   - Each step reports DONE / SKIP / FAIL clearly
#
# Prerequisites: Ubuntu 20.04+ with sudo access (do NOT run as root)
#
# Usage:
#   chmod +x scripts/setup_ubuntu.sh
#   ./scripts/setup_ubuntu.sh

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Colours and output helpers
# ══════════════════════════════════════════════════════════════════════════════

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ICON_DONE="${GREEN}✓ DONE${NC}"
ICON_SKIP="${CYAN}↷ SKIP${NC}"
ICON_FAIL="${RED}✗ FAIL${NC}"
ICON_WARN="${YELLOW}⚠ WARN${NC}"

step()  { echo -e "\n${BOLD}${CYAN}[$(date +%H:%M:%S)]${NC} ${BOLD}$1${NC}"; }
info()  { echo -e "        ${DIM}$1${NC}"; }
done_() { echo -e "  ${ICON_DONE}  $1"; STEP_STATUS+=("✓ $1"); }
skip()  { echo -e "  ${ICON_SKIP}  $1"; STEP_STATUS+=("↷ $1 (skipped)"); }
warn()  { echo -e "  ${ICON_WARN}  $1"; }
fail()  { echo -e "  ${ICON_FAIL}  $1"; print_summary; exit 1; }

# Accumulate step results for the final summary
STEP_STATUS=()

# ══════════════════════════════════════════════════════════════════════════════
# Error trap — fires on any unhandled non-zero exit
# ══════════════════════════════════════════════════════════════════════════════

handle_error() {
    local exit_code=$?
    local line_no=$1
    local cmd=$2

    echo ""
    echo -e "${RED}════════════════════════════════════════════════${NC}"
    echo -e "${RED}  UNEXPECTED ERROR${NC}"
    echo -e "${RED}════════════════════════════════════════════════${NC}"
    echo -e "  Line    : ${BOLD}$line_no${NC}"
    echo -e "  Command : ${DIM}$cmd${NC}"
    echo -e "  Exit    : $exit_code"
    echo ""
    echo -e "  ${YELLOW}Diagnostics to run:${NC}"
    echo "    docker compose logs --tail 30"
    echo "    sudo journalctl -u docker --since '5 minutes ago'"
    echo "    sudo systemctl status docker"
    echo ""
    echo -e "  ${YELLOW}Reference docs:${NC}"
    echo "    cat references/ubuntu.md"
    echo ""
    print_summary
    exit $exit_code
}

trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# ══════════════════════════════════════════════════════════════════════════════
# Utility functions
# ══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_DIR="$SKILL_DIR/docker"

require_non_root() {
    if [[ $EUID -eq 0 ]]; then
        echo -e "${RED}Do not run this script as root.${NC}"
        echo "Run as a normal user with sudo access."
        exit 1
    fi
}

require_ubuntu() {
    if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
        warn "This script targets Ubuntu. Detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
        warn "Proceeding — some steps may need manual adjustment."
    else
        local ver
        ver=$(lsb_release -rs 2>/dev/null || echo "unknown")
        local major
        major=$(echo "$ver" | cut -d. -f1)
        if [[ "$major" -lt 20 ]]; then
            fail "Ubuntu $ver is not supported. Need 20.04 or newer."
        fi
    fi
}

port_available() {
    # Returns 0 if port is free, 1 if in use
    ! ss -tlnp 2>/dev/null | grep -q ":$1 " && \
    ! ss -tlnp 2>/dev/null | grep -q ":$1$"
}

port_used_by_our_stack() {
    local port=$1
    local service=$2
    docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --format json 2>/dev/null | \
        python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if '$service' in d.get('Name','') and d.get('State') == 'running':
            sys.exit(0)
    except: pass
sys.exit(1)
" 2>/dev/null
}

check_port() {
    local port=$1
    local service_name=$2
    local env_var=$3

    if ! port_available "$port"; then
        if port_used_by_our_stack "$port" "$service_name" 2>/dev/null; then
            skip "Port $port in use by our $service_name container — OK"
        else
            echo -e "  ${ICON_FAIL}  Port $port is already in use by another process."
            echo ""
            echo "  Who is using it:"
            ss -tlnp | grep ":$port " || true
            echo ""
            echo "  Fix: change $env_var in $DOCKER_DIR/.env then re-run."
            exit 1
        fi
    fi
}

wait_for_url() {
    local url=$1
    local label=$2
    local max_attempts=${3:-24}
    local interval=${4:-5}

    info "Waiting for $label to be ready..."
    local attempt=0
    until curl -sf "$url" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            echo ""
            fail "$label did not become ready after $((max_attempts * interval))s. Check: docker compose logs --tail 30"
        fi
        echo -ne "        Attempt $attempt/$max_attempts...\r"
        sleep "$interval"
    done
    echo ""
}

print_summary() {
    if [[ ${#STEP_STATUS[@]} -eq 0 ]]; then return; fi
    echo ""
    echo -e "${BOLD}════════════ Run Summary ════════════${NC}"
    for s in "${STEP_STATUS[@]}"; do
        echo "  $s"
    done
    echo -e "${BOLD}════════════════════════════════════${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

require_non_root
require_ubuntu

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Hermes + Paperclip — Stack Setup (Ubuntu)  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo -e "  Script: $0"
echo -e "  Docker dir: $DOCKER_DIR"
echo -e "  User: $USER"
echo ""

# ── Step 1: Ubuntu version ────────────────────────────────────────────────────
step "Checking Ubuntu version"
require_ubuntu
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
done_ "Ubuntu $UBUNTU_VER"

# ── Step 2: System dependencies ──────────────────────────────────────────────
step "Checking system dependencies"
MISSING_PKGS=()
for pkg in curl git ca-certificates gnupg lsb-release; do
    dpkg -l "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "Installing: ${MISSING_PKGS[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${MISSING_PKGS[@]}"
    done_ "Installed: ${MISSING_PKGS[*]}"
else
    skip "All system dependencies already installed"
fi

# ── Step 3: Docker Engine ─────────────────────────────────────────────────────
step "Checking Docker Engine"
if command -v docker &>/dev/null && docker --version &>/dev/null; then
    DOCKER_VER=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    skip "Docker Engine already installed (v$DOCKER_VER)"
else
    info "Installing Docker Engine via official apt repository..."

    # Remove any conflicting old packages silently
    for old in docker docker-engine docker.io containerd runc; do
        sudo apt-get remove -y "$old" &>/dev/null || true
    done

    # Add Docker GPG key (idempotent — overwrites if exists)
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add apt repository (idempotent — tee overwrites)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    docker --version &>/dev/null || fail "Docker installed but 'docker --version' failed. Try: sudo systemctl start docker"
    done_ "Docker Engine installed ($(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1))"
fi

# ── Step 4: Docker Compose plugin ────────────────────────────────────────────
step "Checking Docker Compose"
if docker compose version &>/dev/null; then
    skip "Docker Compose already available ($(docker compose version --short 2>/dev/null || echo 'ok'))"
else
    info "Installing docker-compose-plugin..."
    sudo apt-get install -y -qq docker-compose-plugin
    docker compose version &>/dev/null || fail "docker-compose-plugin installed but 'docker compose version' still fails."
    done_ "Docker Compose installed"
fi

# ── Step 5: Docker group membership ──────────────────────────────────────────
step "Checking docker group membership for user '$USER'"
if groups "$USER" | grep -q '\bdocker\b'; then
    skip "User $USER already in docker group"
else
    warn "Adding $USER to the docker group..."
    sudo usermod -aG docker "$USER"
    echo ""
    echo -e "  ${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}║  ACTION REQUIRED: Group change needs a new session.  ║${NC}"
    echo -e "  ${YELLOW}║                                                      ║${NC}"
    echo -e "  ${YELLOW}║  Option A: Log out and back in, then re-run.         ║${NC}"
    echo -e "  ${YELLOW}║  Option B: Run:  newgrp docker  (this terminal only) ║${NC}"
    echo -e "  ${YELLOW}║            then re-run this script in that shell.    ║${NC}"
    echo -e "  ${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_summary
    exit 0
fi

# Verify we can actually use Docker without sudo
if ! docker info &>/dev/null; then
    fail "User is in docker group but cannot connect to daemon. Try: newgrp docker"
fi

# ── Step 6: Docker daemon running ─────────────────────────────────────────────
step "Checking Docker daemon"
if systemctl is-active --quiet docker; then
    skip "Docker daemon already running"
else
    info "Starting Docker daemon..."
    sudo systemctl start docker
    sudo systemctl enable docker
    # Wait up to 15s for daemon to be responsive
    local_attempts=0
    until docker info &>/dev/null; do
        local_attempts=$((local_attempts + 1))
        [[ $local_attempts -ge 6 ]] && fail "Docker daemon started but is not responsive after 15s. Check: sudo journalctl -u docker -n 30"
        sleep 3
    done
    done_ "Docker daemon started and enabled on boot"
fi

# ── Step 7: Git ───────────────────────────────────────────────────────────────
step "Checking Git"
if command -v git &>/dev/null; then
    skip "Git already installed ($(git --version))"
else
    sudo apt-get install -y -qq git
    done_ "Git installed ($(git --version))"
fi

# ── Step 8: Firewall ──────────────────────────────────────────────────────────
step "Checking firewall (ufw)"
PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
MCP_PORT="${MCP_SERVER_PORT:-8765}"

if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    ADDED_RULES=()
    for port_label in "$PAPERCLIP_PORT:Paperclip-UI" "$MCP_PORT:Hermes-MCP"; do
        port="${port_label%%:*}"; label="${port_label##*:}"
        if sudo ufw status | grep -q "^$port/tcp"; then
            skip "ufw rule for port $port ($label) already exists"
        else
            sudo ufw allow "$port/tcp" comment "$label" > /dev/null
            ADDED_RULES+=("$port ($label)")
        fi
    done
    [[ ${#ADDED_RULES[@]} -gt 0 ]] && done_ "Added ufw rules: ${ADDED_RULES[*]}" || true
else
    skip "ufw not active — no firewall changes needed"
fi

# ── Step 9: Environment file ──────────────────────────────────────────────────
step "Checking environment file"
ENV_FILE="$DOCKER_DIR/.env"
ENV_EXAMPLE="$DOCKER_DIR/.env.example"

if [[ ! -f "$ENV_EXAMPLE" ]]; then
    fail ".env.example not found at $ENV_EXAMPLE. Are you running from the skill directory?"
fi

if [[ -f "$ENV_FILE" ]]; then
    skip ".env already exists — not overwriting"
else
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Created $ENV_FILE from example."
    echo ""
    echo -e "  ${YELLOW}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}║  ACTION REQUIRED: Edit .env before continuing.  ║${NC}"
    echo -e "  ${YELLOW}║                                                 ║${NC}"
    echo -e "  ${YELLOW}║  At minimum, add one of:                        ║${NC}"
    echo -e "  ${YELLOW}║    OPENROUTER_API_KEY=sk-or-...                 ║${NC}"
    echo -e "  ${YELLOW}║    ANTHROPIC_API_KEY=sk-ant-...                 ║${NC}"
    echo -e "  ${YELLOW}║    OPENAI_API_KEY=sk-...                        ║${NC}"
    echo -e "  ${YELLOW}║                                                 ║${NC}"
    echo -e "  ${YELLOW}║  nano '$ENV_FILE'                               ║${NC}"
    echo -e "  ${YELLOW}╚═════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Press Enter after saving .env to continue..."
fi

# ── Step 10: Validate .env ────────────────────────────────────────────────────
step "Validating .env"
MISSING_KEYS=()
KEY_FOUND=false
for key in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY; do
    val=$(grep -E "^${key}=.+" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "$val" && "$val" != "sk-or-" && "$val" != "sk-ant-" && "$val" != "sk-" ]]; then
        KEY_FOUND=true
        done_ "$key is set"
    fi
done

if [[ "$KEY_FOUND" != "true" ]]; then
    warn "No model API key found in .env."
    warn "Agents will fail to run tasks without one. Add OPENROUTER_API_KEY (recommended) to $ENV_FILE."
    STEP_STATUS+=("⚠ No model API key — agents won't work until you add one")
fi

# Load .env values for port checks
set -a; source "$ENV_FILE"; set +a

# ── Step 11: Port availability ────────────────────────────────────────────────
step "Checking port availability"
check_port "${PAPERCLIP_PORT:-3100}" "paperclip" "PAPERCLIP_PORT"
check_port "${MCP_SERVER_PORT:-8765}" "mcp-server" "MCP_SERVER_PORT"
skip "Ports ${PAPERCLIP_PORT:-3100} and ${MCP_SERVER_PORT:-8765} are available"

# ── Step 12: Docker images ────────────────────────────────────────────────────
step "Checking Docker images"
cd "$DOCKER_DIR"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

NEEDS_BUILD=false
for svc in hermes-worker mcp-server; do
    # Check if an image for this service already exists
    img=$(docker compose -f "$COMPOSE_FILE" images -q "$svc" 2>/dev/null || true)
    if [[ -z "$img" ]]; then
        info "Image for '$svc' not found — will build"
        NEEDS_BUILD=true
    else
        skip "Image for '$svc' already built"
    fi
done

# Paperclip always checks for updates since it builds from GitHub
info "Checking Paperclip image..."
if docker image inspect paperclip-local &>/dev/null 2>&1 || \
   docker compose -f "$COMPOSE_FILE" images -q paperclip 2>/dev/null | grep -q .; then
    skip "Paperclip image present"
else
    NEEDS_BUILD=true
fi

if [[ "$NEEDS_BUILD" == "true" ]]; then
    info "Building missing images (this may take 5-10 minutes on first run)..."
    docker compose -f "$COMPOSE_FILE" build --progress=plain 2>&1 | \
        grep -E "(Step|Successfully|ERROR|error)" | sed 's/^/        /' || \
        fail "docker compose build failed. Re-run with: docker compose build --no-cache"
    done_ "Images built"
else
    skip "All images already built — use 'docker compose build' to force a rebuild"
fi

# ── Step 13: Start the stack ──────────────────────────────────────────────────
step "Starting the stack"
RUNNING=$(docker compose -f "$COMPOSE_FILE" ps --status running --format json 2>/dev/null | \
    python3 -c "import sys,json; lines=[l for l in sys.stdin if l.strip()]; print(len(lines))" 2>/dev/null || echo "0")

if [[ "$RUNNING" -ge 3 ]]; then
    skip "All 3 services already running"
else
    info "Starting containers..."
    docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
    done_ "Stack started"
fi

# ── Step 14: Wait for health ──────────────────────────────────────────────────
step "Waiting for services to be healthy"
wait_for_url "http://localhost:${PAPERCLIP_PORT:-3100}/api/health" "Paperclip" 24 5
wait_for_url "http://localhost:${MCP_SERVER_PORT:-8765}/health" "MCP server" 12 5
done_ "All services healthy"

# ── Step 15: Final verification ───────────────────────────────────────────────
step "Running verification"
if bash "$SCRIPT_DIR/verify.sh" 2>&1 | tee /tmp/hp-verify.log | grep -q "All checks passed"; then
    done_ "All verification checks passed"
else
    warn "Some verification checks failed. See /tmp/hp-verify.log"
    STEP_STATUS+=("⚠ Verification had failures — check /tmp/hp-verify.log")
fi

# ── Step 16: Optional systemd service ────────────────────────────────────────
step "Auto-start on boot (systemd)"
SERVICE_FILE="/etc/systemd/system/ai-workforce.service"

if [[ -f "$SERVICE_FILE" ]] && sudo systemctl is-enabled ai-workforce &>/dev/null; then
    skip "systemd service already installed and enabled"
else
    echo ""
    read -rp "  Install systemd service so the stack starts automatically on boot? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Hermes + Paperclip AI Workforce
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DOCKER_DIR
ExecStartPre=/usr/bin/docker compose -f $COMPOSE_FILE pull --quiet || true
ExecStart=/usr/bin/docker compose -f $COMPOSE_FILE up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f $COMPOSE_FILE down
ExecReload=/usr/bin/docker compose -f $COMPOSE_FILE restart
TimeoutStartSec=180
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable ai-workforce.service
        done_ "systemd service installed — stack auto-starts on boot"
        info "Manage with: sudo systemctl start|stop|status|restart ai-workforce"
    else
        skip "Skipped systemd install — stack will not auto-start on reboot"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Final summary
# ══════════════════════════════════════════════════════════════════════════════

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        Setup complete — stack is running          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Paperclip UI${NC}   http://${HOST_IP}:${PAPERCLIP_PORT:-3100}"
echo -e "  ${BOLD}MCP server${NC}     http://${HOST_IP}:${MCP_SERVER_PORT:-8765}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    docker compose logs -f               # live logs"
echo "    docker compose logs hermes-worker -f # agent activity"
echo "    docker compose restart hermes-worker # restart workers"
echo "    docker compose down                  # stop stack"
echo "    docker compose down -v               # stop + wipe data"
echo ""
print_summary

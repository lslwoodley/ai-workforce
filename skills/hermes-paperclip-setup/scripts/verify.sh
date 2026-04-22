#!/usr/bin/env bash
# verify.sh — Cross-platform stack health check with per-failure fix instructions
#
# Can be run:
#   On the host:  cd docker && bash ../scripts/verify.sh
#   In container: docker compose exec mcp-server bash /app/scripts/verify.sh
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed (details printed inline)

set -uo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Colour helpers
# ══════════════════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

PASS="${GREEN}✓${NC}"; FAIL="${RED}✗${NC}"; WARN="${YELLOW}⚠${NC}"

# ══════════════════════════════════════════════════════════════════════════════
# State
# ══════════════════════════════════════════════════════════════════════════════

FAILURES=0
WARNINGS=0
FAILURE_DETAIL=()

# ══════════════════════════════════════════════════════════════════════════════
# Check helpers
# ══════════════════════════════════════════════════════════════════════════════

# check <label> <test_command> <fix_message>
check() {
    local label="$1"
    local cmd="$2"
    local fix="${3:-}"

    if eval "$cmd" > /dev/null 2>&1; then
        printf "  ${PASS}  %-52s\n" "$label"
    else
        printf "  ${FAIL}  %-52s\n" "$label"
        FAILURES=$((FAILURES + 1))
        if [[ -n "$fix" ]]; then
            FAILURE_DETAIL+=("${RED}✗${NC} $label")
            FAILURE_DETAIL+=("  ${YELLOW}Fix:${NC} $fix")
            FAILURE_DETAIL+=("")
        fi
    fi
}

# check_url <label> <url> <fix>
check_url() {
    local label="$1"; local url="$2"; local fix="${3:-}"
    check "$label" "curl -sf --max-time 5 '$url'" "$fix"
}

# check_warn <label> <test_command> <message>
check_warn() {
    local label="$1"; local cmd="$2"; local msg="${3:-}"
    if eval "$cmd" > /dev/null 2>&1; then
        printf "  ${PASS}  %-52s\n" "$label"
    else
        printf "  ${WARN}  %-52s\n" "$label"
        WARNINGS=$((WARNINGS + 1))
        [[ -n "$msg" ]] && echo -e "        ${DIM}$msg${NC}"
    fi
}

section() { echo -e "\n${BOLD}${CYAN}── $1 ──────────────────────────────────${NC}"; }

# ══════════════════════════════════════════════════════════════════════════════
# Config
# ══════════════════════════════════════════════════════════════════════════════

PAPERCLIP_URL="${PAPERCLIP_API_URL:-http://localhost:3100}"
MCP_URL="http://localhost:${MCP_SERVER_PORT:-8765}"

# Detect if we're running inside a container (no docker CLI) or on the host
IN_CONTAINER=false
[[ ! -S /var/run/docker.sock && ! -f /usr/bin/docker ]] && IN_CONTAINER=true

# ══════════════════════════════════════════════════════════════════════════════
# Header
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Hermes + Paperclip — Stack Verification         ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo -e "  Paperclip : $PAPERCLIP_URL"
echo -e "  MCP server: $MCP_URL"
echo -e "  Mode      : $([ "$IN_CONTAINER" = "true" ] && echo "inside container" || echo "host")"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Checks: Docker containers (host only)
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$IN_CONTAINER" == "false" ]]; then
    section "Docker Containers"

    check "Docker daemon accessible" \
        "docker info" \
        "Start Docker Desktop (Windows) or: sudo systemctl start docker (Ubuntu)"

    check "paperclip container running" \
        "docker compose ps paperclip 2>/dev/null | grep -q 'running\|Up'" \
        "docker compose up -d paperclip"

    check "hermes-worker container running" \
        "docker compose ps hermes-worker 2>/dev/null | grep -q 'running\|Up'" \
        "docker compose up -d hermes-worker  |  then: docker compose logs hermes-worker --tail 30"

    check "mcp-server container running" \
        "docker compose ps mcp-server 2>/dev/null | grep -q 'running\|Up'" \
        "docker compose up -d mcp-server"

    check "paperclip container healthy" \
        "docker compose ps paperclip 2>/dev/null | grep -qi 'healthy'" \
        "docker compose logs paperclip --tail 30  (look for startup errors)"

    check "hermes-worker container healthy or running" \
        "docker compose ps hermes-worker 2>/dev/null | grep -qiE 'healthy|running|Up'" \
        "docker compose logs hermes-worker --tail 30  (check for missing API key)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Checks: Paperclip API
# ══════════════════════════════════════════════════════════════════════════════

section "Paperclip API"

check_url "Health endpoint responds" \
    "${PAPERCLIP_URL}/api/health" \
    "Paperclip may still be starting. Wait 30s then re-run. Or: docker compose logs paperclip --tail 30"

check_url "Agents API reachable" \
    "${PAPERCLIP_URL}/api/agents" \
    "Paperclip is up but API is returning errors. Check: docker compose logs paperclip --tail 30"

check_url "Goals API reachable" \
    "${PAPERCLIP_URL}/api/goals" \
    "API routing issue. Check Paperclip container logs."

check_url "Skills API reachable" \
    "${PAPERCLIP_URL}/api/skills" \
    "API routing issue. Check Paperclip container logs."

# ══════════════════════════════════════════════════════════════════════════════
# Checks: MCP server
# ══════════════════════════════════════════════════════════════════════════════

section "MCP Server (Agent-to-Agent API)"

check_url "MCP server health" \
    "${MCP_URL}/health" \
    "MCP server may not be running. On host: docker compose up -d mcp-server  |  In container: python /app/scripts/mcp_server.py"

check_url "MCP tools list" \
    "${MCP_URL}/tools" \
    "MCP server is up but /tools endpoint failed. Check: docker compose logs mcp-server --tail 20"

# Check tool count
if curl -sf --max-time 5 "${MCP_URL}/tools" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
tools = data.get('tools', [])
expected = {'list_agents','assign_task','query_agent','get_agent_memory','spawn_agent','escalate_to_human','get_company_goals'}
missing = expected - {t['name'] for t in tools}
if missing:
    print(f'Missing tools: {missing}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
    printf "  ${PASS}  %-52s\n" "All 7 expected MCP tools registered"
else
    printf "  ${WARN}  %-52s\n" "Tool count mismatch — some tools may be missing"
    WARNINGS=$((WARNINGS + 1))
fi

# ══════════════════════════════════════════════════════════════════════════════
# Checks: Hermes inside container (host only)
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$IN_CONTAINER" == "false" ]]; then
    section "Hermes Agent (inside container)"

    check "hermes CLI available" \
        "docker compose exec -T hermes-worker hermes --version" \
        "Image may not have built correctly. Rebuild: docker compose build --no-cache hermes-worker"

    check "hermes config readable" \
        "docker compose exec -T hermes-worker hermes config list" \
        "Hermes config may be corrupted. Try: docker compose exec hermes-worker rm ~/.hermes/config.json && docker compose restart hermes-worker"

    check "adapter installed" \
        "docker compose exec -T hermes-worker hermes-paperclip --version" \
        "Adapter missing from image. Rebuild: docker compose build --no-cache hermes-worker"

    check_warn "Hermes model configured" \
        "docker compose exec -T hermes-worker hermes config get model 2>/dev/null | grep -q '/'" \
        "Model not set — check HERMES_MODEL and API key in .env"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Checks: Volumes
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$IN_CONTAINER" == "false" ]]; then
    section "Data Volumes"

    for vol in paperclip-data hermes-sessions hermes-skills; do
        check "Volume '$vol' exists" \
            "docker volume inspect $vol" \
            "docker compose up -d  (volumes are created automatically on first start)"
    done

    # Check sessions volume has data (not strictly required but good signal)
    check_warn "hermes-sessions has session data" \
        "docker run --rm -v hermes-sessions:/data alpine ls /data 2>/dev/null | grep -q ." \
        "No sessions yet — normal on first run, will populate after first task"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Checks: Network connectivity between containers
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$IN_CONTAINER" == "false" ]]; then
    section "Inter-Container Networking"

    check "hermes-worker can reach Paperclip internally" \
        "docker compose exec -T hermes-worker curl -sf --max-time 5 http://paperclip:3100/api/health" \
        "Network issue between containers. Check: docker network ls | grep ai-workforce"

    check "mcp-server can reach Paperclip internally" \
        "docker compose exec -T mcp-server curl -sf --max-time 5 http://paperclip:3100/api/health" \
        "Network issue. Recreate the network: docker compose down && docker compose up -d"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}═══════════════ Results ═════════════════${NC}"

if [[ $FAILURES -eq 0 && $WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}  All checks passed. Stack is healthy.${NC}"
elif [[ $FAILURES -eq 0 ]]; then
    echo -e "${YELLOW}  All checks passed with $WARNINGS warning(s).${NC}"
else
    echo -e "${RED}  $FAILURES check(s) failed, $WARNINGS warning(s).${NC}"
fi

if [[ ${#FAILURE_DETAIL[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}  Failed checks and fixes:${NC}"
    for line in "${FAILURE_DETAIL[@]}"; do
        echo -e "    $line"
    done
fi

echo ""

[[ $FAILURES -gt 0 ]] && exit 1 || exit 0

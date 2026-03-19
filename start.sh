#!/bin/bash
#
# Starts Wanaku with Keycloak + Router + Camel Integration Capability.
#
# Usage:
#   ./start.sh                              # starts with hello-tool
#   ./start.sh hello-tool                   # same
#   ./start.sh postgres-tool                # PostgreSQL example
#   ./start.sh hello-tool postgres-tool     # both at once
#   ./start.sh hello-tool postgres-tool file-resource  # all three
#

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS="${DIR}/artifacts"
LOGS="${DIR}/logs"
PIDS="${DIR}/.pids"
KEYCLOAK_IMAGE="quay.io/keycloak/keycloak:26.3.5"
POSTGRES_IMAGE="docker.io/library/postgres:16"
CIC_BASE_PORT=9191

# Auto-detect container runtime (podman or docker)
if command -v podman &> /dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
  CONTAINER_CMD="docker"
else
  echo "Neither podman nor docker found. Install one and try again."
  exit 1
fi

# Default to hello-tool if no args
if [ $# -eq 0 ]; then
  EXAMPLES=("hello-tool")
else
  EXAMPLES=("$@")
fi

# ── Preflight checks ─────────────────────────────────────────────────

if [ ! -d "${ARTIFACTS}/wanaku-router-backend-0.1.0-SNAPSHOT" ]; then
  echo "Artifacts not found. Run ./download.sh first."
  exit 1
fi

if ! ${CONTAINER_CMD} info > /dev/null 2>&1; then
  echo "${CONTAINER_CMD} is not running. Start it and try again."
  exit 1
fi

for example in "${EXAMPLES[@]}"; do
  if [ ! -d "${DIR}/camel-integration-capabilities/${example}" ]; then
    echo "Example '${example}' not found. Available:"
    ls "${DIR}/camel-integration-capabilities/"
    exit 1
  fi
done

# ── Cleanup from previous run ────────────────────────────────────────

"${DIR}/stop.sh" 2>/dev/null || true

mkdir -p "${LOGS}" "${PIDS}"
rm -f "${LOGS}"/*.log

# ── 1. Keycloak ──────────────────────────────────────────────────────

echo "Starting Keycloak..."
${CONTAINER_CMD} run -d --name wanaku-keycloak \
  -p 8543:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  "${KEYCLOAK_IMAGE}" start-dev \
  > /dev/null

echo "  Waiting for Keycloak..."
for i in $(seq 1 60); do
  curl -sf http://localhost:8543/realms/master > /dev/null 2>&1 && break
  sleep 2
done

if ! curl -sf http://localhost:8543/realms/master > /dev/null 2>&1; then
  echo "  Keycloak failed to start. Check: docker logs wanaku-keycloak"
  exit 1
fi

# Get admin token
ADMIN_TOKEN=$(curl -s -d 'client_id=admin-cli' -d 'username=admin' -d 'password=admin' -d 'grant_type=password' \
  http://localhost:8543/realms/master/protocol/openid-connect/token | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# Import realm
curl -s -X POST http://localhost:8543/admin/realms \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"${DIR}/config/wanaku-config.json" > /dev/null

# Create test user
curl -s -X POST http://localhost:8543/admin/realms/wanaku/users \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"test-user","enabled":true,"emailVerified":true,"firstName":"Test","lastName":"User","email":"test-user@wanaku.local","credentials":[{"type":"password","value":"test-password","temporary":false}]}' > /dev/null

echo "  Keycloak ready (port 8543)"

# ── 2. Router ────────────────────────────────────────────────────────

ROUTER_DIR="${ARTIFACTS}/wanaku-router-backend-0.1.0-SNAPSHOT"

echo "Starting Router..."
(cd "${ROUTER_DIR}" && java \
  -Dquarkus.http.port=8080 \
  -Dquarkus.grpc.server.port=9090 \
  -jar quarkus-run.jar \
  > "${LOGS}/router.log" 2>&1) &

echo $! > "${PIDS}/router.pid"

echo "  Waiting for Router..."
for i in $(seq 1 30); do
  curl -sf http://localhost:8080/q/health/ready > /dev/null 2>&1 && break
  sleep 2
done

if ! curl -sf http://localhost:8080/q/health/ready > /dev/null 2>&1; then
  echo "  Router failed to start. Check: tail logs/router.log"
  exit 1
fi

echo "  Router ready (port 8080)"

# ── 3. PostgreSQL (if any example needs it) ──────────────────────────

NEEDS_POSTGRES=false
for example in "${EXAMPLES[@]}"; do
  if [ -f "${DIR}/camel-integration-capabilities/${example}/seed.sql" ]; then
    NEEDS_POSTGRES=true
    break
  fi
done

if [ "${NEEDS_POSTGRES}" = true ]; then
  echo "Starting PostgreSQL..."
  ${CONTAINER_CMD} run -d --name wanaku-postgres \
    -p 5432:5432 \
    -e POSTGRES_DB=wanaku \
    -e POSTGRES_USER=wanaku \
    -e POSTGRES_PASSWORD=wanaku \
    "${POSTGRES_IMAGE}" \
    > /dev/null

  echo "  Waiting for PostgreSQL..."
  for i in $(seq 1 30); do
    ${CONTAINER_CMD} exec wanaku-postgres pg_isready -U wanaku > /dev/null 2>&1 && break
    sleep 1
  done

  # Seed from all examples that have seed.sql
  for example in "${EXAMPLES[@]}"; do
    if [ -f "${DIR}/camel-integration-capabilities/${example}/seed.sql" ]; then
      echo "  Seeding database (${example})..."
      ${CONTAINER_CMD} exec -i wanaku-postgres psql -U wanaku -d wanaku < "${DIR}/camel-integration-capabilities/${example}/seed.sql" > /dev/null 2>&1
    fi
  done

  echo "  PostgreSQL ready (port 5432)"
fi

# ── 4. Camel Integration Capability ───────────────────────────────────

GRPC_PORT=${CIC_BASE_PORT}
LOADED_EXAMPLES=""

for example in "${EXAMPLES[@]}"; do
  EXAMPLE_DIR="${DIR}/camel-integration-capabilities/${example}"

  CIC_EXTRA_ARGS=""
  if [ -f "${EXAMPLE_DIR}/dependencies.txt" ]; then
    CIC_EXTRA_ARGS="--dependencies file://${EXAMPLE_DIR}/dependencies.txt"
  fi

  CIC_DATA_DIR="${DIR}/.data/${example}"
  mkdir -p "${CIC_DATA_DIR}"

  echo "Starting Camel Integration Capability: ${example} (gRPC port ${GRPC_PORT})..."
  java -jar "${ARTIFACTS}/cic/cic.jar" \
    --name "${example}" \
    --grpc-port "${GRPC_PORT}" \
    --data-dir "${CIC_DATA_DIR}" \
    --routes-ref "file://${EXAMPLE_DIR}/routes.camel.yaml" \
    --rules-ref "file://${EXAMPLE_DIR}/rules.yaml" \
    ${CIC_EXTRA_ARGS} \
    --registration-url http://localhost:8080 \
    --registration-announce-address localhost \
    --token-endpoint "http://localhost:8543/realms/wanaku" \
    --client-id wanaku-service \
    --client-secret mypasswd \
    > "${LOGS}/cic-${example}.log" 2>&1 &

  echo $! > "${PIDS}/cic-${example}.pid"
  LOADED_EXAMPLES="${LOADED_EXAMPLES}  - ${example} (gRPC :${GRPC_PORT}, log: logs/cic-${example}.log)\n"
  GRPC_PORT=$((GRPC_PORT + 1))
done

# Wait for at least one tool to register
echo "  Waiting for Camel Integration Capability to register..."
for i in $(seq 1 30); do
  curl -sf http://localhost:8080/api/v1/tools/list 2>/dev/null | grep -q '"data":\[{' && break
  sleep 20
done

echo "  Camel Integration Capability ready"

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "  Wanaku is running!"
echo "========================================="
echo ""
echo "  MCP:        http://localhost:8080/mcp/sse"
echo "  Web UI:     http://localhost:8080"
echo "  Keycloak:   http://localhost:8543"
echo ""
echo "  Login:      test-user / test-password"
echo "  Admin:      admin / admin"
echo ""
echo "  Examples loaded:"
echo -e "${LOADED_EXAMPLES}"
echo "  Logs:"
echo "    check in the /logs/ folder manually  or"
echo "    tail -f logs/router.log"
for example in "${EXAMPLES[@]}"; do
  echo "    tail -f logs/cic-${example}.log"
done
echo ""
echo "  Run MCP Inspector:  npx @modelcontextprotocol/inspector"
echo ""
echo "  Go to MCP Inspector UI: http://localhost:6274"
echo ""
echo "    Transport Type:  SSE"
echo "    Endpoint URL:    http://localhost:8080/mcp/sse"
echo "    Authentication:  Direct (OAuth)"
echo "    Client ID:       mcp-client"
echo "    Client Secret:   (leave empty)"
echo "    Redirect URI:    http://localhost:6274/oauth/callback"
echo "    Scope:           openid wanaku-mcp-client"
echo ""
echo "  If you get an OAuth error in MCP Inspector:"
echo "    Open Auth Settings -> Clear OAuth State -> Connect again"
echo ""
echo "  Check the status:  ./status.sh"
echo "  Stop:  ./stop.sh"
echo "========================================="

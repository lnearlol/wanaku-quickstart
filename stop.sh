#!/bin/bash
#
# Stops all Wanaku processes.
#

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS="${DIR}/.pids"

# Stop Java processes
if [ -d "${PIDS}" ]; then
  for pidfile in "${PIDS}"/*.pid; do
    [ -f "${pidfile}" ] || continue
    pid=$(cat "${pidfile}")
    name=$(basename "${pidfile}" .pid)
    if kill -0 "${pid}" 2>/dev/null; then
      echo "Stopping ${name} (PID ${pid})..."
      kill "${pid}" 2>/dev/null
      sleep 2
      kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${pidfile}"
  done
fi

# Auto-detect container runtime
if command -v podman &> /dev/null; then
  CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
  CONTAINER_CMD="docker"
else
  CONTAINER_CMD=""
fi

# Stop containers
if [ -n "${CONTAINER_CMD}" ]; then
  for container in wanaku-keycloak wanaku-postgres; do
    if ${CONTAINER_CMD} ps -q --filter "name=${container}" 2>/dev/null | grep -q .; then
      echo "Stopping ${container}..."
      ${CONTAINER_CMD} rm -f "${container}" > /dev/null 2>&1
    fi
  done
fi

# Kill any orphan Java processes on our ports
for port in 8080 9090 9191; do
  pid=$(lsof -ti :${port} -sTCP:LISTEN 2>/dev/null)
  if [ -n "${pid}" ]; then
    echo "Killing orphan process on port ${port} (PID ${pid})..."
    kill -9 "${pid}" 2>/dev/null || true
  fi
done

# Clean Infinispan locks to prevent startup failures
rm -rf ~/.wanaku/router/ ~/.wanaku/services/ 2>/dev/null

echo "All stopped."

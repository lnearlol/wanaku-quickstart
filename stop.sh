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

# Stop Docker containers
for container in wanaku-keycloak wanaku-postgres; do
  if docker ps -q --filter "name=${container}" | grep -q .; then
    echo "Stopping ${container}..."
    docker rm -f "${container}" > /dev/null 2>&1
  fi
done

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

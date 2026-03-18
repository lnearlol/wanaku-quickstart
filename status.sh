#!/bin/bash
#
# Shows status of Wanaku processes.
#

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS="${DIR}/.pids"

check() {
  local name="$1"
  local pidfile="${PIDS}/${name}.pid"
  if [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
    echo "  ${name}: running (PID $(cat "${pidfile}"))"
  else
    echo "  ${name}: stopped"
  fi
}

echo "Docker:"
for container in wanaku-keycloak wanaku-postgres; do
  if docker ps -q --filter "name=${container}" | grep -q .; then
    echo "  ${container}: running"
  else
    echo "  ${container}: stopped"
  fi
done

echo "Java:"
check router

if [ -d "${PIDS}" ]; then
  for pidfile in "${PIDS}"/cic-*.pid; do
    [ -f "${pidfile}" ] || continue
    name=$(basename "${pidfile}" .pid)
    check "${name}"
  done
fi

echo ""
echo "Tools registered:"
curl -s http://localhost:8080/api/v1/tools/list 2>/dev/null | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"/  -/' || echo "  (router not available)"
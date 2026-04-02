#!/bin/bash
#
# Downloads Wanaku artifacts from GitHub releases.
#

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS="${DIR}/artifacts"

mkdir -p "${ARTIFACTS}"

echo "Downloading Wanaku Router..."
curl -fSL -o "${ARTIFACTS}/router.zip" \
  "https://github.com/wanaku-ai/wanaku/releases/download/early-access/wanaku-router-backend-0.1.0-SNAPSHOT.zip"
unzip -o -d "${ARTIFACTS}" "${ARTIFACTS}/router.zip"
rm -f "${ARTIFACTS}/router.zip"

echo "Downloading Camel Integration Capability..."
mkdir -p "${ARTIFACTS}/cic"
curl -fSL -o "${ARTIFACTS}/cic/cic.jar" \
  "https://github.com/wanaku-ai/camel-integration-capability/releases/download/early-access/camel-integration-capability-main-0.1.0-SNAPSHOT-jar-with-dependencies.jar"

echo "Downloading Wanaku CLI..."
curl -fSL -o "${ARTIFACTS}/cli.zip" \
  "https://github.com/wanaku-ai/wanaku/releases/download/early-access/cli-0.1.0-SNAPSHOT.zip"
unzip -o -d "${ARTIFACTS}" "${ARTIFACTS}/cli.zip"
rm -f "${ARTIFACTS}/cli.zip"

echo ""
echo "Done! Artifacts in ${ARTIFACTS}/"

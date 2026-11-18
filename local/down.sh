#!/usr/bin/env bash
# Deletes the local cluster and the Service Bus emulator. Nothing is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
kind delete cluster --name shopflow
docker compose -f local/servicebus.compose.yaml down -v

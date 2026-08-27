#!/bin/sh
set -e

UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-ProxyService}"

echo "[$(date)] Generating Xray config..."
envsubst '${UUID} ${GRPC_SERVICE_NAME}' < /etc/xray/config.template.json > /etc/xray/config.json

echo "[$(date)] Starting Xray on port 8089 (VLESS+gRPC; plain transport, TLS terminated by FC gateway)"
exec /usr/local/bin/xray run -config /etc/xray/config.json

#!/bin/sh
set -e

# envsubst 只替换环境变量(非 shell 变量),故此处必须 export,否则未显式传入的
# 变量会被替换成空串(如 WS_PATH 未传时 path 会变成 "/" 而不是 "/ws")
export UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
export GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-ProxyService}"
export WS_PATH="${WS_PATH:-ws}"
TRANSPORT="${TRANSPORT:-ws}"   # ws(默认,生产) | grpc(保留回退)— 同一镜像两种传输,部署时用环境变量选择

if [ "$TRANSPORT" = "ws" ]; then
  TEMPLATE=/etc/xray/config.ws.template.json
  echo "[$(date)] Starting Xray on port 8089 (VLESS+WebSocket, path=/${WS_PATH}; plain transport, TLS terminated by FC gateway)"
else
  TEMPLATE=/etc/xray/config.template.json
  echo "[$(date)] Starting Xray on port 8089 (VLESS+gRPC; plain transport, TLS terminated by FC gateway)"
fi

echo "[$(date)] Generating Xray config..."
envsubst '${UUID} ${GRPC_SERVICE_NAME} ${WS_PATH}' < "$TEMPLATE" > /etc/xray/config.json

exec /usr/local/bin/xray run -config /etc/xray/config.json

#!/bin/sh
set -e

# envsubst 只替换环境变量(非 shell 变量),故此处必须 export,否则未显式传入的
# 变量会被替换成空串(如 WS_PATH 未传时 path 会变成 "/" 而不是 "/ws")
export UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
export WS_PATH="${WS_PATH:-ws}"

echo "[$(date)] Generating Xray config..."
envsubst '${UUID} ${WS_PATH}' < /etc/xray/config.template.json > /etc/xray/config.json

echo "[$(date)] Starting Xray on port 8089 (VLESS+WebSocket, path=/${WS_PATH}; plain transport, TLS terminated by FC gateway)"
exec /usr/local/bin/xray run -config /etc/xray/config.json

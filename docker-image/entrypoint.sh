#!/bin/sh
set -e

# envsubst 只替换环境变量(非 shell 变量),故此处必须 export,否则未显式传入的
# 变量会被替换成空串(如 WS_PATH 未传时 path 会变成 "/" 而不是 "/ws")
export UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
export WS_PATH="${WS_PATH:-ws}"
# tcpFastOpen: 生产 FC 默认开;本地 Docker 联调需 TFO=false(qemu 下会连接重置,见 docs/memory.md)
export TFO="${TFO:-true}"

# 中转模式:设置了 RELAY_EXIT_HOST 即作为入口节点,outbound 链到出口节点(如 shanghai→tokyo);
# 未设置则用直连模板(outbound=freedom,出口节点)
if [ -n "${RELAY_EXIT_HOST:-}" ]; then
  export RELAY_EXIT_HOST
  export RELAY_EXIT_PORT="${RELAY_EXIT_PORT:-443}"
  # RELAY_EXIT_TLS=true 走出口节点 FC 网关 WSS 443;本地容器联调 false 直连明文 WS
  if [ "${RELAY_EXIT_TLS:-true}" = "true" ]; then
    export RELAY_EXIT_SECURITY="tls"
  else
    export RELAY_EXIT_SECURITY="none"
  fi
  # FC 平台保留 FC_ 前缀环境变量名,s.yaml 注入时改名 RELAY_BEARER_TOKEN(本地两者皆可)
  export FC_BEARER_TOKEN="${RELAY_BEARER_TOKEN:-${FC_BEARER_TOKEN:-}}"
  TEMPLATE=/etc/xray/config.relay.template.json
  MODE_DESC="relay mode, outbound → ${RELAY_EXIT_SECURITY}://${RELAY_EXIT_HOST}:${RELAY_EXIT_PORT}/ws"
else
  TEMPLATE=/etc/xray/config.template.json
  MODE_DESC="direct mode (freedom outbound)"
fi

echo "[$(date)] Generating Xray config..."
envsubst '${UUID} ${WS_PATH} ${TFO} ${RELAY_EXIT_HOST} ${RELAY_EXIT_PORT} ${RELAY_EXIT_SECURITY} ${FC_BEARER_TOKEN}' \
  < "$TEMPLATE" > /etc/xray/config.json

echo "[$(date)] Starting Xray on port 8089 (VLESS+WebSocket, path=/${WS_PATH}; ${MODE_DESC})"
exec /usr/local/bin/xray run -config /etc/xray/config.json

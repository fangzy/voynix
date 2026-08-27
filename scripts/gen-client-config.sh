#!/bin/sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO_DIR}/docker-image/.env"
TEMPLATE="${REPO_DIR}/client-config/clash-verge.yaml.template"
OUTPUT="${REPO_DIR}/client-config/clash-verge.yaml"

usage() {
  echo "Usage: $0 <hk_host> <sg_host> [hk_port] [sg_port]"
  echo ""
  echo "  hk_host  香港 FC 节点域名(必填)"
  echo "  sg_host  新加坡 FC 节点域名(必填)"
  echo "  hk_port  香港端口(默认 8089,FC gRPC 入口端口)"
  echo "  sg_port  新加坡端口(默认 8089)"
  echo ""
  echo "Reads UUID and GRPC_SERVICE_NAME from docker-image/.env"
  echo "Outputs to client-config/clash-verge.yaml"
  echo ""
  echo "示例:"
  echo "  $0 voynix-xray-hk-xxx.cn-hongkong.fcapp.run xray-exit-proxy-service-xxx.ap-southeast-1.fcapp.run"
  exit 1
}

[ $# -lt 2 ] && usage

HK_HOST="$1"
SG_HOST="$2"
HK_PORT="${3:-8089}"
SG_PORT="${4:-8089}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found"
  echo "Run: cp docker-image/.env.example docker-image/.env && edit it"
  exit 1
fi

# Source server .env
. "$ENV_FILE"

if [ -z "$UUID" ] || [ "$UUID" = "your-uuid-here" ]; then
  echo "Error: UUID not set in $ENV_FILE"
  exit 1
fi

GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-ProxyService}"

export UUID GRPC_SERVICE_NAME HK_HOST HK_PORT SG_HOST SG_PORT

envsubst '${UUID} ${GRPC_SERVICE_NAME} ${HK_HOST} ${HK_PORT} ${SG_HOST} ${SG_PORT}' \
  < "$TEMPLATE" > "$OUTPUT"

echo "Generated: $OUTPUT"
echo "  香港 (Voynix-HK):    $HK_HOST:$HK_PORT"
echo "  新加坡 (Voynix-SG):  $SG_HOST:$SG_PORT"
echo "  UUID:               $UUID"
echo "  GRPC_SERVICE_NAME:  $GRPC_SERVICE_NAME"
echo "  自动切换组:         Voynix-Auto (url-test, 按延迟选优)"

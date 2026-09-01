#!/bin/sh
# Voynix Xray FC 部署脚本(本地调试)
#
# 用法:
#   ./scripts/deploy-fc.sh                  # 构建镜像 → 推送 → 部署全部节点(6 海外 + 6 国内)
#   ./scripts/deploy-fc.sh build hk         # 构建推送后仅部署香港
#   ./scripts/deploy-fc.sh deploy           # 跳过构建推送,仅部署(镜像已存在)
#   ./scripts/deploy-fc.sh deploy sg        # 仅部署新加坡
#   ./scripts/deploy-fc.sh deploy tokyo     # 仅部署东京
#   FC_NODES=sg,hk,tokyo ./scripts/deploy-fc.sh            # 按 FC_NODES 批量部署(逗号分隔,与 CI 语义一致)
#   FC_NODES=sg,hk,tokyo ./scripts/deploy-fc.sh deploy     # 跳过构建,仅部署 FC_NODES 指定节点
#
# 依赖:
#   - docker(Docker Desktop,Apple Silicon 亦可)、node/npm(首次自动装 Serverless Devs)
#   - .env(统一环境变量:common/deploy/client 三节,模板见 .env.example)
# 注意:
#   - Docker Hub 仓库必须是 Public,FC 拉取无需凭据
#   - 各节点均用 Docker Hub 公共镜像
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FC_DIR="${REPO_DIR}/fc"
IMAGE_NAME="${IMAGE_NAME:-voynix-xray}"   # Docker Hub 镜像名/FC 函数名前缀(公开 fork 可改,如 myproxy)

MODE="${1:-build}"    # build(默认) | deploy
TARGET="${2:-}"       # 可选:both(全部)| 节点键;未指定时用 FC_NODES 环境变量,仍无则部署全部

# ---------- 读取统一环境变量(根目录 .env:common/deploy/client 三节) ----------
ENV_FILE="${REPO_DIR}/.env"

[ -f "$ENV_FILE" ] || {
  echo "错误: 未找到 $ENV_FILE"
  echo "请先执行: cp .env.example .env 并填写"
  exit 1
}
. "$ENV_FILE"

UUID="${UUID:-}"
FC_BEARER_TOKEN="${FC_BEARER_TOKEN:-}"
WS_PATH="${WS_PATH:-ws}"

# ---------- 校验必需变量 ----------
fail() { echo "错误: $1"; exit 1; }
[ -n "$UUID" ] || fail "UUID 未设置($ENV_FILE)"
[ -n "$FC_BEARER_TOKEN" ] || fail "FC_BEARER_TOKEN 未设置($ENV_FILE,生产触发器已开启 Bearer 鉴权)"
[ -n "$ALIBABA_CLOUD_ACCOUNT_ID" ] || fail "ALIBABA_CLOUD_ACCOUNT_ID 未设置($ENV_FILE)"
[ -n "$ALIBABA_CLOUD_ACCESS_KEY_ID" ] || fail "ALIBABA_CLOUD_ACCESS_KEY_ID 未设置($ENV_FILE)"
[ -n "$ALIBABA_CLOUD_ACCESS_KEY_SECRET" ] || fail "ALIBABA_CLOUD_ACCESS_KEY_SECRET 未设置($ENV_FILE)"
[ -n "$DOCKERHUB_USERNAME" ] || fail "DOCKERHUB_USERNAME 未设置($ENV_FILE,各节点镜像仓库 owner)"

# s.yaml 中的 ${env(...)} 需要这些变量
export UUID IMAGE_NAME FC_BEARER_TOKEN WS_PATH
export DOCKERHUB_USERNAME
# 中转模式(仅 shanghai 等 relay 入口节点引用;RELAY_EXIT_HOST 空则该节点按直连模式部署)
export RELAY_EXIT_HOST="${RELAY_EXIT_HOST:-}"
export RELAY_EXIT_PORT="${RELAY_EXIT_PORT:-443}"
export RELAY_EXIT_TLS="${RELAY_EXIT_TLS:-true}"
# CN 地域镜像引用(加速镜像 + digest 固定,docker.io 直连不可达)
export RELAY_IMAGE="${RELAY_IMAGE:-}"

# ---------- 安装/检查 Serverless Devs ----------
if ! command -v s >/dev/null 2>&1; then
  echo "[deploy-fc] 未检测到 Serverless Devs,开始安装..."
  if command -v npm >/dev/null 2>&1; then
    npm install -g @serverless-devs/s
  else
    curl -o- https://cli.serverless-devs.com | bash
  fi
fi
command -v s >/dev/null 2>&1 || fail "Serverless Devs(s) 安装失败,请手动安装后重试"

# ---------- 配置阿里云凭证(access=default,与 s.yaml 对应) ----------
echo "[deploy-fc] 配置阿里云凭证 (access=default)"
s config add -a default \
  --AccountID "${ALIBABA_CLOUD_ACCOUNT_ID}" \
  --AccessKeyID "${ALIBABA_CLOUD_ACCESS_KEY_ID}" \
  --AccessKeySecret "${ALIBABA_CLOUD_ACCESS_KEY_SECRET}" \
  -f

# ---------- 构建 + 推送镜像 ----------
if [ "$MODE" != "deploy" ]; then
  [ -n "$DOCKERHUB_TOKEN" ] || fail "DOCKERHUB_TOKEN 未设置(构建模式需要)"

  echo "[deploy-fc] 构建镜像 (linux/amd64)..."
  docker build --platform linux/amd64 -t "${IMAGE_NAME}:latest" "$REPO_DIR/docker-image"

  echo "[deploy-fc] 推送 Docker Hub (双节点共用镜像)..."
  echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin >/dev/null
  docker tag "${IMAGE_NAME}:latest" "docker.io/${DOCKERHUB_USERNAME}/${IMAGE_NAME}:latest"
  docker push "docker.io/${DOCKERHUB_USERNAME}/${IMAGE_NAME}:latest"
fi

# ---------- 确定部署节点 ----------
# 优先级:命令行参数 > FC_NODES 环境变量 > 全部节点(both)
# FC_NODES 与 CI/gen-client-config.sh 语义一致:逗号分隔节点键;空/纯空白 → 显式报错
VALID_KEYS="sg hk tokyo frankfurt va sv hangzhou shanghai beijing zhangjiakou huhehaote shenzhen"

if [ -n "$TARGET" ]; then
  NODES="$TARGET"
elif [ -n "${FC_NODES:-}" ]; then
  [ -n "${FC_NODES//[[:space:]]/}" ] || fail "FC_NODES 为空或纯空白,未指定任何节点(示例: FC_NODES=sg,hk,tokyo)"
  NODES=$(echo "$FC_NODES" | tr ',' ' ')
else
  NODES="both"
fi

if [ "$NODES" != "both" ]; then
  for key in $NODES; do
    case " $VALID_KEYS " in
      *" $key "*) ;;
      *) fail "未知节点键 '$key'(可选: $VALID_KEYS,或 both 全部部署)" ;;
    esac
  done
fi

# shanghai 为中转入口节点:必须提供 RELAY_EXIT_HOST(出口节点 fcapp.run 域名)与 RELAY_IMAGE
# (CN 地域 FC 无法直连 docker.io,镜像走加速镜像 + digest 固定,见 .env deploy 节)
case " $NODES " in
  *" shanghai "*|*" both "*)
    [ -n "$RELAY_EXIT_HOST" ] || fail "RELAY_EXIT_HOST 未设置($ENV_FILE deploy 节)——shanghai 以中转模式部署,需指向出口节点域名(如 voynix-xray-tokyo-xxx.ap-northeast-1.fcapp.run,可用 gen-client-config.sh 查询)"
    [ -n "$RELAY_IMAGE" ] || fail "RELAY_IMAGE 未设置($ENV_FILE deploy 节)——CN 地域 FC 无法直连 docker.io,需加速镜像地址(digest 固定)"
    ;;
esac

# ---------- 部署 FC ----------
cd "$FC_DIR"
if [ "$NODES" = "both" ]; then
  echo "[deploy-fc] 部署 全部节点(6 海外 + 6 国内)..."
  s deploy -y
else
  for key in $NODES; do
    echo "[deploy-fc] 部署 $key..."
    s voynix-${key} deploy -y
  done
fi

echo "[deploy-fc] 完成 ✔ 请到 FC 控制台确认函数状态"

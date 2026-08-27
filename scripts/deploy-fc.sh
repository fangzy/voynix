#!/bin/sh
# Voynix Xray FC 部署脚本(本地调试)
#
# 用法:
#   ./scripts/deploy-fc.sh                  # 构建镜像 → 推送 → 部署全部节点(6 海外 + 6 国内)
#   ./scripts/deploy-fc.sh build hk         # 构建推送后仅部署香港
#   ./scripts/deploy-fc.sh deploy           # 跳过构建推送,仅部署(镜像已存在)
#   ./scripts/deploy-fc.sh deploy sg        # 仅部署新加坡
#   ./scripts/deploy-fc.sh deploy tokyo     # 仅部署东京
#
# 依赖:
#   - docker(Docker Desktop,Apple Silicon 亦可)、node/npm(首次自动装 Serverless Devs)
#   - docker-image/.env(运行时变量:UUID/GRPC_SERVICE_NAME)
#   - .env.deploy(部署凭据:Docker Hub/阿里云,模板见 .env.deploy.example)
# 注意:
#   - Docker Hub 仓库必须是 Public,FC 拉取无需凭据
#   - 各节点(新加坡/香港/首尔/东京)均用 Docker Hub 公共镜像
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FC_DIR="${REPO_DIR}/fc"
IMAGE_NAME="voynix-xray"

MODE="${1:-build}"    # build(默认) | deploy
TARGET="${2:-both}"   # both(全部)| sg | hk | tokyo | frankfurt | va | sv | hangzhou | shanghai | beijing | zhangjiakou | huhehaote | shenzhen

# ---------- 读取本地 env(运行时变量 + 部署凭据分开存放) ----------
RUNTIME_ENV="${REPO_DIR}/docker-image/.env"    # UUID / GRPC_SERVICE_NAME
DEPLOY_ENV="${REPO_DIR}/.env.deploy"           # Docker Hub / 阿里云凭据

[ -f "$RUNTIME_ENV" ] || {
  echo "错误: 未找到 $RUNTIME_ENV"
  echo "请先执行: cp docker-image/.env.example docker-image/.env 并填入 UUID"
  exit 1
}
[ -f "$DEPLOY_ENV" ] || {
  echo "错误: 未找到 $DEPLOY_ENV"
  echo "请先执行: cp .env.deploy.example .env.deploy 并填入部署凭据"
  exit 1
}
. "$RUNTIME_ENV"
. "$DEPLOY_ENV"

UUID="${UUID:-}"
GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-ProxyService}"

# ---------- 校验必需变量 ----------
fail() { echo "错误: $1"; exit 1; }
[ -n "$UUID" ] || fail "UUID 未设置($RUNTIME_ENV)"
[ -n "$ALIBABA_CLOUD_ACCOUNT_ID" ] || fail "ALIBABA_CLOUD_ACCOUNT_ID 未设置($DEPLOY_ENV)"
[ -n "$ALIBABA_CLOUD_ACCESS_KEY_ID" ] || fail "ALIBABA_CLOUD_ACCESS_KEY_ID 未设置($DEPLOY_ENV)"
[ -n "$ALIBABA_CLOUD_ACCESS_KEY_SECRET" ] || fail "ALIBABA_CLOUD_ACCESS_KEY_SECRET 未设置($DEPLOY_ENV)"
[ -n "$DOCKERHUB_USERNAME" ] || fail "DOCKERHUB_USERNAME 未设置($DEPLOY_ENV,各节点镜像仓库 owner)"

# s.yaml 中的 ${env(...)} 需要这些变量
export UUID GRPC_SERVICE_NAME
export DOCKERHUB_USERNAME

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

# ---------- 部署 FC ----------
cd "$FC_DIR"
case "$TARGET" in
  both)  echo "[deploy-fc] 部署 全部节点(6 海外 + 6 国内)..."; s deploy -y ;;
  sg)    echo "[deploy-fc] 部署 新加坡..."; s voynix-sg deploy -y ;;
  hk)    echo "[deploy-fc] 部署 香港...";   s voynix-hk deploy -y ;;
  tokyo) echo "[deploy-fc] 部署 东京...";   s voynix-tokyo deploy -y ;;
  frankfurt) echo "[deploy-fc] 部署 法兰克福..."; s voynix-frankfurt deploy -y ;;
  va)    echo "[deploy-fc] 部署 弗吉尼亚..."; s voynix-va deploy -y ;;
  sv)    echo "[deploy-fc] 部署 硅谷...";   s voynix-sv deploy -y ;;
  hangzhou) echo "[deploy-fc] 部署 杭州..."; s voynix-hangzhou deploy -y ;;
  shanghai) echo "[deploy-fc] 部署 上海..."; s voynix-shanghai deploy -y ;;
  beijing)  echo "[deploy-fc] 部署 北京..."; s voynix-beijing deploy -y ;;
  zhangjiakou) echo "[deploy-fc] 部署 张家口..."; s voynix-zhangjiakou deploy -y ;;
  huhehaote) echo "[deploy-fc] 部署 呼和浩特..."; s voynix-huhehaote deploy -y ;;
  shenzhen) echo "[deploy-fc] 部署 深圳..."; s voynix-shenzhen deploy -y ;;
  *)     fail "未知目标 '$TARGET'(可选: both|sg|hk|tokyo|frankfurt|va|sv|hangzhou|shanghai|beijing|zhangjiakou|huhehaote|shenzhen)" ;;
esac

echo "[deploy-fc] 完成 ✔ 请到 FC 控制台确认函数状态"

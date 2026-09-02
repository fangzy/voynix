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
# 保存调用方 FC_NODES(.env 的 FC_NODES 是默认值;显式环境变量应优先)
CALLER_FC_NODES="${FC_NODES:-}"
. "$ENV_FILE"
[ -z "$CALLER_FC_NODES" ] || FC_NODES="$CALLER_FC_NODES"

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
# aliyun CLI 凭据(GetTrigger 查询出口节点 fcapp.run 域名;与 Serverless Devs 的 s config 相互独立)
export ALIBABA_CLOUD_ACCESS_KEY_ID ALIBABA_CLOUD_ACCESS_KEY_SECRET
# 中转入口配置(单字段,格式:入口短码>出口短码,分号分隔多条;如 sh>hk = shanghai 入口链到 hk 出口)
# 入口/出口短码经 resolve_node_key 解析为真实节点 key;出口节点 fcapp.run 域名由下方自动查询(无需手填)
# 节点短码别名(新增别名在此扩展,与 gen-client-config.sh 保持一致)
resolve_node_key() {
  case "$1" in
    bj) echo "beijing" ;;
    hz) echo "hangzhou" ;;
    sh) echo "shanghai" ;;
    sz) echo "shenzhen" ;;
    *)  echo "$1" ;;
  esac
}
export RELAY_ENTRIES="${RELAY_ENTRIES:-}"
if [ -n "$RELAY_ENTRIES" ]; then
  # 定位 aliyun CLI(GetTrigger 查询出口域名所需;RELAY_ENTRIES 为空则用不到)
  if command -v aliyun >/dev/null 2>&1; then
    ALIYUN="aliyun"
  else
    ALIYUN="/private/tmp/aliyun"
  fi
  "$ALIYUN" --version >/dev/null 2>&1 || fail "未找到 aliyun CLI(需 aliyun fc GetTrigger 查询出口节点域名;请安装或设置 ALIYUN 路径)"
fi
# 查询节点 fcapp.run 域名(机制同 gen-client-config.sh:解析 s.yaml region/functionName → GetTrigger → urlInternet;结果缓存)
EXIT_HOST_CACHE=""
fetch_exit_host() {
  local key="$1" host meta region fn url
  host=$(echo "$EXIT_HOST_CACHE" | grep "^$key|" | head -1 | cut -d'|' -f2)
  [ -n "$host" ] && { echo "$host"; return 0; }
  meta=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$FC_DIR/s.yaml'))
res = d['resources'].get('voynix-$key')
if not res: sys.exit(1)
p = res['props']
region_var = p['region'].replace('\${vars.','').replace('}','')
print(f\"{d['vars'][region_var]}|{p['functionName']}\")
" 2>/dev/null) || return 1
  region="${meta%%|*}"
  fn="$(echo "${meta#*|}" | sed "s|\${env(IMAGE_NAME)}|${IMAGE_NAME}|g")"
  url="$("$ALIYUN" fc GetTrigger --region "$region" --functionName "$fn" --triggerName httpTrigger 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('httpTrigger', {}).get('urlInternet', ''))
except Exception:
    pass
")"
  [ -n "$url" ] || return 1
  host="$(echo "$url" | sed 's|https://||; s|/$||')"
  EXIT_HOST_CACHE="$EXIT_HOST_CACHE
$key|$host"
  echo "$host"
}
# 解析 RELAY_ENTRIES → "key|exit_host" 映射(key 为解析后的真实节点 key;出口域名自动查询)
RELAY_EXIT_MAP=""
if [ -n "$RELAY_ENTRIES" ]; then
  for entry in $(echo "$RELAY_ENTRIES" | tr ';' ' '); do
    entry_key=$(resolve_node_key "$(echo "$entry" | cut -d'>' -f1)")
    exit_key=$(resolve_node_key "$(echo "$entry" | cut -s -d'>' -f2)")
    exit_host=""
    if [ -n "$entry_key" ] && [ -n "$exit_key" ]; then
      exit_host=$(fetch_exit_host "$exit_key") || exit_host=""
      [ -n "$exit_host" ] || fail "RELAY_ENTRIES 中 $entry_key 的出口节点 $exit_key 未部署或无 URL(无法建立中转链路,先部署出口节点)"
    fi
    [ -n "$entry_key" ] && [ -n "$exit_host" ] && RELAY_EXIT_MAP="$RELAY_EXIT_MAP
$entry_key|$exit_host"
  done
fi
# s.yaml 的 ${env(RELAY_EXIT_HOST)} 需要此变量(每个入口节点部署前会覆写为对应出口)
# ⚠️ s 会对 s.yaml 全文件做 ${env()} 解析且空值报错("not found"):直连节点部署也须非空,用占位符(仅替换进 relay 块 YAML,不会被注入)
export RELAY_EXIT_HOST="${RELAY_EXIT_HOST:-direct.invalid}"
export RELAY_EXIT_PORT="${RELAY_EXIT_PORT:-443}"
export RELAY_EXIT_TLS="${RELAY_EXIT_TLS:-true}"
# CN 地域镜像:docker.io 直连不可达,走加速镜像 + digest 固定
# digest 由脚本查询 Docker Hub 自动构造(无需 .env 配置 RELAY_IMAGE;镜像站前缀可 RELAY_IMAGE_MIRROR 覆盖)
RELAY_IMAGE_MIRROR="${RELAY_IMAGE_MIRROR:-docker.1panel.live}"
RELAY_IMAGE=""
# 查询 Docker Hub 上 <user>/<image>:latest 的最新 digest,构造 CN 加速镜像地址(惰性调用,仅部署 CN 中转入口时执行)
query_relay_image() {
  [ -n "$RELAY_IMAGE" ] && return 0
  local repo="${DOCKERHUB_USERNAME}/${IMAGE_NAME}"
  local digest
  digest=$(curl -s --max-time 30 "https://hub.docker.com/v2/repositories/${repo}/tags/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('digest',''))" 2>/dev/null)
  if [ -z "$digest" ]; then
    fail "查询 Docker Hub digest 失败($repo:latest)——请检查网络或镜像是否已推送"
  fi
  RELAY_IMAGE="${RELAY_IMAGE_MIRROR}/${repo}@${digest}"
  export RELAY_IMAGE
  echo "[deploy-fc] CN 加速镜像(自动查询 digest): ${RELAY_IMAGE}"
}

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

# 校验:RELAY_ENTRIES 声明的中转入口必须在部署范围内且已提供出口/加速镜像
# (CN 地域 FC 无法直连 docker.io,镜像走加速镜像 + digest 固定,见 .env deploy 节)
if [ -n "$RELAY_EXIT_MAP" ]; then
  for line in $RELAY_EXIT_MAP; do
    entry_key=$(echo "$line" | cut -d'|' -f1)
    exit_host=$(echo "$line" | cut -d'|' -f2)
    case " $NODES " in
      *" $entry_key "*|*" both "*)
        [ -n "$exit_host" ] || fail "RELAY_ENTRIES 中 $entry_key 缺少出口域名(格式: 入口>出口,如 shanghai>hk)"
        query_relay_image   # 自动查询 Docker Hub digest 构造 CN 加速镜像(无需 .env 配置 RELAY_IMAGE)
        ;;
    esac
  done
fi

# s 对 s.yaml 全文件做 ${env(RELAY_IMAGE)} 解析且空值报错("not found"):纯直连部署也须非空,给非 digest 占位
# (仅替换进 relay 块 YAML,不会被部署;中转入口已在上面校验块用自动查询的 digest 覆写)
RELAY_IMAGE="${RELAY_IMAGE:-${RELAY_IMAGE_MIRROR}/${DOCKERHUB_USERNAME}/${IMAGE_NAME}:latest}"
export RELAY_IMAGE

# ---------- 部署 FC ----------
cd "$FC_DIR"
if [ "$NODES" = "both" ]; then
  echo "[deploy-fc] 部署 全部节点(6 海外 + 6 国内)..."
  # 逐个部署而非 s deploy -y:每个中转入口需在部署前注入自己的 RELAY_EXIT_HOST(RELAY_ENTRIES 解析)
  for key in $VALID_KEYS; do
    relay_exit=$(echo "$RELAY_EXIT_MAP" | grep "^$key|" | head -1 | cut -d'|' -f2)
    if [ -n "$relay_exit" ]; then
      export RELAY_EXIT_HOST="$relay_exit"
      echo "[deploy-fc]   $key: 中转入口,出口=$relay_exit"
    fi
    echo "[deploy-fc] 部署 $key..."
    s voynix-${key} deploy -y
  done
else
  for key in $NODES; do
    relay_exit=$(echo "$RELAY_EXIT_MAP" | grep "^$key|" | head -1 | cut -d'|' -f2)
    if [ -n "$relay_exit" ]; then
      export RELAY_EXIT_HOST="$relay_exit"
      echo "[deploy-fc]   $key: 中转入口,出口=$relay_exit"
    fi
    echo "[deploy-fc] 部署 $key..."
    s voynix-${key} deploy -y
  done
fi

echo "[deploy-fc] 完成 ✔ 请到 FC 控制台确认函数状态"

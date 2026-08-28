#!/bin/sh
# Voynix Xray 客户端配置生成脚本(自动获取 FC 节点域名)
#
# 用法:
#   ./scripts/gen-client-config.sh                  # 自动获取 s.yaml 中全部已部署节点
#   ./scripts/gen-client-config.sh sg hk tokyo      # 仅指定节点(逗号/空格分隔均可)
#
# 依赖:
#   - docker-image/.env(UUID/GRPC_SERVICE_NAME)
#   - .env.deploy(可选,FC_NODES 部署范围;不存在则仅用环境变量)
#   - aliyun CLI(默认 aliyun,找不到则用 /private/tmp/aliyun)
#   - python3(解析 s.yaml 与 FC API 输出)
#
# 原理:
#   1. 从 fc/s.yaml 读取节点清单(key → region/functionName)
#   2. 逐个调用 `aliyun fc GetTrigger` 获取 urlInternet(自动抓取真实 FC 域名)
#   3. 动态生成 proxies + proxy-groups,注入模板输出 clash-verge.yaml
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO_DIR}/docker-image/.env"
S_YAML="${REPO_DIR}/fc/s.yaml"
TEMPLATE="${REPO_DIR}/client-config/clash-verge.yaml.template"
OUTPUT="${REPO_DIR}/client-config/clash-verge.yaml"
PORT=8089  # FC gRPC 入口端口(所有节点一致)

# ---------- 定位 aliyun CLI ----------
if command -v aliyun >/dev/null 2>&1; then
  ALIYUN="aliyun"
else
  ALIYUN="/private/tmp/aliyun"
fi
"$ALIYUN" --version >/dev/null 2>&1 || { echo "错误: 未找到 aliyun CLI,请安装或配置路径"; exit 1; }

# ---------- 读取运行时变量 ----------
[ -f "$ENV_FILE" ] || {
  echo "错误: 未找到 $ENV_FILE"
  echo "请先执行: cp docker-image/.env.example docker-image/.env 并填入 UUID"
  exit 1
}
. "$ENV_FILE"

if [ -z "$UUID" ] || [ "$UUID" = "your-uuid-here" ]; then
  echo "错误: UUID 未设置($ENV_FILE)"
  exit 1
fi
GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-ProxyService}"

# ---------- 可选:读取 .env.deploy 中的 FC_NODES(与 deploy-fc.sh 语义一致) ----------
# 存在则 source,让 .env.deploy 里配置的 FC_NODES 同样作用于本脚本;
# 文件不存在(纯生成客户端,无需部署凭据)时跳过,仅用环境变量/命令行参数
DEPLOY_ENV="${REPO_DIR}/.env.deploy"
[ -f "$DEPLOY_ENV" ] && . "$DEPLOY_ENV"

# ---------- 镜像名/函数名前缀(公开 fork 可改,默认 voynix-xray) ----------
IMAGE_NAME="${IMAGE_NAME:-voynix-xray}"
# 客户端显示名前缀:取 IMAGE_NAME 首段并首字母大写(voynix-xray → Voynix)
CLIENT_PREFIX=$(echo "$IMAGE_NAME" | cut -d- -f1 | awk '{ print toupper(substr($0,1,1)) substr($0,2) }')

# ---------- 确定要生成的节点 ----------
# 优先级:命令行参数 > FC_NODES 环境变量 > 全部节点(s.yaml)
# FC_NODES 与 CI 语义一致:逗号分隔节点键,如 sg,hk,tokyo;设置为空/纯空白 → 显式报错
if [ $# -gt 0 ]; then
  # 用户指定节点:支持 "sg hk tokyo" 或 "sg,hk,tokyo"
  NODES=$(echo "$*" | tr ',' ' ')
elif [ -n "${FC_NODES:-}" ]; then
  # FC_NODES 环境变量(逗号分隔,复用 CI 的节点选择语义)
  if [ -z "${FC_NODES//[[:space:]]/}" ]; then
    echo "错误: FC_NODES 为空或纯空白,未指定任何节点"
    echo "请设置 FC_NODES(如 FC_NODES=sg,hk,tokyo)或去掉该变量以生成全部已部署节点"
    exit 1
  fi
  NODES=$(echo "$FC_NODES" | tr ',' ' ')
else
  # 默认全部节点(s.yaml 中定义的所有 resources)
  NODES=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$S_YAML'))
print(' '.join(k.replace('voynix-','') for k in d['resources']))
")
fi

echo "[gen-client-config] 目标节点: $NODES"
echo "[gen-client-config] 逐个获取 FC 域名(aliyun fc GetTrigger)..."
echo ""

# ---------- 逐节点获取域名 ----------
# 格式: "key|region|functionName|host"
NODE_LINES=""
for key in $NODES; do
  meta=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$S_YAML'))
res = d['resources'].get('voynix-$key')
if not res:
    sys.exit(1)
p = res['props']
region_var = p['region'].replace('\${vars.','').replace('}','')
print(f\"{d['vars'][region_var]}|{p['functionName']}\")
" 2>/dev/null) || {
    echo "  ⚠️ 跳过未知节点: $key(s.yaml 无 voynix-$key)"
    continue
  }
  region="${meta%%|*}"
  fn="${meta#*|}"
  # s.yaml 中 functionName 用 ${env(IMAGE_NAME)} 占位,解析为实际值
  fn=$(echo "$fn" | sed "s|\${env(IMAGE_NAME)}|${IMAGE_NAME}|g")

  url="$("$ALIYUN" fc GetTrigger --region "$region" --functionName "$fn" --triggerName httpTrigger 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # URL 嵌套在 httpTrigger 对象下(urlInternet)
    print(d.get('httpTrigger', {}).get('urlInternet', ''))
except Exception:
    print('')
")"

  if [ -z "$url" ]; then
    echo "  ⚠️ 节点 $key($fn @ $region)未部署或无 URL,跳过"
    continue
  fi
  host=$(echo "$url" | sed 's|https://||; s|/$||')
  NODE_LINES="$NODE_LINES
$key|$region|$fn|$host"
  echo "  ✅ $key: $host"
done

NODE_LINES=$(echo "$NODE_LINES" | sed '/^$/d')
if [ -z "$NODE_LINES" ]; then
  echo "错误: 没有任何可用节点(请先部署 FC 节点)"
  exit 1
fi

# ---------- 生成 proxies ----------
PROXIES=""
for line in $NODE_LINES; do
  key=$(echo "$line" | cut -d'|' -f1)
  host=$(echo "$line" | cut -d'|' -f4)
  # 节点名:两字母缩写(sg/hk/va/sv)全大写,多字母首字母大写
  name=$(echo "$key" | awk '{ if (length($0) == 2) print toupper($0); else print toupper(substr($0,1,1)) substr($0,2) }')
  PROXIES="$PROXIES
  # $name 节点(FC,自动获取域名)
  - name: \"${CLIENT_PREFIX}-$name\"
    type: vless
    server: $host
    port: $PORT
    uuid: $UUID
    network: grpc
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $host
    client-fingerprint: chrome
    grpc-opts:
      grpc-service-name: $GRPC_SERVICE_NAME
"
done

# ---------- 生成 proxy-groups ----------
GROUP_MEMBERS=""
for line in $NODE_LINES; do
  key=$(echo "$line" | cut -d'|' -f1)
  name=$(echo "$key" | awk '{ if (length($0) == 2) print toupper($0); else print toupper(substr($0,1,1)) substr($0,2) }')
  GROUP_MEMBERS="$GROUP_MEMBERS
      - ${CLIENT_PREFIX}-$name"
done

# 注意:变量名不用 GROUPS(bash 中是只读数组,赋值会静默失败)
GROUPS_TEXT="
proxy-groups:
  # 自动选优:按延迟(每 300s 测速)在所有节点间切换
  - name: \"${CLIENT_PREFIX}-Auto\"
    type: url-test
    url: 'http://www.gstatic.com/generate_204'
    interval: 300
    tolerance: 50
    proxies:$GROUP_MEMBERS

  - name: \"Proxy\"
    type: select
    proxies:
      - ${CLIENT_PREFIX}-Auto
      - DIRECT

  - name: \"Streaming\"
    type: select
    proxies:
      - ${CLIENT_PREFIX}-Auto
      - Proxy
"

# ---------- 注入模板输出 ----------
# 模板标记:# BEGIN_PROXIES / # END_PROXIES 与 # BEGIN_GROUPS / # END_GROUPS
# (macOS BSD awk 的 -v 不支持换行,改用 python3 注入)
export GEN_PROXIES="$PROXIES" GEN_GROUPS="$GROUPS_TEXT"
python3 - "$TEMPLATE" "$OUTPUT" <<'PYEOF'
import os, sys
tpl_path, out_path = sys.argv[1], sys.argv[2]
tpl = open(tpl_path).read()
proxies = os.environ.get('GEN_PROXIES', '').strip()
groups = os.environ.get('GEN_GROUPS', '').strip()
tpl = tpl.replace('# BEGIN_PROXIES\n# END_PROXIES', proxies)
tpl = tpl.replace('# BEGIN_GROUPS\n# END_GROUPS', groups)
open(out_path, 'w').write(tpl)
PYEOF

echo ""
echo "Generated: $OUTPUT"
echo "  节点数: $(echo "$NODE_LINES" | wc -l | tr -d ' ')"
echo "  端口:   $PORT"
echo "  UUID:   $UUID"
echo "  GRPC_SERVICE_NAME: $GRPC_SERVICE_NAME"
echo "  自动切换组: ${CLIENT_PREFIX}-Auto (url-test, 按延迟选优)"
echo ""
echo "校验: mihomo -t -f $OUTPUT"

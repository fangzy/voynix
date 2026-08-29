#!/bin/sh
# Voynix Xray 客户端配置生成脚本(自动获取 FC 节点域名)
#
# 用法:
#   ./scripts/gen-client-config.sh                  # 自动获取 s.yaml 中全部已部署节点
#   ./scripts/gen-client-config.sh sg hk tokyo      # 仅指定节点(逗号/空格分隔均可)
#   OUT_FILE=clash-verge-sg-tokyo.yaml ./scripts/gen-client-config.sh sg tokyo  # 自定义输出文件名(生成多份配置)
#
# 依赖:
#   - .env(统一环境变量:common/deploy/client 三节,模板见 .env.example)
#   - aliyun CLI(默认 aliyun,找不到则用 /private/tmp/aliyun)
#   - python3(解析 s.yaml 与 FC API 输出)
#
# 原理:
#   1. 从 fc/s.yaml 读取节点清单(key → region/functionName)
#   2. 逐个调用 `aliyun fc GetTrigger` 获取 urlInternet(自动抓取真实 FC 域名)
#   3. 动态生成 proxies + proxy-groups,注入模板输出 clash-verge.yaml
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"   # 统一环境变量(common/deploy/client 三节)
S_YAML="${REPO_DIR}/fc/s.yaml"
TEMPLATE="${REPO_DIR}/client-config/clash-verge.yaml.template"
# 输出文件名:可用 OUT_FILE 环境变量覆盖(如 OUT_FILE=clash-verge-sg-tokyo.yaml 生成多份配置)
OUT_FILE="${OUT_FILE:-clash-verge.yaml}"
OUTPUT="${REPO_DIR}/client-config/${OUT_FILE}"
PORT=443  # FC WSS 入口端口(8089 是 gRPC h2 专用,WS 升级会 500)

# ---------- 定位 aliyun CLI ----------
if command -v aliyun >/dev/null 2>&1; then
  ALIYUN="aliyun"
else
  ALIYUN="/private/tmp/aliyun"
fi
"$ALIYUN" --version >/dev/null 2>&1 || { echo "错误: 未找到 aliyun CLI,请安装或配置路径"; exit 1; }

# ---------- 读取统一环境变量 ----------
[ -f "$ENV_FILE" ] || {
  echo "错误: 未找到 $ENV_FILE"
  echo "请先执行: cp .env.example .env 并填写"
  exit 1
}
. "$ENV_FILE"

if [ -z "$UUID" ] || [ "$UUID" = "your-uuid-here" ]; then
  echo "错误: UUID 未设置($ENV_FILE)"
  exit 1
fi
FC_BEARER_TOKEN="${FC_BEARER_TOKEN:-}"
if [ -z "$FC_BEARER_TOKEN" ]; then
  echo "错误: FC_BEARER_TOKEN 未设置($ENV_FILE,生产触发器已开启 Bearer 鉴权)"
  exit 1
fi

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
  # $name 节点(FC,自动获取域名;VLESS+WS+WSS 443 + Bearer 鉴权)
  - name: \"${CLIENT_PREFIX}-$name\"
    type: vless
    server: $host
    port: $PORT
    uuid: $UUID
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $host
    client-fingerprint: chrome
    ws-opts:
      path: /ws
      headers:
        Authorization: Bearer $FC_BEARER_TOKEN
"
done

# ---------- 生成 proxy-groups ----------
# 先建立 key → 节点显示名 映射(key|Voynix-Name)
NODE_NAME_MAP=""
GROUP_MEMBERS=""
for line in $NODE_LINES; do
  key=$(echo "$line" | cut -d'|' -f1)
  name=$(echo "$key" | awk '{ if (length($0) == 2) print toupper($0); else print toupper(substr($0,1,1)) substr($0,2) }')
  NODE_NAME_MAP="$NODE_NAME_MAP
$key|${CLIENT_PREFIX}-$name"
  GROUP_MEMBERS="$GROUP_MEMBERS
      - ${CLIENT_PREFIX}-$name"
done

# 场景组(可选):SCENE_NODES="company=sg,tokyo;home=hk,tokyo"(分号分隔场景,逗号分隔节点 key)
# 每个场景生成 Auto(url-test)+LB(load-balance)子组;有场景时顶层 Voynix-Scene 直接列各场景 Auto/LB + 全量 Auto
SCENES_TEXT=""
SCENE_REF=""
if [ -n "${SCENE_NODES:-}" ]; then
  SCENE_SELECT_MEMBERS=""
  for scene in $(echo "$SCENE_NODES" | tr ';' ' '); do
    scene_name=$(echo "$scene" | cut -d= -f1)
    node_keys=$(echo "$scene" | cut -d= -f2- | tr ',' ' ')
    scene_display=$(echo "$scene_name" | awk '{ print toupper(substr($0,1,1)) substr($0,2) }')
    scene_members=""
    missing=""
    for k in $node_keys; do
      node_line=$(echo "$NODE_NAME_MAP" | grep "^$k|" | head -1)
      if [ -z "$node_line" ]; then
        missing="$missing $k"
      else
        scene_members="$scene_members
      - ${node_line#*|}"
      fi
    done
    if [ -n "$missing" ] || [ -z "$scene_members" ]; then
      echo "  ⚠️ 跳过场景 $scene_name: 节点缺失($missing)或为空"
      continue
    fi
    SCENES_TEXT="$SCENES_TEXT
  # $scene_display 场景:按延迟选优
  - name: \"${CLIENT_PREFIX}-$scene_display-Auto\"
    type: url-test
    url: 'https://github.com/manifest.json'
    interval: 300
    tolerance: 50
    proxies:$scene_members

  # $scene_display 场景:负载均衡
  - name: \"${CLIENT_PREFIX}-$scene_display-LB\"
    type: load-balance
    strategy: round-robin
    url: 'https://github.com/manifest.json'
    interval: 300
    proxies:$scene_members
"
    SCENE_SELECT_MEMBERS="$SCENE_SELECT_MEMBERS
      - ${CLIENT_PREFIX}-$scene_display-Auto
      - ${CLIENT_PREFIX}-$scene_display-LB"
  done
  if [ -n "$SCENE_SELECT_MEMBERS" ]; then
    SCENES_TEXT="$SCENES_TEXT
  # 场景切换:各场景 Auto/LB + 全量 Auto
  - name: \"${CLIENT_PREFIX}-Scene\"
    type: select
    proxies:$SCENE_SELECT_MEMBERS
      - ${CLIENT_PREFIX}-Auto
"
    SCENE_REF="
      - ${CLIENT_PREFIX}-Scene"
  fi
fi

# 注意:变量名不用 GROUPS(bash 中是只读数组,赋值会静默失败)
# 有场景时精简结构:去掉全量 LB,Proxy/Streaming 指向 Scene;无场景时保持原结构(Auto+LB)
if [ -n "$SCENE_REF" ]; then
  LB_BLOCK=""
  PROXY_MEMBERS="$SCENE_REF
      - DIRECT"
  STREAMING_MEMBERS="
      - ${CLIENT_PREFIX}-Scene
      - Proxy"
else
  LB_BLOCK="
  # 负载均衡:连接轮询分发到所有节点
  - name: \"${CLIENT_PREFIX}-LB\"
    type: load-balance
    strategy: round-robin
    url: 'https://github.com/manifest.json'
    interval: 300
    proxies:$GROUP_MEMBERS
"
  PROXY_MEMBERS="
      - ${CLIENT_PREFIX}-Auto
      - ${CLIENT_PREFIX}-LB
      - DIRECT"
  STREAMING_MEMBERS="
      - ${CLIENT_PREFIX}-Auto
      - Proxy"
fi

GROUPS_TEXT="
proxy-groups:
  # 时间优先:按延迟(每 300s 测速)选最优节点
  - name: \"${CLIENT_PREFIX}-Auto\"
    type: url-test
    url: 'https://github.com/manifest.json'
    interval: 300
    tolerance: 50
    proxies:$GROUP_MEMBERS
$LB_BLOCK$SCENES_TEXT  # 切换开关:场景组(如有) / 时间优先(Auto) / 负载均衡(LB)
  - name: \"Proxy\"
    type: select
    proxies:$PROXY_MEMBERS

  - name: \"Streaming\"
    type: select
    proxies:$STREAMING_MEMBERS
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
echo "  端口:   $PORT (WSS)"
echo "  UUID:   $UUID"
echo "  传输:   WebSocket(path /ws)+ Bearer 鉴权"
echo "  自动切换组: ${CLIENT_PREFIX}-Auto (url-test, 按延迟选优)"
echo ""
echo "校验: mihomo -t -f $OUTPUT"

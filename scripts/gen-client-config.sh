#!/bin/sh
# Voynix Xray 客户端配置生成脚本(自动获取 FC 节点域名)
#
# 用法:
#   ./scripts/gen-client-config.sh                  # 自动获取 s.yaml 中全部已部署节点
#   ./scripts/gen-client-config.sh sg hk tokyo      # 仅指定节点(逗号/空格分隔均可)
#   OUT_FILE=clash-verge-sg-tokyo.yaml ./scripts/gen-client-config.sh sg tokyo  # 自定义输出文件名(生成多份配置)
#   RELAY_ENTRIES="sh>hk" ./scripts/gen-client-config.sh sg hk tokyo shanghai
#                                                   # 附带生成中继节点(客户端只连入口,转发链在服务端完成)
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
PORT=443  # FC WSS 入口端口

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
# 保存调用方覆盖值(.env 的 FC_NODES/RELAY_ENTRIES 是默认值;显式环境变量应优先)
CALLER_FC_NODES="${FC_NODES:-}"
CALLER_RELAY_ENTRIES="${RELAY_ENTRIES:-}"
. "$ENV_FILE"
[ -z "$CALLER_FC_NODES" ] || FC_NODES="$CALLER_FC_NODES"
[ -z "$CALLER_RELAY_ENTRIES" ] || RELAY_ENTRIES="$CALLER_RELAY_ENTRIES"

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

# 节点短码别名:RELAY_ENTRIES 入口可写短码(解析为真实节点 key;新增别名在此扩展,与 deploy-fc.sh 保持一致)
resolve_node_key() {
  case "$1" in
    bj) echo "beijing" ;;
    hz) echo "hangzhou" ;;
    sh) echo "shanghai" ;;
    sz) echo "shenzhen" ;;
    *)  echo "$1" ;;
  esac
}

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

# 中继入口自动并入生成范围(与部署语义一致:FC_NODES/默认 ∪ RELAY_ENTRIES 入口;
# 否则入口不在 FC_NODES 时会整条路由跳过——如 sz>sg 而 FC_NODES 无 shenzhen 时只有 sh-hk)
# 显式命令行参数时保持精确,不自动并入(与 deploy-fc.sh 单节点 TARGET 语义一致)
if [ $# -eq 0 ] && [ -n "${RELAY_ENTRIES:-}" ]; then
  for route in $(echo "$RELAY_ENTRIES" | tr ';' ' '); do
    chain="${route#*=}"   # 兼容旧格式 name=入口>出口
    entry_key=$(resolve_node_key "$(echo "$chain" | cut -d'>' -f1)")
    [ -n "$entry_key" ] || continue
    case " $NODES " in
      *" $entry_key "*) ;;
      *) NODES="$NODES $entry_key"; echo "[gen-client-config] 中继入口 $entry_key 自动加入生成范围(RELAY_ENTRIES 声明)" ;;
    esac
  done
fi

echo "[gen-client-config] 目标节点: $NODES"
echo "[gen-client-config] 逐个获取 FC 域名(aliyun fc GetTrigger)..."

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
# 每个场景生成一个 url-test 组(测速间隔 900s/15 分钟);Voynix-Scene 用于手动切换场景
SCENES_TEXT=""
SCENE_SELECT_MEMBERS=""
if [ -n "${SCENE_NODES:-}" ]; then
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
  # $scene_display 场景:按延迟选优(每 15 分钟测速)
  - name: \"${CLIENT_PREFIX}-$scene_display\"
    type: url-test
    url: 'https://github.com/manifest.json'
    interval: 900
    tolerance: 50
    proxies:$scene_members
"
    SCENE_SELECT_MEMBERS="$SCENE_SELECT_MEMBERS
      - ${CLIENT_PREFIX}-$scene_display"
  done
  # Voynix-Scene 组延后到 relay 段后统一生成(需条件性把 Voynix-Relay 加入可选成员)
fi

# 中继节点生成(与部署共用 RELAY_ENTRIES 单字段:入口短码>出口短码,分号分隔;节点名自动=入口-出口,如 sh>hk → Voynix-sh-hk)
# 兼容旧格式 name=入口>出口(显式节点名);中继节点 = 客户端只连入口节点,链路在服务端完成(入口以中转模式部署)
# 入口节点必须已在本次生成范围且已部署(取其域名);出口节点客户端配置不引用,仅校验 key 拼写
RELAY_PROXIES=""
RELAY_MEMBERS=""
if [ -n "${RELAY_ENTRIES:-}" ]; then
  for route in $(echo "$RELAY_ENTRIES" | tr ';' ' '); do
    if echo "$route" | grep -q '='; then
      route_name=$(echo "$route" | cut -d= -f1)   # 旧格式:显式节点名
      chain=$(echo "$route" | cut -d= -f2-)
    else
      chain="$route"                               # 新格式:入口短码>出口短码,节点名自动
      entry_token=$(echo "$chain" | cut -d'>' -f1)
      exit_token=$(echo "$chain" | cut -s -d'>' -f2)
      [ -n "$entry_token" ] && [ -n "$exit_token" ] && route_name="${entry_token}-${exit_token}"
    fi
    entry_key=$(resolve_node_key "$(echo "$chain" | cut -d'>' -f1)")
    exit_key=$(echo "$chain" | cut -s -d'>' -f2)
    if [ -z "$route_name" ] || [ -z "$entry_key" ] || [ -z "$exit_key" ]; then
      echo "  ⚠️ 跳过格式错误的中继路由 '$route'(格式: 入口短码>出口短码,如 sh>hk)"
      continue
    fi
    entry_line=$(echo "$NODE_LINES" | grep "^$entry_key|" | head -1)
    if [ -z "$entry_line" ]; then
      echo "  ⚠️ 跳过中继路由 $route_name: 入口节点 $entry_key 未部署或不在本次生成范围"
      continue
    fi
    if ! python3 -c "
import yaml, sys
d = yaml.safe_load(open('$S_YAML'))
sys.exit(0 if 'voynix-$exit_key' in d['resources'] else 1)
" 2>/dev/null; then
      echo "  ⚠️ 中继路由 $route_name 的出口 '$exit_key' 不在 s.yaml,请确认拼写"
    fi
    entry_host=$(echo "$entry_line" | cut -d'|' -f4)
    RELAY_PROXIES="$RELAY_PROXIES
  # 中继 ${entry_key}→${exit_key}(客户端→入口节点,服务端转发至出口;连接参数=入口节点)
  - name: \"${CLIENT_PREFIX}-$route_name\"
    type: vless
    server: $entry_host
    port: $PORT
    uuid: $UUID
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $entry_host
    client-fingerprint: chrome
    ws-opts:
      path: /ws
      headers:
        Authorization: Bearer $FC_BEARER_TOKEN
"
    RELAY_MEMBERS="$RELAY_MEMBERS
      - ${CLIENT_PREFIX}-$route_name"
    echo "  🔗 中继路由: ${CLIENT_PREFIX}-$route_name = $entry_key → $exit_key"
  done
  PROXIES="$PROXIES$RELAY_PROXIES"
fi

# 中继组:仅在有中继路由(RELAY_MEMBERS 非空)时生成;Proxy-Download 无中继时回退仅场景组
RELAY_GROUP_TEXT=""
DOWNLOAD_MEMBERS="      - ${CLIENT_PREFIX}-Scene"
SCENE_RELAY_MEMBER=""
if [ -n "$RELAY_MEMBERS" ]; then
  RELAY_GROUP_TEXT="
  # 中继链路:手动选择(客户端只连入口,转发链在服务端完成)
  - name: \"${CLIENT_PREFIX}-Relay\"
    type: select
    proxies:$RELAY_MEMBERS
"
  DOWNLOAD_MEMBERS="      - ${CLIENT_PREFIX}-Relay
      - ${CLIENT_PREFIX}-Scene"
  SCENE_RELAY_MEMBER="
      - ${CLIENT_PREFIX}-Relay"
fi

# Voynix-Scene 场景切换组(在 relay 解析后生成):成员 = 各场景 url-test 组 + [有中继时] Voynix-Relay(可直接选中继链路)
SCENE_TEXT=""
if [ -n "$SCENE_SELECT_MEMBERS" ]; then
  SCENE_TEXT="
  # 场景切换:手动选择场景组 / 中继链路
  - name: \"${CLIENT_PREFIX}-Scene\"
    type: select
    proxies:$SCENE_SELECT_MEMBERS$SCENE_RELAY_MEMBER
"
fi

# 注意:变量名不用 GROUPS(bash 中是只读数组,赋值会静默失败)
# 组结构(2026-09-02 重构):
#   Voynix-<Scene>(url-test,900s) → Voynix-Relay(有中继时) → Voynix-Scene(select,可选中继) → Proxy(select)
#   [RELAY_ENTRIES 非空时] Voynix-Relay(select) → Proxy-Download(select) ← 外网下载域名专用
#   (组顺序按成员引用排列,避免前向引用)
GROUPS_TEXT="
proxy-groups:
$SCENES_TEXT$RELAY_GROUP_TEXT$SCENE_TEXT
  # 下载专用:外网下载域名走此组(规则见模板 rules);有中继时默认 Relay
  - name: \"Proxy-Download\"
    type: select
    proxies:
$DOWNLOAD_MEMBERS

  # 常规代理出口:跟随场景切换
  - name: \"Proxy\"
    type: select
    proxies:
      - ${CLIENT_PREFIX}-Scene
      - DIRECT
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

# ---------- 刷新 jsdelivr 规则文件缓存(purge) ----------
# 背景:jsdelivr gh @main 浮动标签在 push 后各边缘节点缓存不一致,易拉回旧内容(2026-09-03 实测多次回退,
# 症状:provider ruleCount>0 但内容是旧版/裸条目)。改过 custom-*.txt 并 push 后重跑本脚本即自动 purge,
# 保证客户端下次拉取得到新版。可用 GEN_SKIP_PURGE=1 跳过;仓库/用户与模板 rule-providers url 需一致(fork 时同步改)
if [ "${GEN_SKIP_PURGE:-0}" != "1" ]; then
  echo "[gen-client-config] 刷新 jsdelivr 规则文件缓存(purge)..."
  for f in custom-reject custom-direct custom-download custom-proxy; do
    st=$(curl -sf -m 20 "https://purge.jsdelivr.net/gh/fangzy/voynix@main/client-config/$f.txt" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
    if [ -n "$st" ]; then echo "  ✅ $f: purge $st"; else echo "  ⚠️ $f: purge 失败(网络/仓库不可达,可稍后手动 purge 或忽略)"; fi
  done
else
  echo "[gen-client-config] 已跳过 jsdelivr purge(GEN_SKIP_PURGE=1)"
fi

echo ""
echo "Generated: $OUTPUT"
echo "  节点数: $(echo "$NODE_LINES" | wc -l | tr -d ' ')$(if [ -n "$RELAY_MEMBERS" ]; then echo " + 中继 $(echo "$RELAY_MEMBERS" | grep -c '^ *- ' | tr -d ' ') 条"; fi)"
echo "  端口:   $PORT (WSS)"
echo "  UUID:   $UUID"
echo "  传输:   WebSocket(path /ws)+ Bearer 鉴权"
echo "  自动切换组: ${CLIENT_PREFIX}-Auto (url-test, 按延迟选优)"
echo ""
echo "校验: mihomo -t -f $OUTPUT"

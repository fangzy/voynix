# Voynix 运维笔记（内部）

> 本文件为项目内部运维记录，**不面向公开用户**。README 只保留对使用者有价值的内容，以下实测数据、部署细节、个人环境问题与历史变更统一归档于此。

## 实测经验（2026-08）

### 节点历史

旧新加坡函数 `proxy_service$xray-exit`（ACR 镜像）已于 2026-08 删除，由 `voynix-xray-sg` 接管。

### 镜像推送（Docker Hub）

本机 `docker push` 会被 Docker Desktop 自动检测出的死代理（3128）拦截，报 `EOF`/`broken pipe`。绕行方案：用 `crane`（go-containerregistry）直连推送，复用 `docker login` 凭据：

```bash
docker save voynix-xray:latest -o /tmp/voynix.tar
crane push /tmp/voynix.tar docker.io/<user>/voynix-xray:latest
```

### 客户端端口必须是 443（WSS）

FC WS 入口端口为 443（WSS，FC 网关终止 TLS）。

### FC 节点验证方式

不要用裸 `curl` 测 FC 节点——HTTP 触发器开了 Bearer 鉴权:无 token/错 token → 403,对 token + `Upgrade: websocket` 头 → 101（路径不匹配/旧实例 → 404）,对 token 的普通 HTTP 请求 → 400（已过网关到容器,但不是 WS 升级）。用真实 mihomo 客户端验证:

```bash
mihomo -f client-config/clash-verge.yaml
curl -x http://127.0.0.1:7890 https://www.google.com   # 返回 204 即为通
```

### 实例数 vs 并发数（压测结论）

控制台"弹性实例配额"列显示/编辑的就是 `concurrencyConfig.reservedConcurrency`（预留并发，单位 = 并发请求数），**不是实例数上限**；真正的实例数上限字段 `targetInstances`（GetScalingConfig）未设置时弹性不限。实例数由 FC 按流量弹性创建——压测 100 并发 HTTP（经 mihomo）时监控显示 **3 个活跃实例**，全程**无 429**：长连接复用使 FC 端实际并发请求数未触及 15 上限，少量请求失败（SSL/HTTP2 framing）为本机链路问题而非 FC 流控。若需硬性实例数上限，须在 FC 控制台"函数配额"设置（超限返回 429）。

### WebSocket 传输实验(2026-08-29,SG)

同镜像 TRANSPORT=ws 切换（当日已移除 gRPC 回退、模板收敛为单一 `config.template.json`），部署用 `fc/s.ws.yaml` + `:ws` 镜像 tag，函数 `voynix-xray-ws-sg` 与生产并存。结论：

- **延迟对比**（SG，gRPC 8089 vs WS 443，mihomo delay API 16 轮交错）：中位数几乎相同（~233ms），WS 更稳定（0 失败 vs gRPC 2 次失败，后者为 FC 实例回收后的死连接，keepalive 也救不回已回收实例）
- **带宽对比**（绕开本机 Clash TUN 后干净链路复测）：单流 ~12-16KB/s（gRPC 与 WS 完全相同），多目标（CF/OVH）一致，4 并行聚合也仅 ~40KB/s——瓶颈是本机到境外的跨境单流限速，与传输协议无关；gRPC/WS 帧开销差异（亚 1%）在噪声内不可分辨
- WS 无应用层保活（Xray WS 无 ping 配置），依赖 TCP keepalive + 客户端 keep-alive-interval

### 全量 WS 切换(2026-08-29)

按 SG 实验结论将生产全部改为 VLESS+WS+Bearer 鉴权——entrypoint 默认 TRANSPORT=ws、s.yaml 锚点加 `TRANSPORT: ws` / `WS_PATH: ${env(WS_PATH)}` / 触发器 `authType: bearer`（BearerFormat: opaque + opaqueTokenConfig）、deploy-fc.sh 与 gen-client-config.sh 支持 FC_BEARER_TOKEN/WS_PATH、客户端生成 WS(443)+Bearer。部署验证：sg/hk/tokyo 裸握手 101、delay SG 225ms/HK 78ms/Tokyo 161ms、代理实测全部 HTTP 200。

踩坑：
1. entrypoint 未 export 时 envsubst 把 WS_PATH 替换成空串（path=`/` → 404）
2. 部署后 FC 实例未更新时新请求仍路由旧 gRPC 实例（404），需重新部署+等实例回收
3. 本机经 Clash TUN 时 DNS 被 fake-ip 污染，mihomo CONNECT 隧道目标变假 IP（经 SG 跳板推镜像时需关 TUN 或用干净配置）

同日进一步移除 gRPC 回退：entrypoint 无 TRANSPORT 分支、模板收敛为单一 `config.template.json`(WS)、删除 GRPC_SERVICE_NAME/TRANSPORT 环境变量及相关文档。

### SG WS 节点 Bearer 鉴权与会话亲和实验(2026-08-29,fc/s.ws.yaml)

- **Bearer 鉴权**（fc3 触发器 `authType: bearer`）：authConfig 结构为 `BearerFormat: opaque` + `opaqueTokenConfig.tokens:[{enable,tokenData,tokenName}]`（值写 `Opaque` 报 "Opaque is invalid"，裸 `tokens` 报 "BearerFormat is required"；token 32-128 字符 Base64 字符集，存 .env common 节，gitignored）。验证：无 token/错 token → 403，对 token + WS 升级 → 101，普通请求对 token → 400（过网关到容器）
- **客户端携带**：mihomo `ws-opts.headers` 可带 `Authorization: Bearer <token>`（端到端验证 delay 225ms/HTTP 200）；`grpc-opts` 无 headers 字段 → gRPC 客户端无法过 Bearer 鉴权（鉴权曾是 WS 独有优势；gRPC 现已彻底移除）
- **Cookie 会话亲和**：fc3 字段是 `sessionAffinity: GENERATED_COOKIE`（枚举 GENERATED_COOKIE/HEADER_FIELD/MCP_SSE/NONE）+ `sessionAffinityConfig`（sessionConcurrencyPerInstance/sessionIdleTimeoutInSeconds/sessionTTLInSeconds）；写 `sessionAffinity: cookie` 报 invalid，`sessionAffinityConfig: cookie` 被静默忽略（sessionAffinity 显示 NONE）。开启后 **instanceConcurrency 强制 200**（报 "ConcurrencyLimit is invalid for session function, allowed: 200"）。实测 WS 101 握手响应**不植入 Set-Cookie**（x-fc-cookie-session-id），mihomo 也不管理 cookie → 会话亲和对 VLESS+WS 代理连接无效（长连接本身有连接级亲和），与 2026-08 早前 gRPC 时代结论一致；开启亲和后代理功能正常
- **HeaderField 会话亲和**（`sessionAffinity: HEADER_FIELD` + `sessionAffinityConfig.affinityHeaderFieldName: mySessionId`，FC 会把 header 名规范化为小写 mysessionid）：**客户端传入模式可行**——mihomo `ws-opts.headers` 带固定 `mySessionId` 值即实现粘性，与 Bearer（Authorization 头）共存验证 delay 243ms/HTTP 200。实例调度验证（s instance list）：4 个新 distinct 会话值 → 新增 2 实例（正好 = 4 会话 ÷ sessionConcurrencyPerInstance=2）；复用同一值 4 次 → 实例零增长（粘在同一实例）。服务端生成模式（不带 header）下 WS 101 响应同样不回传 session ID 头，与 Cookie 一样不适用于代理。注意：固定 header 值会把**所有连接都钉到一个实例**（0.1 vCPU 实例上集中负载）；个人代理场景无实际收益，且同样丢失 instanceConcurrency=30 的并发控制 → **建议不启用**
- 2026-08 早前（gRPC 时代）session affinity 也曾尝试并回退：4 种亲和类型对 VLESS+gRPC 均无效（客户端不处理 cookie/自定义头）
- 部署：`cd fc && s deploy -t s.ws.yaml -y`（需 export FC_BEARER_TOKEN）

### 本地 tcpFastOpen 踩坑

本地 Docker Desktop（qemu amd64）下容器带 tcpFastOpen:true 会导致连接被重置/400（mihomo/裸握手均失败），生产 FC 不受影响；本地联调需去掉 tcpFastOpen。

## 内部故障排查

### Docker Desktop 死代理导致 docker push 失败（EOF / broken pipe）

原因：Docker Desktop 自动检测系统代理（被 Clash fake-ip 劫持的 WPAD），配出 3128 死代理。
修复：用 `crane` 直连推送绕开 daemon 代理（见上文「镜像推送」）。

### FC 实例反复创建/销毁，日志显示健康检查通过但请求失败

检查项：

- 用 `s` 查看函数信息确认镜像已解析：`cd fc && s voynix-hk info`（state: Active 且 resolvedImageUri 已解析）
- 确认客户端连的是 443 端口（WSS）
- 查看日志：`cd fc && s voynix-hk logs --tail`（需 logConfig 已配置）

## 会话记忆补充

### 客户端国外遥测域名 REJECT(2026-08-30)

分析本机 Clash Verge 内核日志（`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/service-logs/service/*.log`）发现的遥测上报:

- **国内**（走 GEOSITE cn DIRECT，不耗代理，不加规则）:阿里 SLS XTrace（`proj-xtrace-*.log.aliyuncs.com`，频次最高）、RUM 前端监控（`*.rum.aliyuncs.com`）、mmstat 埋点、字节 `mon/mcs.zijieapi.com`、`mon-va.byteoversea.com`、`mssdk.bytedance.com`、火山 `gator.volces.com`、神策 `*.datasink.sensorsdata.cn`、Edge `browser.events.data.msn.cn`。
- **国外**（命中 geolocation-!cn → Proxy，耗代理流量 → REJECT）:微软 `mobile.events.data.microsoft.com`、VS Code A/B 实验 `default.exp-tas.com`（禁用遥测仍每 30 分钟上报）、Google `analytics.google.com` / `googletagmanager.com` / `doubleclick.net`、Comscore `scorecardresearch.com`、Sentry `*.ingest.sentry.io`（错误监控上报，`o<orgid>.ingest.us.sentry.io` 为美国区 ingest 端点；注意 `DOMAIN-SUFFIX,ingest.sentry.io` 匹配不到带区域前缀的形式，直接用 `DOMAIN-SUFFIX,sentry.io`）。

已按此在 `client-config/clash-verge.yaml.template` rules 顶部加 7 条国外遥测 REJECT（置于所有 DIRECT/Proxy 规则之前；2026-08-31 补加 sentry.io）。注意 `mobile.events.data.microsoft.com` 原被 `events.data.microsoft.com` DIRECT 兜住，REJECT 后完全不外发。mihomo 校验需 `-d` 指向含 geosite.dat 的目录（否则联网下载 geodata 卡住）。

### 客户端 rules 改用 Loyalsoldier 规则集(2026-08-31)

模板 rules 尾部由手写 GEOSITE/GEOIP 兜底改为 Loyalsoldier/clash-rules 全量 13 个 rule-providers（jsdelivr CDN，每日 6:30 自动构建，本地缓存 `./ruleset/`）:reject REJECT;apple/icloud/direct/private/lancidr/cncidr DIRECT;google/proxy/gfw/tld-not-cn/telegramcidr Proxy;applications DIRECT（PROCESS-NAME 规则，2026-08-31 起模板 find-process-mode 改为 always 使其生效；注意 strict/on 对 provider 内进程规则不匹配，官方 issue 明确需 always）;结尾 MATCH,DIRECT（黑名单模式）。7 条国外遥测 REJECT、MSN/Bing、系统打点、Apple 证书 CA、Edge/VS Code 直连等手写规则保留为覆盖层（置于规则集之前）。注意:

- `GEOSITE,cn,DIRECT` 保留且须在 `tld-not-cn`（等效原 geolocation-!cn）之前，否则海外 CDN IP 上的国内域名会误走代理
- reject.txt 大概率已覆盖 googletagmanager/doubleclick/scorecardresearch;遥测覆盖层保留兜底，后续可用 mihomo 日志观察是否有重复命中再精简
- `mihomo -t` 校验会联网拉取 13 个规则集（jsdelivr），离线或 CDN 不可达时会失败

### 客户端组结构重构(2026-09-02)

gen-client-config.sh 组生成逻辑重构：去掉全量 Auto 与场景 LB 组；每个场景一个 url-test 组（Voynix-Company=SG+Tokyo / Voynix-Home=HK+Tokyo，interval 900s/15 分钟）；Voynix-Scene(select) 切换场景；新增 Voynix-Relay(select,全部中继节点) 与 Proxy-Download(select,[Relay, Scene])，外网下载域名（release-assets.githubusercontent.com / objects.githubusercontent.com / codeload.github.com / raw.githubusercontent.com / dl.google.com / download.jetbrains.com）走 Proxy-Download。中转部署配置同日记为单字段 `RELAY_ENTRIES="sh>hk;sz>sg"`（入口短码>出口短码，分号分隔；短码 sh=shanghai/sz=shenzhen 由 deploy-fc.sh 内置别名解析，出口 fcapp.run 域名部署时经 aliyun fc GetTrigger 自动查询、无需手填），逐个解析注入（`RELAY_EXIT_HOST` 仅为 s.yaml 占位，2026-09-02 起 FC_NODES 自动并集中转入口(声明即部署,CI 与 deploy-fc.sh 一致),无需再手动 `FC_NODES=shanghai,shenzhen` 列出入口;单节点部署参数仍精确部署）。RELAY_ROUTES 已于 2026-09-02 并入 RELAY_ENTRIES(去重:同一字段驱动部署与客户端中继节点生成)。当前生效链路：shanghai→hk、shenzhen→sg（sh-sg/sz-hk/bj-tokyo 路由已移除，beijing 恢复直连）。同日合并删除 Streaming 组（youtube/googlevideo/netflix 三条流媒体规则并入 Proxy；原 Streaming 成员 [Scene, Proxy] 两条路径都汇到 Scene，功能冗余）。

## 客户端 rules 独立文件化(2026-09-03)

背景：客户端模板 rules 顶部的自定义覆盖层（遥测 REJECT/功能直连/Proxy-Download 域名/GEOSITE cn）原先内联在 `clash-verge.yaml.template` 里，逐行与 Loyalsoldier 规则集混排。当日目标：规则独立成文件维护、便于分发。方案当日演进三次：

1. **注入方案（初版，已实现又回退）**：模板留 `# BEGIN_CUSTOM_RULES/# END_CUSTOM_RULES` 标记，`gen-client-config.sh` 生成时把 `custom-rules.yaml` 内容拼入 rules 顶部（python 注入，逐行 diff 校验一致）。运行时输出不变，但改规则需重跑 gen。
2. **rule-provider 能力实测**（用户问能否用 provider 方式）：
   - `behavior: classical` 支持 DOMAIN/DOMAIN-SUFFIX/DOMAIN-REGEX/GEOSITE/AND 复合/逐行不同目标（`mihomo -t` 实测通过）；
   - `type: file` provider 的 `path` 以 mihomo 运行 home（`-d`）为基准，不是配置文件目录；
   - **http provider 拉取失败时 `mihomo -t` 仍返回成功**——provider 被静默跳过、对应组规则缺失且无告警（本地校验必须用 file provider 兜底，勿信裸 -t 通过）。
3. **终版（去耦合）**：用户选定 http provider + 仓库公开走 jsdelivr（`cdn.jsdelivr.net/gh/fangzy/voynix@main/client-config/custom-*.txt`，behavior domain，interval 86400，与 Loyalsoldier 同构）。后发现 classical 文件**每行自带策略目标** → 规则文件与 `Proxy`/`Proxy-Download` 组名强耦合（改组名/被其它配置复用即失效）→ 拆为 4 个纯域名列表 `custom-{reject,direct,download,proxy}.txt`（纯数据不含策略名），策略绑定与顺序收敛到模板 rules 顶部「装配」块：AND-REJECT > custom-reject(REJECT) > custom-proxy(Proxy) > custom-direct(DIRECT) > custom-download(Proxy-Download) > GEOSITE cn。`apple.com` 宽直连由模板特例移入 custom-direct，装配 proxy 先于 direct 保证 `developer.apple.com`（custom-proxy）先命中；AND 复合与 GEOSITE cn 无法列表化，留在装配行。

4. **rule-provider 文件格式坑（2026-09-03 发现并修复）**：4 个文件初版为纯文本逐行域名，mihomo rule-provider `format` **默认 yaml**（要求 `payload:` 包装）→ 纯文本按 YAML 解析失败 → **provider 加载成功但 ruleCount=0（空规则集）**，`RULE-SET,custom-direct` 空转静默跳过 → 症状：custom-direct 里的域名（如 update.code.visualstudio.com）落到 Loyalsoldier `RuleSet(proxy)` 走代理。判定手段：Verge 内核 API `GET /providers/rules` 看各 provider ruleCount（纯文本=0，google=112）；`mihomo -t` 通过不代表规则解析成功（**-t 对空 provider 静默放行**，本地 file-provider 兜底验证同样要查 ruleCount 或文件格式）。修复路线：先给 provider 加 `format: text`（文档：domain+text=每行一域名，实测 ruleCount 恢复 8/33/6/1），后按用户意见统一改为 **payload: YAML 格式**（`payload:` + `- '域名'`，与 Loyalsoldier 文件完全同构），模板 provider 不加 format（默认 yaml）。⚠️ 规则文件保持 payload 包装；若哪天改纯文本，必须同步加 `format: text`。

5. **payload 条目语义坑（同日二次修复）**：payload-YAML 下 **裸条目 = 仅精确匹配（不覆盖子域）；后缀匹配必须写 `+.` 前缀**（Loyalsoldier 的 gfw/proxy.txt 正是 `+.github.com`/`+.visualstudio.com` 式）。初版 4 文件全用裸条目 → 显式条目（update.code.visualstudio.com、marketplace.visualstudio.com、gateway.icloud.com 等）命中正常，但**靠宽条目后缀覆盖的子域全部漏匹配**（如 6-courier.push.apple.com ⊂ `apple.com` 裸条目 → 漏到 Loyalsoldier `RuleSet(proxy)` 走代理）。判定要点：Verge Connections 面板/`/connections` API 的 rule 字段只显示 `RuleSet`，**无法区分是哪个 provider**——必须看服务日志 match 行（`[TCP] ... match RuleSet(custom-direct) using DIRECT` 带完整规则名）；当"显式条目命中、靠后缀的子域不命中"即裸=精确的直接证据。修复：全部条目加 `+.` 前缀（统一后缀语义，等价原 DOMAIN-SUFFIX；原精确 DOMAIN 条目放宽为后缀，无实际危害）。

与 Loyalsoldier 去重结论（解析其 payload YAML 格式、`+.` 后缀条目按子域语义比对）：

- custom-proxy 原 7 域 youtube/googlevideo/netflix/google.com/github.com/b.ai/developer.apple.com 全部已被其 proxy/gfw/tld-not-cn 覆盖（同绑 Proxy）→ 删除 6 域，仅留 developer.apple.com（顺序职责：先于 custom-direct 内 apple.com 宽直连命中，而 Loyalsoldier apple 列表本身不含它）；
- 原模板 `DOMAIN-REGEX,^ohttp-relay.*\.fastly-edge\.com$` 存在漏匹配：Chrome Safe Browsing OHTTP 中继真实主机为 `google-ohttp-relay-safebrowsing.fastly-edge.com`（google- 前缀不在正则内）→ 移入 custom-direct 放宽为整域 `fastly-edge.com`（该域为中继专用，Mozilla/Google 各 relay 均在其下，直连实测可达）。

文档分工约定（本次确立）：AGENTS.md 只保留**现状事实与反直觉点**（不记逐次变更流水）；过程、理由、逐日改动与踩坑一律归档本文件。上一条 2026-09-03 大 bullet 已按此压成现状描述。

本地验证流程（仓库公开前）：`gen-client-config.sh` 重新生成后，把生成配置的 4 个 custom-* provider 临时改为 `type: file` + path 指向仓库 txt（复制到 scratch 目录），`mihomo -t -d scratch -f scratch.yaml` 通过即装配有效；仓库公开前 jsdelivr 404 属预期（provider 静默跳过）。

## 中转模式 shanghai→tokyo（2026-09-01）

### 实现与实测

同一镜像双角色：`RELAY_EXIT_HOST` 非空 → 入口中转（新增 `config.relay.template.json`，outbound 第一条为 VLESS+WS(+TLS) 指向出口、ws headers 带 `Authorization: Bearer` 过出口网关鉴权，routing 默认走它；outbound 自身到出口的连接不经过 routing，`geoip:private` 封禁不影响）；未设 → 直连出口（原模板）。出口节点（tokyo）零改动，同一 inbound 同时服务直连客户端与上海的中转连接。本地联调：`docker compose --profile relay up -d`（exit 8089 + relay 8090，明文 WS + TFO=false），xray 客户端容器双 socks 对照 + 停 relay 隔离验证。

实测数据（FC 生产，客户端在本机武汉电信）：

- 裸 WS 握手：shanghai/tokyo 均 101
- delay（mihomo，google generate_204）：tokyo 直连 60ms、sh-tokyo 中继 100-106ms、shanghai 入口单独测 101ms（=中继同路径）
- 端到端出口 IP：47.74.7.201 / 47.74.41.86 / 8.209.246.59（均 Japan Tokyo Alibaba，多实例出口 IP 池）
- 客户端配置：`RELAY_ENTRIES="sh>hk"`（.env deploy 节，2026-09-02 前为 RELAY_ROUTES="sh-tokyo=shanghai>tokyo"）生成 `Voynix-sh-hk`（连接参数=入口 shanghai），列于 Proxy/Scene select 组手动选择，不进 Auto url-test 池

### 链路带宽实测(2026-09-02 起,现行两条链路)

实测（客户端武汉电信,经中转链路）：sh-hk delay ~105ms、下载 ~330-430KB/s；sz-sg delay ~107ms、下载 ~210-430KB/s（HK 出口最快）。

### 踩坑

1. **Xray v26.2.6 移除 `tlsSettings.allowInsecure`**（强制迁移 pinnedPeerCertSha256）：relay 模板带它 → 容器启动即崩（FC 报 412 Precondition Failed，函数日志见 "Failed to build TLS config"）；本地 TLS=false 走 none 分支不触发，仅生产暴露。fcapp.run 证书为公共 CA 有效（curl 不带 -k 即 101），outbound 用 `serverName` 正常校验即可。
2. **FC 保留 `FC_` 前缀环境变量名**：容器 env 写 `FC_BEARER_TOKEN` → deploy 报 400 "The environment variable name 'FC_BEARER_TOKEN' is reserved"。s.yaml 注入改名 `RELAY_BEARER_TOKEN`，entrypoint 回退取值。
3. **CN 地域 FC 拉不到 docker.io**：deploy 报 400 "registry is not reachable"（确定性复现，海外地域正常）。方案：`RELAY_IMAGE=docker.1panel.live/<user>/voynix-xray@sha256:<digest>`（digest 与 Docker Hub 一致防篡改；FC 仅函数创建/更新时拉镜像，冷启动用内部缓存，镜像站只影响部署窗口）。镜像站普查：DaoCloud docker.m.daocloud.io 白名单外不代理；docker.1ms.run 判"可能违反相关地区法律"拒绝代理类仓库（hub.rat.dev 重定向到它）；xuanyuan 需付费。**长期正解是开通 ACR 个人版**（免费）：账号当前 USER_NOT_REGISTERED（cn-shanghai/hangzhou/beijing/shenzhen/hongkong/ap-southeast-1 均未注册，开通需控制台一次性点击）；个人版老 ROA API 可手签调用（`acs AKID:signature`，HMAC-SHA1 **裸 SK**（不加 "&"，与 OSS 不同），StringToSign=METHOD\nAccept\nContent-MD5\nContent-Type\nDate\nPath，Date 格式 `%a, %d %b %Y %H:%M:%S GMT`）；aliyun CLI 3.4 的 cr 产品是 ACR EE API（ListNamespace 需 InstanceId），个人版 API 不内置，插件 aliyun-cli-cr 亦无。
4. **/bin/sh 变量后紧跟多字节字符会吞字节**：`"$entry_key→tokyo"` 中 bash-posix 把 `→` 首字节 e2 并入变量名 → 查 `entry_key\xe2` 得空、箭头只剩 `86 92` → env 传给 python 变 surrogates（UnicodeEncodeError: surrogates not allowed）。zsh 无此问题（所以文件内容校验看不出）。**多字节字符前必须 `${var}` 花括号**。
5. **zsh `$VAR:latest` 会被解析为 `:l` 小写修饰符**：`"$IMAGE_NAME:latest"` → `voynix-xray`+`atest` = `voynix-xrayatest`，crane 误推到自动创建的仓库 `fangzy0823/voynix-xrayatest`（Docker Hub PAT 不能调 Hub API 删除，401 "cannot be used as a bearer"，需网页端手动删除）。**zsh 下 `$VAR` 后跟 `:` 必须用 `${VAR}`**。
6. shanghai FC URL 前缀是 `voynix-shanghai-vyqovfqvfs`（函数名一致）；tokyo 实际前缀是 `voynix-ay-tokyo-xtmohqxugy`（URL 派生名与函数名 voynix-xray-tokyo 不完全一致，勿按函数名猜域名，以 GetTrigger urlInternet 为准）。
7. Clash Verge Rev 的 mixed-port 由 Verge 设置覆盖（本机 7897，非模板 7890）；runtime external-controller 为空，API 走 unix socket：`curl --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/proxies/<name>/delay`。更新本机配置流程：覆盖 `profiles/LmNYOQCAwXHd.yaml`（先 .bak 时间戳备份）→ osascript 重启 Clash Verge → socket API 验证。
8. FC HTTP 触发器首次请求冷启动较慢（镜像已缓存仍需拉起实例），握手重试带间隔（实测 redeploy 后首次即 101，之前 412 是配置崩溃非冷启动）。

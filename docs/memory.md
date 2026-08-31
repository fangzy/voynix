# Voynix 运维笔记（内部）

> 本文件为项目内部运维记录，**不面向公开用户**。README 只保留对使用者有价值的内容，以下实测数据、部署细节、个人环境问题与历史变更统一归档于此。

## 实测经验（2026-08）

### 节点信息

12 个节点（6 海外 + 6 国内，均使用 Docker Hub 公共镜像 `docker.io/<user>/voynix-xray`）。已实测新加坡/香港，其余由 `FC_NODES` 部署后生效：

| 节点键 | 地域 | 函数名 | 客户端地址 |
|--------|------|--------|-----------|
| `sg` | ap-southeast-1 | `voynix-xray-sg` | `voynix-xray-sg-xxx.ap-southeast-1.fcapp.run:443` |
| `hk` | cn-hongkong | `voynix-xray-hk` | `voynix-xray-hk-xxx.cn-hongkong.fcapp.run:443` |
| `tokyo` | ap-northeast-1 | `voynix-xray-tokyo` | `voynix-xray-tokyo-xxx.ap-northeast-1.fcapp.run:443` |
| `frankfurt` | eu-central-1 | `voynix-xray-frankfurt` | `voynix-xray-frankfurt-xxx.eu-central-1.fcapp.run:443` |
| `va` | us-east-1 | `voynix-xray-va` | `voynix-xray-va-xxx.us-east-1.fcapp.run:443` |
| `sv` | us-west-1 | `voynix-xray-sv` | `voynix-xray-sv-xxx.us-west-1.fcapp.run:443` |
| `hangzhou` | cn-hangzhou | `voynix-xray-hangzhou` | `voynix-xray-hangzhou-xxx.cn-hangzhou.fcapp.run:443` |
| `shanghai` | cn-shanghai | `voynix-xray-shanghai` | `voynix-xray-shanghai-xxx.cn-shanghai.fcapp.run:443` |
| `beijing` | cn-beijing | `voynix-xray-beijing` | `voynix-xray-beijing-xxx.cn-beijing.fcapp.run:443` |
| `zhangjiakou` | cn-zhangjiakou | `voynix-xray-zhangjiakou` | `voynix-xray-zhangjiakou-xxx.cn-zhangjiakou.fcapp.run:443` |
| `huhehaote` | cn-huhehaote | `voynix-xray-huhehaote` | `voynix-xray-huhehaote-xxx.cn-huhehaote.fcapp.run:443` |
| `shenzhen` | cn-shenzhen | `voynix-xray-shenzhen` | `voynix-xray-shenzhen-xxx.cn-shenzhen.fcapp.run:443` |

镜像内不含 UUID 等机密，运行时经环境变量注入（仓库必须设为 Public）。旧新加坡函数 `proxy_service$xray-exit`（ACR 镜像）已于 2026-08 删除，由 `voynix-xray-sg` 接管。

### 地域支持范围

仅列出支持自定义容器镜像的 FC 3.0 地域（2026-08 依据阿里云官方 supported-regions 图标实测核对）。以下地域**不支持**自定义容器镜像，已排除：首尔（ap-northeast-2）/吉隆坡（ap-southeast-3）/雅加达（ap-southeast-5）/曼谷（ap-southeast-7）/伦敦（eu-west-1）/利雅得（me-central-1）/青岛（cn-qingdao）/乌兰察布（cn-wulanchabu）/成都（cn-chengdu）。

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

### 函数规格与弹性配置

`fc/s.yaml` 所有节点统一（锚点复用）：

| 配置项 | 值 | 字段 |
|--------|-----|------|
| CPU / 内存 | 0.1 vCPU / 128MB | `cpu` / `memorySize` |
| 单实例并发 | 30 | `instanceConcurrency` |
| 最小实例数 | 0（无请求不收费） | `scalingConfig.minInstances` |
| 预留并发 | 15 | `concurrencyConfig.reservedConcurrency` |

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

# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-27
**Updated:** 2026-09-01
**Branch:** main

## OVERVIEW

Xray-core Docker proxy service using VLESS + WebSocket + TLS,HTTP 触发器 Bearer 鉴权. Single container deployment; local Docker for dev, Alibaba Cloud FC 3.0 (custom-container) for production across 12 regions (6 overseas + 6 CN). Images built via GitHub Actions and pushed to Docker Hub (public, shared by all nodes). 同一镜像支持直连出口(默认)与中转入口(`RELAY_*` env 激活,如 shanghai→tokyo)。

## STRUCTURE

```
.
├── docker-image/          # Docker deployment
│   ├── Dockerfile
│   ├── config.template.json    # WS 直连出口模板(默认)
│   ├── config.relay.template.json # WS 中转入口模板(outbound=VLESS→出口节点)
│   ├── entrypoint.sh
│   ├── healthcheck.sh
├── client-config/         # Clash client templates
│   └── clash-verge.yaml.template   # Dual-node (HK+SG) + url-test auto-switch
├── fc/
│   ├── s.yaml             # Serverless Devs multi-region FC config
│   └── s.ws.yaml          # SG WebSocket 实验配置(独立函数 voynix-xray-ws-sg,不碰生产)
├── scripts/
│   ├── gen-client-config.sh   # Generate client config (auto-fetch FC node domains)
│   └── deploy-fc.sh           # Local FC deploy script (build/push/deploy)
├── docker-compose.yml     # Local dev compose(根目录 .env 插值;--profile relay 附带中转链联调)
├── docs/
│   └── memory.md          # 内部运维笔记(实测经验/踩坑记录,非公开;README 只留用户内容)
├── .env.example           # 统一环境变量模板(common/deploy/client 三节)
├── .github/workflows/
│   └── deploy.yml         # Build+push images, then Serverless Devs deploy FC
└── .gitignore
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Modify proxy config | `docker-image/config.template.json` | 直连出口模板(envsubst 需 export 变量,见 Config Templating) |
| Modify relay config | `docker-image/config.relay.template.json` | 中转入口模板(outbound=VLESS→`RELAY_EXIT_HOST`;本地联调 `RELAY_EXIT_TLS=false`) |
| WS experiment deploy | `fc/s.ws.yaml` | `cd fc && s deploy -t s.ws.yaml -y`(SG,函数 voynix-xray-ws-sg,镜像 :ws tag) |
| Update Docker build | `docker-image/Dockerfile` | Multi-stage Alpine 3.20 build |
| Update CI/CD | `.github/workflows/deploy.yml` | GitHub Actions (build+push+FC deploy) |
| Client configuration | `client-config/clash-verge.yaml.template` | mihomo/Clash template (dual-node, url-test;rules 用 Loyalsoldier 13 规则集,MATCH,DIRECT) |
| FC deployment config | `fc/s.yaml` | Serverless Devs, regions + images per node;shanghai=中转入口(RELAY_* env + RELAY_IMAGE 镜像) |
| Generate client config | `scripts/gen-client-config.sh` | Auto-fetch FC node domains (aliyun fc GetTrigger); filter via args or `FC_NODES`; `RELAY_ROUTES` 生成中继节点 |
| Local FC deploy | `scripts/deploy-fc.sh` | Reads 根目录 .env;部署 shanghai 时校验 RELAY_EXIT_HOST/RELAY_IMAGE |
| Runtime entrypoint | `docker-image/entrypoint.sh` | envsubst + Xray start;`RELAY_EXIT_HOST` 非空→relay 模板,否则直连模板 |
| Health check | `docker-image/healthcheck.sh` | Docker HEALTHCHECK script (pidof xray) |
| Compose config | `docker-compose.yml` | 根目录,Local dev(`--profile relay` 附带中转链联调容器) |

## ENTRY POINTS

- **Container**: `docker-image/entrypoint.sh` runs envsubst on config template, then starts Xray (config validation skipped for cold-start)
- **Xray binary**: `/usr/local/bin/xray` at `/etc/xray/config.json`

## CONVENTIONS

### Environment Variables

单文件 `.env`(gitignored,模板 `.env.example`),按注释分三节:common(部署+客户端共享)/ deploy(凭据+参数)/ client(客户端生成参数)。deploy-fc.sh、gen-client-config.sh、docker-compose.yml 均读取它。

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `UUID` | Yes | (none) | VLESS client authentication UUID (shared by all nodes) |
| `WS_PATH` | No | `ws` | WS path(客户端 ws-opts.path 需一致,如 /ws) |
| `FC_BEARER_TOKEN` | Yes | (none) | HTTP 触发器 Bearer 鉴权 token(32-128 字符 Base64 字符集;存 .env common 节,gitignored;客户端 ws-opts.headers 带 `Authorization: Bearer`) |
| `TFO` | No | `true` | inbound sockopt tcpFastOpen(生产 true;本地 Docker qemu 下需 `false`,见 docs/memory.md) |

Deploy 节变量(镜像到 GitHub Secret 供 CI):
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `ALIBABA_CLOUD_ACCOUNT_ID`, `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET`, `FC_NODES`, `IMAGE_NAME`, `RELAY_EXIT_HOST`(中转出口域名,如 tokyo), `RELAY_EXIT_PORT`(443), `RELAY_EXIT_TLS`(true), `RELAY_IMAGE`(CN 地域加速镜像地址+digest 固定,FC 无法直连 docker.io)。Client 节:`SCENE_NODES`(场景组)、`RELAY_ROUTES`(中继路由,如 `sh-tokyo=shanghai>tokyo`)。

### Relay Mode(中转模式)

- 同一镜像两种角色:`RELAY_EXIT_HOST` 非空 → 入口中转(outbound=VLESS+WS+TLS 指向出口,带 `Authorization: Bearer` 头过出口 FC 网关鉴权);未设 → 直连出口(freedom)
- 出口节点(tokyo)**零改动**:同一 inbound 同时服务直连客户端与中转连接
- s.yaml 中入口节点(shanghai)整块覆盖 `environmentVariables`(YAML 锚点浅合并)+ `customContainerConfig.image`(走 `RELAY_IMAGE` 加速镜像)
- ⚠️ FC 平台保留 `FC_` 前缀环境变量名——容器内 token 变量须叫 `RELAY_BEARER_TOKEN`(entrypoint 回退取值)

### Xray-core Version

Pinned to **v26.2.6**. Update the `XRAY_VERSION` arg in `Dockerfile` to change.

### Base Image

Alpine 3.20 for both build and runtime stages. Final image is approximately 27-35MB.

### Port

Xray listens on **port 8089** (plain WS;TLS terminated by FC gateway). No reverse proxy in front of it. **客户端必须走 443 端口(WSS)**。

### Config Templating

- `config.template.json` uses `${UUID}` / `${WS_PATH}` / `${TFO}`;`config.relay.template.json` 另用 `${RELAY_EXIT_HOST}` / `${RELAY_EXIT_PORT}` / `${RELAY_EXIT_SECURITY}` / `${FC_BEARER_TOKEN}`
- `entrypoint.sh` runs `envsubst` at container start to produce `/etc/xray/config.json`(`RELAY_EXIT_HOST` 非空选 relay 模板;`RELAY_EXIT_TLS` true/false → security tls/none)
- ⚠️ **envsubst 只替换环境变量,不替换 shell 变量**——entrypoint 必须 `export UUID/WS_PATH`,否则未显式传入的变量会被替换成空串(曾因 WS_PATH 未 export 导致 path 变成 `/`、WS 握手 404,2026-08-29)
- Never hardcode UUIDs in the template
- ⚠️ Xray v26.2.6 已移除 tlsSettings `allowInsecure`(迁移 pinnedPeerCertSha256)——outbound TLS 用 `serverName` 正常校验即可(fcapp.run 公共证书有效,实测 101)

### Certificates

- No container-side certs: FC gateway terminates TLS (inbound is plain WS, no `security:tls`)
- Client must set `skip-cert-verify: true` (trusts FC gateway's public cert)

### Security

- Non-root `xray` user (UID 1000) runs the Xray process
- Sniffing disabled on inbound (VLESS carries domain in header; routing is IP-only `geoip:private`)
- `geoip:private` blocked in routing

## COMMANDS

```bash
# Build and run locally
cp .env.example .env
# Edit .env to fill values (common/deploy/client 三节)
docker compose up -d

# Build image manually
docker build -t voynix-xray:latest docker-image/

# Run with env var
docker run -d -p 8089:8089 -e UUID=$(uuidgen) voynix-xray:latest

# Generate client config (auto-fetch domains of deployed FC nodes; VLESS+WS 443 + Bearer 鉴权)
./scripts/gen-client-config.sh            # all deployed nodes (skips undeployed)
./scripts/gen-client-config.sh sg hk      # only sg + hk (args take priority)
FC_NODES=sg,hk,tokyo ./scripts/gen-client-config.sh   # same filter via env (blank → error)
# 场景组(可选):生成 Company(SG+Tokyo)/Home(HK+Tokyo) 各自 Auto+LB 子组 + 顶层 Voynix-Scene 切换
# 8 组结构:Auto(全量)+ Company-Auto/LB + Home-Auto/LB + Scene(列四组+全量Auto)+ Proxy + Streaming(有场景时去掉全量 LB)
SCENE_NODES="company=sg,tokyo;home=hk,tokyo" ./scripts/gen-client-config.sh
# 中继节点(可选,RELAY_ROUTES 在 .env client 节):生成 Voynix-sh-tokyo(连接参数=入口 shanghai,手动选择,不进 Auto 池)
RELAY_ROUTES="sh-tokyo=shanghai>tokyo" ./scripts/gen-client-config.sh sg hk tokyo shanghai

# Verify with mihomo(需 geodata:macOS 本机用 -d 指向 Clash Verge 数据目录,否则尝试联网下载 geodata 会卡住)
mihomo -t -d "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" -f client-config/clash-verge.yaml

# Local FC deploy (build+push+deploy; or deploy-only / single region)
# 需先 cp .env.example .env 并填写 deploy 节凭据;shanghai 需 RELAY_EXIT_HOST + RELAY_IMAGE(脚本校验)
./scripts/deploy-fc.sh               # all nodes
./scripts/deploy-fc.sh build hk      # HK only
./scripts/deploy-fc.sh deploy tokyo    # deploy-only Tokyo
./scripts/deploy-fc.sh deploy shanghai # deploy-only Shanghai(中转入口,需 RELAY_*)

# Local relay chain debug(compose relay profile:exit 8089 + relay 8090,均明文 WS + TFO=false)
docker compose --profile relay up -d --build

# Push to Docker Hub from CN network (Docker Desktop proxy blocks docker push):
docker save voynix-xray:latest -o /tmp/voynix.tar
crane push /tmp/voynix.tar docker.io/<user>/voynix-xray:latest
# 推送后更新 .env 的 RELAY_IMAGE digest(crane digest docker.io/<user>/voynix-xray:latest)再部署 shanghai

# Check container health
docker compose ps
```

**GitHub Actions:**
- Workflow: `.github/workflows/deploy.yml`
- Trigger: Push to `docker-image/**`, `fc/**`, `.github/workflows/deploy.yml` paths
- Job 1 `build-and-push`: Builds Xray image, pushes to Docker Hub (public, shared by all nodes)
- Job 2 `deploy-fc`: Serverless Devs `s deploy -y` from `fc/` (loops over nodes in FC_NODES)
- Docker Hub secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
- FC deploy secrets: `ALIBABA_CLOUD_ACCOUNT_ID`, `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET`, `UUID`, `FC_BEARER_TOKEN`

## ARCHITECTURE

```
Client (mihomo/Clash, Voynix-Auto url-test auto-switch)
    |
    | VLESS + WS + TLS (fcapp.run:443 WSS, Bearer 鉴权, skip-cert-verify)
    ├──────────────────────┬──────────────────────┬───────────────────┐
    ↓                      ↓                      ↓                   ↓
HK FC (cn-hongkong)    SG FC (ap-southeast-1)  Tokyo FC          Shanghai FC (中转入口)
voynix-xray-hk         voynix-xray-sg          voynix-xray-tokyo  voynix-xray-shanghai
Docker Hub public img   Docker Hub public img   RELAY_IMAGE 镜像
    │                      │                      │                │ VLESS+WS+TLS(Bearer)
    | Direct               | Direct               | Direct  ←──────┘(经 FC 网关 443)
    ↓                      ↓                      ↓
Internet               Internet               Internet
                          ▲
        中转链路(可选): Client → Shanghai FC → Tokyo FC → Internet(出口 IP=东京)
```

默认单跳直连;中转入口节点(shanghai)默认全部流量链到出口节点(tokyo)。Tokyo 同一 inbound 同时服务直连客户端与中转连接(零改动)。

## NODES

All nodes use Docker Hub public image `docker.io/<user>/voynix-xray`; deployment scope is controlled by the `FC_NODES` repo variable (comma-separated, e.g. `sg,hk,tokyo`). Empty/空白/未设置 → CI 显式报错; unknown keys also fail fast. `fc/s.yaml` defines 12 nodes (6 overseas + 6 CN, YAML anchor `&node-base` for shared props). Only FC 3.0 regions supporting custom-container images are listed (verified 2026-08 against official supported-regions icons; Seoul/KL/Jakarta/Bangkok/London/Qingdao/Wulanchabu/Chengdu excluded). **已部署(2026-09-01):sg / hk / tokyo(直连出口)/ shanghai(中转入口→tokyo)**;CI repo 变量 FC_NODES 仍为 sg,hk,tokyo(本地 .env 已加 shanghai)。

| Key | Region | Function | Client host (fcapp.run:443 WSS) |
|-----|--------|----------|------------------------------|
| `sg` | ap-southeast-1 | `voynix-xray-sg` | `voynix-xray-sg-*.ap-southeast-1.fcapp.run` |
| `hk` | cn-hongkong | `voynix-xray-hk` | `voynix-xray-hk-*.cn-hongkong.fcapp.run` |
| `tokyo` | ap-northeast-1 | `voynix-xray-tokyo` | `voynix-ay-tokyo-*.ap-northeast-1.fcapp.run`(实际前缀 voynix-ay) |
| `frankfurt` | eu-central-1 | `voynix-xray-frankfurt` | `voynix-xray-frankfurt-*.eu-central-1.fcapp.run` |
| `va` | us-east-1 | `voynix-xray-va` | `voynix-xray-va-*.us-east-1.fcapp.run` |
| `sv` | us-west-1 | `voynix-xray-sv` | `voynix-xray-sv-*.us-west-1.fcapp.run` |
| `hangzhou` | cn-hangzhou | `voynix-xray-hangzhou` | `voynix-xray-hangzhou-*.cn-hangzhou.fcapp.run` |
| `shanghai` | cn-shanghai | `voynix-xray-shanghai` | `voynix-shanghai-*.cn-shanghai.fcapp.run`(**中转入口**,RELAY_* env) |
| `beijing` | cn-beijing | `voynix-xray-beijing` | `voynix-xray-beijing-*.cn-beijing.fcapp.run` |
| `zhangjiakou` | cn-zhangjiakou | `voynix-xray-zhangjiakou` | `voynix-xray-zhangjiakou-*.cn-zhangjiakou.fcapp.run` |
| `huhehaote` | cn-huhehaote | `voynix-xray-huhehaote` | `voynix-xray-huhehaote-*.cn-huhehaote.fcapp.run` |
| `shenzhen` | cn-shenzhen | `voynix-xray-shenzhen` | `voynix-xray-shenzhen-*.cn-shenzhen.fcapp.run` |

Note: CN nodes (cn-*) defined 2026-08 per request; deploying proxy on CN regions carries compliance risk — user's decision. Old SG function (`proxy_service$xray-exit`, ACR image) was deleted 2026-08 and replaced by `voynix-xray-sg` (Docker Hub image, same spec as HK).

## NOTES

- FC gateway terminates TLS; no container-side certs (inbound plain WS,生产默认)
- Client must set `skip-cert-verify: true`
- FC client port is **443 (WSS)**
- FC function spec (2026-08): 0.1 vCPU / 128MB / `instanceConcurrency` 30 / `minInstances` 0 / `reservedConcurrency` 15.
- Never verify FC nodes with plain `curl` without token (Bearer 鉴权下无 token → 403);裸 WS 握手带 token 验证:对 token + Upgrade 头 → 101(路径不匹配/旧实例 → 404,曾踩坑)
- Both FC nodes use the same Docker Hub public image `docker.io/<user>/voynix-xray` (no secrets in image; runtime vars injected via env). ACR no longer used (personal edition: one instance per account was the original blocker, now moot). Deployment scope: GitHub Actions `deploy-fc` job loops over the `FC_NODES` repo variable (comma-separated node keys, e.g. `sg,hk,tokyo`, split via bash `tr`); unset/empty/whitespace-only FC_NODES or unknown keys make the workflow fail fast with a clear message (GitHub Actions expressions have no `split` function, so deployment is a bash for-loop, not a matrix). Only custom-container-capable FC regions are defined (Seoul etc. rejected by FC API 2026-08: "Custom container image is not supported in this region")
- No nginx. FC gateway terminates TLS; Xray inbound is plain WS (生产默认,无 TLS)
- No test suite. Infrastructure project
- Runtime envsubst means config changes only need a container restart, not a rebuild
- Client config `Voynix-Auto` url-test measures `https://github.com/manifest.json` every 300s (tolerance 50ms)
- Xray v26.2.6 启动告警:WebSocket transport 已标记弃用,官方建议迁移 XHTTP(stream-up H2/H3);现网仍可用
- SG WS 节点实验结论(2026-08-29):Bearer 鉴权、Cookie/HeaderField 会话亲和均验证过,细节见 docs/memory.md
- 客户端模板 rules 采用 Loyalsoldier/clash-rules 全量 13 个 rule-providers(2026-08-31 起,jsdelivr CDN 每日 6:30 自动构建;reject REJECT、apple/icloud/direct/private/lancidr/cncidr DIRECT、google/proxy/gfw/tld-not-cn/telegramcidr Proxy,结尾 MATCH,DIRECT 黑名单兜底);7 条国外遥测 REJECT 与 MSN/Bing/系统打点/Apple 证书 CA 直连等保留为顶部覆盖层(国内遥测走 `GEOSITE,cn,DIRECT` 不加规则)——细节见 `docs/memory.md`
- 2026-08 试验/踩坑细节(WS 实验、全量 WS 切换、Bearer/会话亲和实验、tcpFastOpen、遥测 REJECT 依据)归档于 `docs/memory.md`,本文件仅保留现状事实与约定
- 中转模式(2026-09-01 上线,shanghai→tokyo):实测 sh-tokyo delay ~100-106ms(tokyo 直连 60ms),出口 IP 日本;客户端生成 `Voynix-sh-tokyo` 中继节点(手动选择,不进 Auto 池;`Voynix-Shanghai` 与其同路径)
- CN 地域 FC 拉不到 docker.io("registry is not reachable")→ shanghai 用 `RELAY_IMAGE`(docker.1panel.live + `@sha256:` digest 固定);FC 仅函数创建/更新时拉镜像,冷启动用内部缓存;镜像更新流程 = push → 更新 .env digest → redeploy shanghai
- 客户端 Verge 混合端口为 7897(Verge 自身设置覆盖模板 mixed-port),runtime 配置 external-controller 为空 + unix socket `/tmp/verge/verge-mihomo.sock`(API 测试用 `curl --unix-socket`)
- 更多踩坑(FC 保留 FC_ 前缀 env、Xray 移除 allowInsecure、/bin/sh 多字节变量名、ACR 个人版未开通)见 `docs/memory.md` 2026-09-01 节

## 维护规则

本文件是项目事实基准,供 AI 代理与协作者使用。当以下任一发生变化时,**必须在同一次改动中同步更新本文件**:
- 项目结构(顶层目录/关键文件增删移)
- 构建、测试、校验命令(如 `mihomo -t`、`gen-client-config.sh`、`deploy-fc.sh` 用法)
- 架构边界(传输协议、端口、鉴权方式、节点清单)
- 开发约定(环境变量、配置模板、CI/CD 行为)
- 本文件记录的其他事实(Xray 版本、函数规格、踩坑结论)

同步更新须与改动同批完成:修正过期描述、补齐新事实、保持 COMMANDS 与 WHERE TO LOOK 与实际一致,禁止只改代码不同步本文件。

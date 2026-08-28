# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-27
**Updated:** 2026-08-27
**Branch:** dev

## OVERVIEW

Xray-core Docker proxy service using VLESS + WebSocket + TLS (生产默认,2026-08 全量切换;gRPC 保留为 TRANSPORT=grpc 回退),HTTP 触发器 Bearer 鉴权. Single container deployment; local Docker for dev, Alibaba Cloud FC 3.0 (custom-container) for production across 20 regions (11 overseas + 9 CN). Images built via GitHub Actions and pushed to Docker Hub (public, shared by all nodes).

## STRUCTURE

```
.
├── docker-image/          # Docker deployment
│   ├── Dockerfile
│   ├── config.template.json    # gRPC 回退模板(TRANSPORT=grpc 时使用)
│   ├── config.ws.template.json # WS 生产模板(默认,TRANSPORT=ws)
│   ├── entrypoint.sh
│   ├── healthcheck.sh
│   ├── docker-compose.yml
│   └── .env.example       # Runtime vars only (UUID / FC_BEARER_TOKEN / TRANSPORT)
├── client-config/         # Clash client templates
│   └── clash-verge.yaml.template   # Dual-node (HK+SG) + url-test auto-switch
├── fc/
│   ├── s.yaml             # Serverless Devs multi-region FC config
│   └── s.ws.yaml          # SG WebSocket 实验配置(独立函数 voynix-xray-ws-sg,不碰生产)
├── scripts/
│   ├── gen-client-config.sh   # Generate client config (auto-fetch FC node domains)
│   └── deploy-fc.sh           # Local FC deploy script (build/push/deploy)
├── .env.deploy.example    # Deploy credentials template (Docker Hub/Aliyun)
├── .github/workflows/
│   └── deploy.yml         # Build+push images, then Serverless Devs deploy FC
└── .gitignore
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Modify proxy config | `docker-image/config.ws.template.json` | **生产默认 WS 模板**(envsubst 需 export 变量,见 Config Templating) |
| gRPC fallback | `docker-image/config.template.json` | `TRANSPORT=grpc` 时使用(旧配置保留) |
| WS experiment deploy | `fc/s.ws.yaml` | `cd fc && s deploy -t s.ws.yaml -y`(SG,函数 voynix-xray-ws-sg,镜像 :ws tag) |
| Update Docker build | `docker-image/Dockerfile` | Multi-stage Alpine 3.20 build |
| Update CI/CD | `.github/workflows/deploy.yml` | GitHub Actions (build+push+FC deploy) |
| Client configuration | `client-config/clash-verge.yaml.template` | mihomo/Clash template (dual-node, url-test) |
| FC deployment config | `fc/s.yaml` | Serverless Devs, regions + images per node |
| Generate client config | `scripts/gen-client-config.sh` | Auto-fetch FC node domains (aliyun fc GetTrigger); filter via args or `FC_NODES` env (comma-separated) |
| Local FC deploy | `scripts/deploy-fc.sh` | Reads docker-image/.env + .env.deploy |
| Runtime entrypoint | `docker-image/entrypoint.sh` | envsubst + Xray start (config validation skipped — deterministic template) |
| Health check | `docker-image/healthcheck.sh` | Docker HEALTHCHECK script (pidof xray) |
| Compose config | `docker-image/docker-compose.yml` | Local dev and deployment |

## ENTRY POINTS

- **Container**: `docker-image/entrypoint.sh` runs envsubst on config template, then starts Xray (config validation skipped for cold-start)
- **Xray binary**: `/usr/local/bin/xray` at `/etc/xray/config.json`

## CONVENTIONS

### Environment Variables

Runtime vars live in `docker-image/.env`; deploy credentials in repo-root `.env.deploy` (gitignored). Never mix them.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `UUID` | Yes | (none) | VLESS client authentication UUID (shared by all nodes) |
| `GRPC_SERVICE_NAME` | No | `ProxyService` | gRPC service name(gRPC 回退传输用) |
| `TRANSPORT` | No | `ws` | 传输协议:ws(默认,生产)或 grpc(回退);entrypoint 据此选择 config 模板 |
| `WS_PATH` | No | `ws` | WS path(客户端 ws-opts.path 需一致,如 /ws) |
| `FC_BEARER_TOKEN` | Yes | (none) | HTTP 触发器 Bearer 鉴权 token(32-128 字符 Base64 字符集;存 docker-image/.env,gitignored;客户端 ws-opts.headers 带 `Authorization: Bearer`) |

Deploy credentials (`.env.deploy`, mirror each to a GitHub Secret for CI):
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `ALIBABA_CLOUD_ACCOUNT_ID`, `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET`.

### Xray-core Version

Pinned to **v26.2.6**. Update the `XRAY_VERSION` arg in `Dockerfile` to change.

### Base Image

Alpine 3.20 for both build and runtime stages. Final image is approximately 27-35MB.

### Port

Xray listens on **port 8089** (plain WS,生产默认;TLS terminated by FC gateway). No reverse proxy in front of it. **客户端 WS 必须走 443 端口(WSS)** — 8089 是 FC gRPC h2 专用入口,WS 升级走 8089 会返回 500;gRPC 客户端(已弃用回退)才用 8089。

### Config Templating

- `config.ws.template.json`(生产)uses `${UUID}` / `${WS_PATH}`;`config.template.json`(gRPC 回退)uses `${UUID}` / `${GRPC_SERVICE_NAME}`
- `entrypoint.sh` runs `envsubst` at container start to produce `/etc/xray/config.json`
- ⚠️ **envsubst 只替换环境变量,不替换 shell 变量**——entrypoint 必须 `export UUID/GRPC_SERVICE_NAME/WS_PATH`,否则未显式传入的变量会被替换成空串(曾因 WS_PATH 未 export 导致 path 变成 `/`、WS 握手 404,2026-08-29)
- Never hardcode UUIDs in the template

### Certificates

- No container-side certs: FC gateway terminates TLS (inbound is plain gRPC, no `security:tls`)
- Client must set `skip-cert-verify: true` (trusts FC gateway's public cert)

### Security

- Non-root `xray` user (UID 1000) runs the Xray process
- Sniffing disabled on inbound (VLESS carries domain in header; routing is IP-only `geoip:private`)
- `geoip:private` blocked in routing

## COMMANDS

```bash
# Build and run locally
cp docker-image/.env.example docker-image/.env
# Edit .env to set UUID
docker compose -f docker-image/docker-compose.yml up -d

# Build image manually
docker build -t voynix-xray:latest docker-image/

# Run with env var
docker run -d -p 8089:8089 -e UUID=$(uuidgen) voynix-xray:latest

# Generate client config (auto-fetch domains of deployed FC nodes; VLESS+WS 443 + Bearer 鉴权)
./scripts/gen-client-config.sh            # all deployed nodes (skips undeployed)
./scripts/gen-client-config.sh sg hk      # only sg + hk (args take priority)
FC_NODES=sg,hk,tokyo ./scripts/gen-client-config.sh   # same filter via env (blank → error)

# Verify with mihomo
mihomo -t -f client-config/clash-verge.yaml

# Local FC deploy (build+push+deploy; or deploy-only / single region)
cp .env.deploy.example .env.deploy   # fill in credentials
./scripts/deploy-fc.sh               # all nodes
./scripts/deploy-fc.sh build hk      # HK only
./scripts/deploy-fc.sh deploy sg     # deploy-only SG

# Push to Docker Hub from CN network (Docker Desktop proxy blocks docker push):
docker save voynix-xray:latest -o /tmp/voynix.tar
crane push /tmp/voynix.tar docker.io/<user>/voynix-xray:latest

# Check container health
docker compose -f docker-image/docker-compose.yml ps
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
    ├──────────────────────┬──────────────────────┐
    ↓                      ↓                      ↓
HK FC (cn-hongkong)    SG FC (ap-southeast-1)
voynix-xray-hk         voynix-xray-sg
Docker Hub public img   Docker Hub public img
    │                      │
    | Direct               | Direct
    ↓                      ↓
Internet               Internet
```

Single hop per node. No chain forwarding, no intermediate nodes.

## NODES

All nodes use Docker Hub public image `docker.io/<user>/voynix-xray`; deployment scope is controlled by the `FC_NODES` repo variable (comma-separated, e.g. `sg,hk,tokyo`). Empty/空白/未设置 → CI 显式报错; unknown keys also fail fast. `fc/s.yaml` defines 12 nodes (6 overseas + 6 CN, YAML anchor `&node-base` for shared props). Only FC 3.0 regions supporting custom-container images are listed (verified 2026-08 against official supported-regions icons; Seoul/KL/Jakarta/Bangkok/London/Qingdao/Wulanchabu/Chengdu excluded).

| Key | Region | Function | Client host (fcapp.run:443 WSS) |
|-----|--------|----------|------------------------------|
| `sg` | ap-southeast-1 | `voynix-xray-sg` | `voynix-xray-sg-*.ap-southeast-1.fcapp.run` |
| `hk` | cn-hongkong | `voynix-xray-hk` | `voynix-xray-hk-*.cn-hongkong.fcapp.run` |
| `tokyo` | ap-northeast-1 | `voynix-xray-tokyo` | `voynix-xray-tokyo-*.ap-northeast-1.fcapp.run` |
| `frankfurt` | eu-central-1 | `voynix-xray-frankfurt` | `voynix-xray-frankfurt-*.eu-central-1.fcapp.run` |
| `va` | us-east-1 | `voynix-xray-va` | `voynix-xray-va-*.us-east-1.fcapp.run` |
| `sv` | us-west-1 | `voynix-xray-sv` | `voynix-xray-sv-*.us-west-1.fcapp.run` |
| `hangzhou` | cn-hangzhou | `voynix-xray-hangzhou` | `voynix-xray-hangzhou-*.cn-hangzhou.fcapp.run` |
| `shanghai` | cn-shanghai | `voynix-xray-shanghai` | `voynix-xray-shanghai-*.cn-shanghai.fcapp.run` |
| `beijing` | cn-beijing | `voynix-xray-beijing` | `voynix-xray-beijing-*.cn-beijing.fcapp.run` |
| `zhangjiakou` | cn-zhangjiakou | `voynix-xray-zhangjiakou` | `voynix-xray-zhangjiakou-*.cn-zhangjiakou.fcapp.run` |
| `huhehaote` | cn-huhehaote | `voynix-xray-huhehaote` | `voynix-xray-huhehaote-*.cn-huhehaote.fcapp.run` |
| `shenzhen` | cn-shenzhen | `voynix-xray-shenzhen` | `voynix-xray-shenzhen-*.cn-shenzhen.fcapp.run` |

Note: CN nodes (cn-*) defined 2026-08 per request; deploying proxy on CN regions carries compliance risk — user's decision. Old SG function (`proxy_service$xray-exit`, ACR image) was deleted 2026-08 and replaced by `voynix-xray-sg` (Docker Hub image, same spec as HK).

## NOTES

- FC gateway terminates TLS; no container-side certs (inbound plain WS,生产默认)
- Client must set `skip-cert-verify: true`
- FC client port is **443 (WSS,生产默认)**;8089 是 gRPC 回退传输专用入口(ALPN h2,WS 升级走它会 500)
- FC function spec (2026-08): 0.1 vCPU / 128MB / `instanceConcurrency` 30 / `minInstances` 0 / `reservedConcurrency` 15. Console "弹性实例配额" column maps to `reservedConcurrency` (CONCURRENCY, not instance count); real instance-count cap (`targetInstances`) is unset → elastic. 100-concurrency load test: 3 active instances, no 429 (gRPC long-connection reuse keeps FC-side concurrent requests under the cap). Session affinity (any type) was tried 2026-08 and reverted: FC forces `instanceConcurrency` to 200 and the 4 affinity types (Cookie/HeaderField/MCP SSE/MCP Streamable) are all useless for VLESS+gRPC (mihomo/Xray gRPC transport doesn't process cookies or custom headers; gRPC long connections already have connection-level affinity)
- Never verify FC nodes with plain `curl` without token (Bearer 鉴权下无 token → 403);裸 WS 握手带 token 验证:对 token + Upgrade 头 → 101(路径不匹配/旧实例 → 404,曾踩坑)
- Both FC nodes use the same Docker Hub public image `docker.io/<user>/voynix-xray` (no secrets in image; runtime vars injected via env). ACR no longer used (personal edition: one instance per account was the original blocker, now moot). Deployment scope: GitHub Actions `deploy-fc` job loops over the `FC_NODES` repo variable (comma-separated node keys, e.g. `sg,hk,tokyo`, split via bash `tr`); unset/empty/whitespace-only FC_NODES or unknown keys make the workflow fail fast with a clear message (GitHub Actions expressions have no `split` function, so deployment is a bash for-loop, not a matrix). Only custom-container-capable FC regions are defined (Seoul etc. rejected by FC API 2026-08: "Custom container image is not supported in this region")
- Local `docker push` to Docker Hub fails with EOF/broken pipe: Docker Desktop auto-detects system proxy (WPAD hijacked by Clash fake-ip) and configures dead proxy :3128; workaround is `crane push` (direct, reuses docker login creds)
- No nginx. FC gateway terminates TLS; Xray inbound is plain WS (生产默认,无 TLS)
- No test suite. Infrastructure project
- Runtime envsubst means config changes only need a container restart, not a rebuild
- gRPC transport (multiMode is client-side only, not set on server)
- gRPC keepalive: `grpcSettings` sets `idle_timeout: 60` / `health_check_timeout: 20` → Xray server sends HTTP/2 PING on idle connections (every 60s) so FC gateway never silently reclaims long-lived gRPC connections; this is what prevents "unexpected EOF" from gh CLI reusing a dead connection. mihomo auto-ACKs PING per HTTP/2 spec (no client config needed). `initial_windows_size` is client-side only (Xray client), useless for mihomo — don't set it
- Client config `Voynix-Auto` url-test measures `https://github.com/manifest.json` every 300s (tolerance 50ms)
- WebSocket 实验(2026-08-29,SG):同镜像支持 `TRANSPORT=ws`(entrypoint 选 config.ws.template.json),部署用 fc/s.ws.yaml + `:ws` 镜像 tag,函数 `voynix-xray-ws-sg` 与生产并存。延迟对比(SG,gRPC 8089 vs WS 443,mihomo delay API 16 轮交错):中位数几乎相同(~233ms),WS 更稳定(0 失败 vs gRPC 2 次失败,后者为 FC 实例回收后的死连接,即 keepalive 也救不回已回收实例)。带宽对比(绕开本机 Clash TUN 后干净链路复测):单流 ~12-16KB/s(gRPC 与 WS 完全相同),多目标(CF/OVH)一致,4 并行聚合也仅 ~40KB/s——瓶颈是本机到境外的跨境单流限速,与传输协议无关;gRPC/WS 帧开销差异(亚 1%)在噪声内不可分辨。WS 无应用层保活(Xray WS 无 ping 配置),依赖 TCP keepalive + 客户端 keep-alive-interval
- Xray v26.2.6 启动告警:gRPC 与 WebSocket transport 均已标记弃用,官方建议迁移 XHTTP(stream-up H2/H3);现网两者仍可用
- **全量 WS 切换(2026-08-29)**:按 SG 实验结论将生产全部改为 VLESS+WS+Bearer 鉴权——entrypoint 默认 TRANSPORT=ws、s.yaml 锚点加 `TRANSPORT: ws` / `WS_PATH: ${env(WS_PATH)}` / 触发器 `authType: bearer`(BearerFormat: opaque + opaqueTokenConfig)、deploy-fc.sh 与 gen-client-config.sh 支持 FC_BEARER_TOKEN/WS_PATH、客户端生成 WS(443)+Bearer。部署验证:sg/hk/tokyo 裸握手 101、delay SG 225ms/HK 78ms/Tokyo 161ms、代理实测全部 HTTP 200。踩坑:①entrypoint 未 export 时 envsubst 把 WS_PATH 替换成空串(path=`/` → 404);②部署后 FC 实例未更新时新请求仍路由旧 gRPC 实例(404),需重新部署+等实例回收;③本机经 Clash TUN 时 DNS 被 fake-ip 污染,mihomo CONNECT 隧道目标变假 IP(经 SG 跳板推镜像时需关 TUN 或用干净配置)
- SG WS 节点 Bearer 鉴权 + Cookie 会话亲和实验(2026-08-29,fc/s.ws.yaml):
  - **Bearer 鉴权**(fc3 触发器 `authType: bearer`):authConfig 结构为 `BearerFormat: opaque` + `opaqueTokenConfig.tokens:[{enable,tokenData,tokenName}]`(值写 `Opaque` 报 "Opaque is invalid",裸 `tokens` 报 "BearerFormat is required";token 32-128 字符 Base64 字符集,存 docker-image/.env 的 `FC_BEARER_TOKEN`,gitignored)。验证:无 token/错 token → 403,对 token + WS 升级 → 101,普通请求对 token → 400(过网关到容器)
  - **客户端携带**:mihomo `ws-opts.headers` 可带 `Authorization: Bearer <token>`(端到端验证 delay 225ms/HTTP 200);`grpc-opts` 无 headers 字段 → **gRPC 客户端无法过 Bearer 鉴权**,鉴权成为 WS 独有优势
  - **Cookie 会话亲和**:fc3 字段是 `sessionAffinity: GENERATED_COOKIE`(枚举 GENERATED_COOKIE/HEADER_FIELD/MCP_SSE/NONE)+ `sessionAffinityConfig`(sessionConcurrencyPerInstance/sessionIdleTimeoutInSeconds/sessionTTLInSeconds);写 `sessionAffinity: cookie` 报 invalid,`sessionAffinityConfig: cookie` 被静默忽略(sessionAffinity 显示 NONE)。开启后 **instanceConcurrency 强制 200**(报 "ConcurrencyLimit is invalid for session function, allowed: 200")。实测 WS 101 握手响应**不植入 Set-Cookie**(x-fc-cookie-session-id),mihomo 也不管理 cookie → 会话亲和对 VLESS+WS 代理连接无效(长连接本身有连接级亲和),与 2026-08 早前 gRPC 时代结论一致;开启亲和后代理功能正常
  - **HeaderField 会话亲和**(`sessionAffinity: HEADER_FIELD` + `sessionAffinityConfig.affinityHeaderFieldName: mySessionId`,FC 会把 header 名规范化为小写 mysessionid):**客户端传入模式可行**——mihomo `ws-opts.headers` 带固定 `mySessionId` 值即实现粘性,与 Bearer(Authorization 头)共存验证 delay 243ms/HTTP 200。实例调度验证(s instance list):4 个新 distinct 会话值 → 新增 2 实例(正好 = 4 会话 ÷ sessionConcurrencyPerInstance=2);复用同一值 4 次 → 实例零增长(粘在同一实例)。服务端生成模式(不带 header)下 WS 101 响应同样不回传 session ID 头,与 Cookie 一样不适用于代理。注意:固定 header 值会把**所有连接都钉到一个实例**(0.1 vCPU 实例上集中负载);个人代理场景无实际收益,且同样丢失 instanceConcurrency=30 的并发控制 → 建议不启用
  - 部署:`cd fc && s deploy -t s.ws.yaml -y`(需 export FC_BEARER_TOKEN)
- 本地 Docker Desktop(qemu amd64)下容器带 tcpFastOpen:true 会导致连接被重置/400(mihomo/裸握手均失败),生产 FC 不受影响;本地联调需去掉 tcpFastOpen

# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-27
**Updated:** 2026-08-27
**Branch:** dev

## OVERVIEW

Xray-core Docker proxy service using VLESS + gRPC + TLS. Single container deployment; local Docker for dev, Alibaba Cloud FC 3.0 (custom-container) for production across 20 regions (11 overseas + 9 CN). Images built via GitHub Actions and pushed to Docker Hub (public, shared by all nodes).

## STRUCTURE

```
.
├── docker-image/          # Docker deployment
│   ├── Dockerfile
│   ├── config.template.json
│   ├── entrypoint.sh
│   ├── healthcheck.sh
│   ├── docker-compose.yml
│   └── .env.example       # Runtime vars only (UUID / GRPC_SERVICE_NAME)
├── client-config/         # Clash client templates
│   └── clash-verge.yaml.template   # Dual-node (HK+SG) + url-test auto-switch
├── fc/
│   └── s.yaml             # Serverless Devs multi-region FC config
├── scripts/
│   ├── gen-client-config.sh   # Generate dual-node client config
│   └── deploy-fc.sh           # Local FC deploy script (build/push/deploy)
├── .env.deploy.example    # Deploy credentials template (Docker Hub/Aliyun)
├── .github/workflows/
│   └── deploy.yml         # Build+push images, then Serverless Devs deploy FC
└── .gitignore
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Modify proxy config | `docker-image/config.template.json` | Xray config template, envsubst at runtime |
| Update Docker build | `docker-image/Dockerfile` | Multi-stage Alpine 3.20 build |
| Update CI/CD | `.github/workflows/deploy.yml` | GitHub Actions (build+push+FC deploy) |
| Client configuration | `client-config/clash-verge.yaml.template` | mihomo/Clash template (dual-node, url-test) |
| FC deployment config | `fc/s.yaml` | Serverless Devs, regions + images per node |
| Generate client config | `scripts/gen-client-config.sh` | `<hk_host> <sg_host> [hk_port] [sg_port]` |
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
| `GRPC_SERVICE_NAME` | No | `ProxyService` | gRPC service name for VLESS transport |

Deploy credentials (`.env.deploy`, mirror each to a GitHub Secret for CI):
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `ALIBABA_CLOUD_ACCOUNT_ID`, `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET`.

### Xray-core Version

Pinned to **v26.2.6**. Update the `XRAY_VERSION` arg in `Dockerfile` to change.

### Base Image

Alpine 3.20 for both build and runtime stages. Final image is approximately 27-35MB.

### Port

Xray listens on **port 8089** (plain gRPC; TLS terminated by FC gateway). No reverse proxy in front of it. **FC client endpoint is also 8089** — it is the FC gRPC entry port (ALPN negotiates h2); port 443 does NOT support h2 and cannot carry gRPC.

### Config Templating

- `config.template.json` uses `${UUID}` and `${GRPC_SERVICE_NAME}` placeholders
- `entrypoint.sh` runs `envsubst` at container start to produce `/etc/xray/config.json`
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

# Generate dual-node client config (HK + SG, url-test auto-switch)
./scripts/gen-client-config.sh <hk_host> <sg_host> 8089 8089

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
- Job 2 `deploy-fc`: Serverless Devs `s deploy -y` from `fc/` (nodes per FC_NODES matrix)
- Docker Hub secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
- FC deploy secrets: `ALIBABA_CLOUD_ACCOUNT_ID`, `ALIBABA_CLOUD_ACCESS_KEY_ID`, `ALIBABA_CLOUD_ACCESS_KEY_SECRET`, `UUID`

## ARCHITECTURE

```
Client (mihomo/Clash, Voynix-Auto url-test auto-switch)
    |
    | VLESS + gRPC + TLS (fcapp.run:8089, ALPN h2, skip-cert-verify)
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

All nodes use Docker Hub public image `docker.io/<user>/voynix-xray`; deployment scope is controlled by the `FC_NODES` repo variable (comma-separated, e.g. `sg,hk,seoul`). Empty/空白/未设置 → CI 显式报错; unknown keys also fail fast. `fc/s.yaml` defines 20 nodes (11 overseas + 9 CN, YAML anchor `&node-base` for shared props).

| Key | Region | Function | Client host (fcapp.run:8089) |
|-----|--------|----------|------------------------------|
| `sg` | ap-southeast-1 | `voynix-xray-sg` | `voynix-xray-sg-*.ap-southeast-1.fcapp.run` |
| `hk` | cn-hongkong | `voynix-xray-hk` | `voynix-xray-hk-*.cn-hongkong.fcapp.run` |
| `seoul` | ap-northeast-2 | `voynix-xray-seoul` | `voynix-xray-seoul-*.ap-northeast-2.fcapp.run` |
| `tokyo` | ap-northeast-1 | `voynix-xray-tokyo` | `voynix-xray-tokyo-*.ap-northeast-1.fcapp.run` |
| `kl` | ap-southeast-3 | `voynix-xray-kl` | `voynix-xray-kl-*.ap-southeast-3.fcapp.run` |
| `jakarta` | ap-southeast-5 | `voynix-xray-jakarta` | `voynix-xray-jakarta-*.ap-southeast-5.fcapp.run` |
| `bangkok` | ap-southeast-7 | `voynix-xray-bangkok` | `voynix-xray-bangkok-*.ap-southeast-7.fcapp.run` |
| `frankfurt` | eu-central-1 | `voynix-xray-frankfurt` | `voynix-xray-frankfurt-*.eu-central-1.fcapp.run` |
| `london` | eu-west-1 | `voynix-xray-london` | `voynix-xray-london-*.eu-west-1.fcapp.run` |
| `va` | us-east-1 | `voynix-xray-va` | `voynix-xray-va-*.us-east-1.fcapp.run` |
| `sv` | us-west-1 | `voynix-xray-sv` | `voynix-xray-sv-*.us-west-1.fcapp.run` |
| `hangzhou` | cn-hangzhou | `voynix-xray-hangzhou` | `voynix-xray-hangzhou-*.cn-hangzhou.fcapp.run` |
| `shanghai` | cn-shanghai | `voynix-xray-shanghai` | `voynix-xray-shanghai-*.cn-shanghai.fcapp.run` |
| `qingdao` | cn-qingdao | `voynix-xray-qingdao` | `voynix-xray-qingdao-*.cn-qingdao.fcapp.run` |
| `beijing` | cn-beijing | `voynix-xray-beijing` | `voynix-xray-beijing-*.cn-beijing.fcapp.run` |
| `zhangjiakou` | cn-zhangjiakou | `voynix-xray-zhangjiakou` | `voynix-xray-zhangjiakou-*.cn-zhangjiakou.fcapp.run` |
| `huhehaote` | cn-huhehaote | `voynix-xray-huhehaote` | `voynix-xray-huhehaote-*.cn-huhehaote.fcapp.run` |
| `wulanchabu` | cn-wulanchabu | `voynix-xray-wulanchabu` | `voynix-xray-wulanchabu-*.cn-wulanchabu.fcapp.run` |
| `shenzhen` | cn-shenzhen | `voynix-xray-shenzhen` | `voynix-xray-shenzhen-*.cn-shenzhen.fcapp.run` |
| `chengdu` | cn-chengdu | `voynix-xray-chengdu` | `voynix-xray-chengdu-*.cn-chengdu.fcapp.run` |

Note: CN nodes (cn-*) defined 2026-08 per request; deploying proxy on CN regions carries compliance risk — user's decision. Old SG function (`proxy_service$xray-exit`, ACR image) was deleted 2026-08 and replaced by `voynix-xray-sg` (Docker Hub image, same spec as HK).

## NOTES

- FC gateway terminates TLS; no container-side certs (inbound plain gRPC)
- Client must set `skip-cert-verify: true`
- FC client port is **8089** (gRPC entry, ALPN h2); 443 does not work for gRPC
- FC function spec (2026-08): 0.1 vCPU / 128MB / `instanceConcurrency` 30 / `minInstances` 0 / `reservedConcurrency` 15. Console "弹性实例配额" column maps to `reservedConcurrency` (CONCURRENCY, not instance count); real instance-count cap (`targetInstances`) is unset → elastic. 100-concurrency load test: 3 active instances, no 429 (gRPC long-connection reuse keeps FC-side concurrent requests under the cap). Session affinity (any type) was tried 2026-08 and reverted: FC forces `instanceConcurrency` to 200 and the 4 affinity types (Cookie/HeaderField/MCP SSE/MCP Streamable) are all useless for VLESS+gRPC (mihomo/Xray gRPC transport doesn't process cookies or custom headers; gRPC long connections already have connection-level affinity)
- Never verify FC nodes with plain `curl` (HTTP/1.1 → 502 `Process exited unexpectedly` is expected for gRPC-only); use mihomo client and `curl -x http://127.0.0.1:7890 https://www.google.com` (204 = OK)
- Both FC nodes use the same Docker Hub public image `docker.io/<user>/voynix-xray` (no secrets in image; runtime vars injected via env). ACR no longer used (personal edition: one instance per account was the original blocker, now moot). Deployment scope: GitHub Actions `deploy-fc` job uses a matrix driven by the `FC_NODES` repo variable (comma-separated node keys, e.g. `sg,hk,seoul`); unset/empty FC_NODES or unknown keys make the workflow fail fast with a clear message (placeholder `__none__` in matrix)
- Local `docker push` to Docker Hub fails with EOF/broken pipe: Docker Desktop auto-detects system proxy (WPAD hijacked by Clash fake-ip) and configures dead proxy :3128; workaround is `crane push` (direct, reuses docker login creds)
- No nginx. FC gateway terminates TLS; Xray inbound is plain gRPC (no TLS)
- No test suite. Infrastructure project
- Runtime envsubst means config changes only need a container restart, not a rebuild
- gRPC transport (multiMode is client-side only, not set on server)
- Client config `Voynix-Auto` url-test measures `http://www.gstatic.com/generate_204` every 300s (tolerance 50ms)

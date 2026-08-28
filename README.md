# Voynix

基于 Xray-core 的独立 Docker 代理服务，使用 VLESS + gRPC + TLS 协议，部署到阿里云函数计算 (FC) 多地域节点（12 个地域：6 海外 + 6 国内）。客户端配置自动生成，支持按延迟自动切换节点。

## 使用方式一览

| 方式 | 适用场景 | 核心命令 |
|------|---------|---------|
| **开箱即用** | GitHub Actions 自动部署,配置一次 Secrets/Variables,推送代码即完成构建+部署 | `git push origin main` |
| **客户端配置生成** | 自动抓取已部署节点域名,生成 Clash/mihomo 配置 | `scripts/gen-client-config.sh` |
| **本地手动部署** | 本地构建镜像、推送 Docker Hub、部署 FC,适合首次验证/调试 | `scripts/deploy-fc.sh` |
| **本地调试** | 不依赖 FC,本地 Docker 起容器开发调试 | `docker compose up -d` |

## 公共前置准备:UUID

VLESS 客户端认证 UUID 是四种方式的公共前置项,生成一次,各处共用:

```bash
# Linux/macOS
uuidgen | tr '[:upper:]' '[:lower:]'

# 或使用在线工具
https://www.uuidgenerator.net/
```

UUID 用于以下位置:

| 位置 | 用途 |
|------|------|
| GitHub Actions **Secrets.`UUID`** | 开箱即用:CI 部署时注入 FC 环境变量 |
| `docker-image/.env` 的 `UUID` | 本地手动部署、客户端配置生成、本地调试 |
| `client-config/clash-verge.yaml` 的 `uuid` | 生成的客户端配置,与服务端一致才能连上 |

## 架构概览

### FC 多地域部署(生产)

```
Client (mihomo/Clash)
    │
    │ VLESS + gRPC + TLS (fcapp.run:8089, ALPN h2)
    ├──────────────┬──────────────┬──────────────┬───────────┬────────── ...
    ↓              ↓              ↓              ↓
 香港 FC         新加坡 FC       东京 FC       法兰克福 FC  其他节点
cn-hongkong    ap-southeast-1  ap-northeast-1  eu-central-1  (见节点清单)
voynix-xray-hk voynix-xray-sg  voynix-xray-tokyo voynix-xray-frankfurt ...
    │              │              │              │
    │ Direct       │ Direct       │ Direct       │ Direct
    ↓              ↓              ↓              ↓
Internet       Internet       Internet       Internet

客户端自动切换:Voynix-Auto (url-test) 按延迟选优
```

### 本地 Docker 部署(开发调试)

```
┌─────────────────────────────────┐
│       Client (mihomo/Clash)     │
│         VLESS + gRPC            │
└───────────────┬─────────────────┘
                │
                │  port 8089
                ↓
┌─────────────────────────────────┐
│       Xray Container            │
│       Alpine 3.20 / ~35MB       │
│       Non-root user (UID 1000)  │
└───────────────┬─────────────────┘
                │
                │  Direct
                ↓
            Internet
```

> 部署哪些地域由 **`FC_NODES`** 控制(逗号分隔,任意子集,如 `sg,hk,tokyo`),`fc/s.yaml` 只维护可用节点清单。**未设置或为空时显式报错**,未知节点键同样报错。

> FC 网关终止 TLS，Xray inbound 为明文 gRPC（无 `security:tls`），客户端连 FC 域名的 **8089** 端口（FC gRPC 入口，支持 HTTP/2 ALPN h2），`skip-cert-verify: true`。

## 特性

- ✅ **VLESS 协议**: 轻量高效的代理协议
- ✅ **gRPC 传输**: 基于 HTTP/2，客户端支持 multiMode
- ✅ **TLS 加密**: FC 部署由 FC 网关终止 TLS
- ✅ **开箱即用**: 配置好 GitHub Secrets/Variables 后,推送代码自动构建+部署
- ✅ **一键部署**: `deploy-fc.sh` 构建 → 推送 → 部署,支持单节点或 `FC_NODES` 批量部署
- ✅ **自动生成客户端配置**: `gen-client-config.sh` 自动抓取 FC 节点域名,无需手填
- ✅ **轻量镜像**: Alpine 3.20 基础镜像，约 35MB
- ✅ **低成本**: FC 按量计费,minInstances 0 无请求不收费,0.1 vCPU/128MB 轻量规格,gRPC 长连接复用降低并发费用
- ✅ **运行时配置**: envsubst 模板替换，改配置只需重启容器
- ✅ **私有 IP 过滤**: 路由规则屏蔽 geoip:private
- ✅ **FC 多地域**: 6 个海外 + 6 个国内地域节点
- ✅ **客户端自动切换**: url-test 按延迟自动选优 (Voynix-Auto)

## 目录结构

```
voynix/
├── docker-image/
│   ├── Dockerfile                    # 多阶段构建
│   ├── config.template.json          # Xray 配置模板
│   ├── entrypoint.sh                 # 容器入口脚本
│   ├── healthcheck.sh                # 健康检查脚本
│   ├── docker-compose.yml            # Compose 配置(本地调试)
│   └── .env.example                  # 运行时环境变量示例 (UUID/GRPC_SERVICE_NAME)
├── client-config/
│   └── clash-verge.yaml.template     # 客户端配置模板(多节点 + url-test)
├── fc/
│   └── s.yaml                        # Serverless Devs 多地域 FC 部署配置
├── scripts/
│   ├── deploy-fc.sh                  # 本地手动部署:构建镜像 → 推送 → 部署 FC
│   └── gen-client-config.sh          # 客户端配置生成:自动抓取域名,生成多节点配置
├── docs/
│   └── memory.md                     # 内部运维笔记(实测经验/故障排查记录)
├── .env.deploy.example               # 部署凭据示例 (Docker Hub/阿里云, 已被 gitignore)
├── .github/workflows/
│   └── deploy.yml                    # GitHub Actions 构建 + FC 部署
└── .gitignore
```

## 开箱即用:GitHub Actions 自动部署

推送 `docker-image/**`、`fc/**` 或 `.github/workflows/deploy.yml` 到 main/master 分支时自动触发(也支持 `workflow_dispatch` 手动触发):Job 1 构建镜像并推送 Docker Hub,Job 2 用 Serverless Devs 按 `FC_NODES` 变量批量部署 FC 节点。**只需配置一次 Secrets/Variables,之后推送代码即可完成部署。**

### 1. 配置 GitHub Secrets / Variables

在仓库 `Settings → Secrets and variables → Actions` 中配置(与 `.env.deploy` 内容一一对应):

**Secrets**(在 **Secrets** 页签,逐个添加):

| Secret | 必需 | 说明 |
|--------|------|------|
| `DOCKERHUB_USERNAME` | 是 | Docker Hub 用户名(镜像仓库 owner,与 `.env.deploy` 一致) |
| `DOCKERHUB_TOKEN` | 是 | Docker Hub Access Token(仅 build-and-push job 使用) |
| `ALIBABA_CLOUD_ACCOUNT_ID` | 是 | 阿里云账号 ID |
| `ALIBABA_CLOUD_ACCESS_KEY_ID` | 是 | 阿里云 AccessKey ID |
| `ALIBABA_CLOUD_ACCESS_KEY_SECRET` | 是 | 阿里云 AccessKey Secret |
| `UUID` | 是 | VLESS 客户端认证 UUID(见「公共前置准备:UUID」) |
| `GRPC_SERVICE_NAME` | 否 | 默认 `ProxyService`(不设置则用默认值) |
| `IMAGE_NAME` | 否 | 默认 `voynix-xray`(Docker Hub 镜像名与 FC 函数名前缀,公开 fork 可改,需与本地 `.env.deploy` 一致) |

**Variables**(在 **Variables** 页签添加):

| Variable | 必需 | 说明 |
|----------|------|------|
| `FC_NODES` | 是 | 逗号分隔节点键,如 `sg,hk,tokyo`;未设置/为空 → workflow 显式报错 |

### 2. 设置部署范围(FC_NODES)

```text
# 只部署 2 个节点:
GitHub → Settings → Secrets and variables → Actions → Variables
FC_NODES = sg,hk

# 部署任意子集(如亚洲 3 地域):
FC_NODES = sg,hk,tokyo

# 未设置 FC_NODES 时 workflow 会显式报错(防止误以为已部署)
```

可用节点键与地域:

海外:`sg`(新加坡)/`hk`(香港)/`tokyo`(东京)/`frankfurt`(法兰克福)/`va`(弗吉尼亚)/`sv`(硅谷)

国内:`hangzhou`(杭州)/`shanghai`(上海)/`beijing`(北京)/`zhangjiakou`(张家口)/`huhehaote`(呼和浩特)/`shenzhen`(深圳)

### 3. 推送触发部署

```bash
git push origin main   # 或推送 docker-image/**、fc/** 相关改动
```

注意事项:
- 各节点 FC 均使用 Docker Hub 公共镜像拉取(`docker.io/<user>/voynix-xray`),仓库必须设为 **Public**(镜像内不含 UUID 等机密,运行时经环境变量注入)
- 国内地域节点已定义于 `fc/s.yaml`,但**代理服务部署国内节点有合规风险,请自行评估**;部分国内地域需向阿里云单独申请开通

## 客户端配置生成(gen-client-config.sh)

自动从 FC 查询已部署节点的域名（调用 `aliyun fc GetTrigger` 获取 `urlInternet`），无需手动填写域名，生成 `client-config/clash-verge.yaml`（多节点 + `Voynix-Auto` 自动切换）。

### 1. 前置条件

- 已部署 FC 节点(见「开箱即用」或「本地手动部署」)
- aliyun CLI(需已 `aliyun configure` 登录)
- `docker-image/.env` 中的 `UUID` 和 `GRPC_SERVICE_NAME`

### 2. 生成配置

```bash
# 自动获取 fc/s.yaml 中所有已部署节点(未部署的自动跳过)
./scripts/gen-client-config.sh

# 只生成指定节点(空格或逗号分隔均可)
./scripts/gen-client-config.sh sg hk tokyo
./scripts/gen-client-config.sh sg,hk,tokyo

# 也支持 FC_NODES 环境变量或 .env.deploy 中的 FC_NODES(与 CI/部署语义一致,逗号分隔;设置为空/纯空白 → 显式报错)
FC_NODES=sg,hk,tokyo ./scripts/gen-client-config.sh
```

节点选择优先级:**命令行参数 > `FC_NODES` 环境变量 > 全部节点**。`FC_NODES` 未设置时生成全部已部署节点,设置后只生成其中列出的节点(与 CI 部署共用同一套节点键)。

### 3. 生成结果

生成结果包含(示例:已部署 sg/hk/tokyo 三个节点):

| 代理 | 说明 |
|------|------|
| `Voynix-SG` | 新加坡节点 (fcapp.run:8089) |
| `Voynix-HK` | 香港节点 (fcapp.run:8089) |
| `Voynix-Tokyo` | 东京节点 (fcapp.run:8089) |
| `Voynix-Auto` | url-test 组,每 300s 测速(`http://www.gstatic.com/generate_204`),按延迟自动切换,容差 50ms |

> FC 节点端口必须是 **8089**(FC gRPC 入口,支持 HTTP/2 ALPN h2;443 端口不支持 h2,无法用于 gRPC)。

### 4. 导入 Clash Verge(正常使用)

1. 打开 Clash Verge
2. 导入生成的 `clash-verge.yaml`
3. 选择 `Voynix-Auto` 代理组并测试连通性（或自行在 HK/SG 间手动选择）

> 客户端必须设置 `skip-cert-verify: true`，因为 FC 网关证书与客户端 servername 不匹配。

本机用 mihomo 验证配置连通性(调试用),见「本地调试」章节的「客户端验证」。

### 5. 测速 URL 说明

`Voynix-Auto` 组默认使用 `http://www.gstatic.com/generate_204` 测速（返回 204、无流量消耗、全球可达）。如需更换，修改模板中 `url-test` 的 `url` 字段后重新生成。

## 本地手动部署(deploy-fc.sh)

本地构建镜像、推送 Docker Hub、部署 FC 节点。适合首次验证或不想依赖 CI 的场景,确认无误后再切到 GitHub Actions 自动部署。

### 1. 前置条件

- Docker（构建镜像）
- 一个 UUID（生成方式见「公共前置准备:UUID」）

### 2. 配置环境变量

环境变量分两个文件存放:运行时变量在 `docker-image/.env`,部署凭据在仓库根 `.env.deploy`:

```bash
cp docker-image/.env.example docker-image/.env   # 填入 UUID(运行时变量)
cp .env.deploy.example .env.deploy               # 填入 Docker Hub / 阿里云凭据(部署专用,已被 gitignore)
```

### 3. 部署

```bash
./scripts/deploy-fc.sh                            # 构建+推送+部署 全部节点
./scripts/deploy-fc.sh build hk                   # 仅香港
./scripts/deploy-fc.sh deploy sg                  # 跳过构建,仅部署新加坡
./scripts/deploy-fc.sh deploy tokyo               # 仅部署东京
FC_NODES=sg,hk,tokyo ./scripts/deploy-fc.sh       # 按 FC_NODES 批量部署(逗号分隔,与 CI 语义一致)
```

节点选择优先级:**命令行参数 > `FC_NODES`(来自 `.env.deploy` 或环境变量) > 全部节点**。

## 本地调试(可选)

仅用于本地开发调试,不依赖 FC。生产部署走「开箱即用」或「本地手动部署」。

### 1. 启动容器

```bash
# 复制环境变量文件
cp docker-image/.env.example docker-image/.env

# 编辑 .env，填入你的 UUID
# UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# 启动容器
docker compose -f docker-image/docker-compose.yml up -d

# 检查运行状态
docker compose -f docker-image/docker-compose.yml ps
```

### 2. 手动构建镜像

```bash
docker build -t voynix-xray:latest docker-image/

# 直接运行
docker run -d -p 8089:8089 -e UUID=$(uuidgen) voynix-xray:latest
```

### 3. 客户端验证(mihomo)

本机用 mihomo 验证生成的客户端配置连通性(配置生成见「客户端配置生成」章节):

```bash
# 验证配置文件语法
mihomo -t -f client-config/clash-verge.yaml

# 启动 mihomo
mihomo -f client-config/clash-verge.yaml

# 通过代理测试(返回 204 即为通)
curl -x http://127.0.0.1:7890 https://www.google.com

# 查看自动切换组当前选择的节点
curl http://127.0.0.1:9090/proxies/Voynix-Auto
```

## 容器镜像

镜像存储在 Docker Hub(公共仓库,各节点共用):

| 镜像 | 路径 |
|------|------|
| Xray 服务 | `docker.io/<user>/voynix-xray:latest` |

### 拉取镜像

```bash
# 拉取镜像(公共仓库无需登录)
docker pull <user>/voynix-xray:latest
```

## 环境变量

环境变量分三类存放:运行时变量在 `docker-image/.env`,部署凭据在仓库根 `.env.deploy`(已被 gitignore),部署范围 `FC_NODES` 可写在 `.env.deploy` 或直接作为环境变量。

### 运行时变量(docker-image/.env)

| 变量 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `UUID` | 是 | (无) | VLESS 客户端认证 UUID(生成见「公共前置准备:UUID」) |
| `GRPC_SERVICE_NAME` | 否 | `ProxyService` | gRPC 传输的服务名称 |

容器启动时 `entrypoint.sh` 用 envsubst 将这两个变量注入 `config.template.json` 生成 `config.json`,改配置只需重启容器。

### 部署凭据(.env.deploy)

| 变量 | 必需 | 说明 |
|------|------|------|
| `DOCKERHUB_USERNAME` | 是 | Docker Hub 用户名(镜像仓库 owner,各节点共用) |
| `DOCKERHUB_TOKEN` | 是 | Docker Hub Access Token(构建推送时用) |
| `ALIBABA_CLOUD_ACCOUNT_ID` | 是 | 阿里云账号 ID |
| `ALIBABA_CLOUD_ACCESS_KEY_ID` | 是 | 阿里云 AccessKey ID |
| `ALIBABA_CLOUD_ACCESS_KEY_SECRET` | 是 | 阿里云 AccessKey Secret |

`deploy-fc.sh` 与 `gen-client-config.sh` 都会读取本文件;模板见 `.env.deploy.example`。

### 部署范围(FC_NODES)

| 变量 | 必需 | 说明 |
|------|------|------|
| `FC_NODES` | 否 | 逗号分隔节点键,如 `sg,hk,tokyo`;未设置 → 全部节点,空/纯空白 → 显式报错 |

可写在 `.env.deploy` 或作为 shell 环境变量传入,作用于 `deploy-fc.sh`(部署范围)与 `gen-client-config.sh`(生成范围),与 CI 的 `FC_NODES` 仓库变量语义一致。

### 镜像/函数名前缀(IMAGE_NAME)

| 变量 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `IMAGE_NAME` | 否 | `voynix-xray` | Docker Hub 镜像名与 FC 函数名前缀(如 `voynix-xray-sg`),客户端显示名派生自其首段(`Voynix-SG`) |

公开 fork 后建议改成自己的名字(如 `IMAGE_NAME=myproxy`),本地 `.env.deploy` 与 GitHub Actions 的 `IMAGE_NAME` Secret 需保持一致;改后会同时影响镜像名、函数名与客户端配置名。

### 与 GitHub Actions 的对应

| 本地文件 | GitHub Actions | 说明 |
|---------|---------------|------|
| `docker-image/.env` 的 `UUID` | **Secrets.**`UUID` | CI 部署时注入 FC 环境变量 |
| `docker-image/.env` 的 `GRPC_SERVICE_NAME` | **Secrets.**`GRPC_SERVICE_NAME`(可选) | 不设置则用默认值 |
| `.env.deploy` 的 5 个凭据 | **Secrets.** 同名 5 项 | 与本地文件一一对应 |
| `FC_NODES` | **Variables.**`FC_NODES` | 部署范围控制 |
| `IMAGE_NAME` | **Secrets.**`IMAGE_NAME`(可选) | 镜像/函数名前缀,默认 `voynix-xray` |

完整配置步骤见「开箱即用:GitHub Actions 自动部署」。

## 技术细节

### gRPC 配置

```json
{
  "streamSettings": {
    "network": "grpc",
    "grpcSettings": {
      "serviceName": "ProxyService"
    }
  }
}
```

> inbound 为明文 gRPC（无 `security:tls`），TLS 由 FC 网关终止。

### Xray-core 版本

固定为 **v26.2.6**。修改 `Dockerfile` 中的 `XRAY_VERSION` 参数可更新版本。

## 故障排查

### 查看日志

```bash
# 容器日志
docker compose -f docker-image/docker-compose.yml logs -f

# 健康检查状态
docker inspect --format='{{.State.Health.Status}}' <container_name>
```

### 测试连接

```bash
# 测试本地端口是否可达(明文 gRPC,无 TLS,不要用 curl https)
nc -zv localhost 8089

# 通过代理测试
curl -x http://127.0.0.1:7890 https://www.google.com
```

### 常见问题

**1. 连接超时**
```
检查项:
- 容器是否正常运行 (docker ps)
- 端口 8089 是否被占用
- UUID 是否正确
- FC 节点时客户端 skip-cert-verify 是否设为 true（本地部署无 TLS，不需要）
```

**2. 认证失败**
```
检查项:
- 客户端和服务端 UUID 是否一致
- gRPC 服务名是否匹配
- 客户端配置中的服务器地址是否正确
```

**3. 容器启动失败**
```
检查项:
- .env 文件中 UUID 是否已设置
- 查看容器日志: docker compose logs
- 确认 Docker 版本支持 Compose V2
```

**4. FC 节点 curl 返回 502 (Process exited unexpectedly)**
```
原因: curl 发的是 HTTP/1.1 请求,VLESS+gRPC 只接受 HTTP/2(FC gRPC 入口)。
这通常是误判,不代表节点故障。
正确验证:
- 用真实 mihomo 客户端: mihomo -f client-config/clash-verge.yaml
- curl -x http://127.0.0.1:7890 https://www.google.com   # 返回 204 即为通
```

**5. mihomo 报 `http2: unexpected ALPN protocol, want h2`**
```
原因: 客户端端口配成了 443,而 FC 的 gRPC 入口是 8089(支持 ALPN h2),443 不支持。
修复: 重新生成配置,端口用 8089
  ./scripts/gen-client-config.sh
```

## 注意事项

1. 本项目仅供学习研究
2. 请遵守当地法律法规
3. 作者不对任何滥用行为负责

## 许可证

MIT License

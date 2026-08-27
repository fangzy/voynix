# Voynix

基于 Xray-core 的独立 Docker 代理服务，使用 VLESS + gRPC + TLS 协议。单容器部署，支持本地 Docker 与阿里云函数计算 (FC) 多地域部署（海外 11 地域，默认香港 + 新加坡）。

## 架构概览

### 本地 Docker 部署

```
┌─────────────────────────────────┐
│       Client (mihomo/Clash)     │
│         VLESS + gRPC + TLS      │
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

### FC 多地域部署(生产)

```
Client (mihomo/Clash)
    │
    │ VLESS + gRPC + TLS (fcapp.run:8089, ALPN h2)
    ├──────────────┬──────────────┬──────────────┬───────────┬────────── ...
    ↓              ↓              ↓              ↓
 香港 FC         新加坡 FC       东京 FC         首尔 FC     其他 7 个地域
cn-hongkong    ap-southeast-1  ap-northeast-1  ap-northeast-2  (见节点清单)
voynix-xray-hk voynix-xray-sg  voynix-xray-tokyo voynix-xray-frankfurt ...
    │              │              │              │
    │ Direct       │ Direct       │ Direct       │ Direct
    ↓              ↓              ↓              ↓
Internet       Internet       Internet       Internet

客户端自动切换:Voynix-Auto (url-test) 按延迟选优
```

> 部署哪些地域由 GitHub Actions 的 **`FC_NODES` 变量**控制(逗号分隔,任意子集,如 `sg,hk,tokyo`),`fc/s.yaml` 只维护可用节点清单。**未设置或为空时 workflow 显式报错**,未知节点键同样报错。

> FC 网关终止 TLS，Xray inbound 为明文 gRPC（无 `security:tls`），客户端连 FC 域名的 **8089** 端口（FC gRPC 入口，支持 HTTP/2 ALPN h2），`skip-cert-verify: true`。

## 特性

- ✅ **VLESS 协议**: 轻量高效的代理协议
- ✅ **gRPC 传输**: 基于 HTTP/2，客户端支持 multiMode
- ✅ **TLS 加密**: 本地部署自签名证书；FC 部署由 FC 网关终止 TLS
- ✅ **单容器部署**: 无需编排，docker compose 一键启动
- ✅ **轻量镜像**: Alpine 3.20 基础镜像，约 35MB
- ✅ **安全运行**: 非 root 用户 (UID 1000) 运行 Xray 进程
- ✅ **运行时配置**: envsubst 模板替换，改配置只需重启容器
- ✅ **健康检查**: 内置 Docker HEALTHCHECK
- ✅ **自动构建**: GitHub Actions CI/CD，推送至 Docker Hub，Serverless Devs 自动部署 FC
- ✅ **私有 IP 过滤**: 路由规则屏蔽 geoip:private
- ✅ **FC 多地域**: 11 个海外 + 9 个国内地域节点(FC_NODES 配置部署范围)
- ✅ **客户端自动切换**: url-test 按延迟自动选优 (Voynix-Auto)

## 目录结构

```
voynix/
├── docker-image/
│   ├── Dockerfile                    # 多阶段构建
│   ├── config.template.json          # Xray 配置模板
│   ├── entrypoint.sh                 # 容器入口脚本
│   ├── healthcheck.sh                # 健康检查脚本
│   ├── docker-compose.yml            # Compose 配置
│   └── .env.example                  # 运行时环境变量示例 (UUID/GRPC_SERVICE_NAME)
├── client-config/
│   └── clash-verge.yaml.template     # 客户端配置模板(多节点 + url-test)
├── fc/
│   └── s.yaml                        # Serverless Devs 多地域 FC 部署配置
├── scripts/
│   ├── gen-client-config.sh          # 生成多节点客户端配置
│   └── deploy-fc.sh                  # 本地 FC 部署脚本(构建/推送/部署)
├── .env.deploy.example               # 部署凭据示例 (Docker Hub/阿里云, 已被 gitignore)
├── .github/workflows/
│   └── deploy.yml                    # GitHub Actions 构建 + FC 部署
└── .gitignore
```

## 快速开始

### 1. 前置条件

- Docker 和 Docker Compose
- 一个 UUID（用于客户端认证）

**生成 UUID**:
```bash
# Linux/macOS
uuidgen | tr '[:upper:]' '[:lower:]'

# 或使用在线工具
https://www.uuidgenerator.net/
```

### 2. 构建与运行

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

### 3. 手动构建镜像

```bash
docker build -t voynix-xray:latest docker-image/

# 直接运行
docker run -d -p 8089:8089 -e UUID=$(uuidgen) voynix-xray:latest
```

### 4. 验证服务

```bash
# 检查容器日志
docker compose -f docker-image/docker-compose.yml logs

# 测试端口连通性
curl -k https://localhost:8089
```

## FC 部署(新加坡 + 香港)

通过阿里云函数计算 (FC 3.0, 自定义容器) 多地域部署:

| 文件 | 说明 |
|------|------|
| `fc/s.yaml` | Serverless Devs 配置:12 个节点(6 海外 + 6 国内,锚点复用公共配置),均用 Docker Hub 公共镜像 |
| `scripts/deploy-fc.sh` | 本地调试脚本:构建镜像 → 推送 → 部署,支持单节点 (`build\|deploy` + `both\|sg\|hk\|tokyo`) |
| `.github/workflows/deploy.yml` | CI:构建推送镜像 + Serverless Devs 按 `FC_NODES` 变量批量部署 |

本地调试(先本地验证,成功后再依赖 CI):

```bash
cp docker-image/.env.example docker-image/.env   # 填入 UUID(运行时变量)
cp .env.deploy.example .env.deploy               # 填入 Docker Hub / 阿里云凭据(部署专用,已被 gitignore)
./scripts/deploy-fc.sh                            # 构建+推送+部署 全部节点
./scripts/deploy-fc.sh build hk                   # 仅香港
./scripts/deploy-fc.sh deploy sg                  # 跳过构建,仅部署新加坡
./scripts/deploy-fc.sh deploy tokyo               # 仅部署东京
```

环境变量分文件存放:运行时变量(`UUID`/`GRPC_SERVICE_NAME`)在 `docker-image/.env`,部署凭据(Docker Hub/阿里云)在仓库根 `.env.deploy`。

### CI 批量部署(FC_NODES 配置项)

GitHub Actions 的 `deploy-fc` job 按 **`FC_NODES` 仓库变量**(逗号分隔)批量部署:

```text
# 只部署 2 个节点:
GitHub → Settings → Secrets and variables → Actions → Variables
FC_NODES = sg,hk

# 部署任意子集(如亚洲 3 地域):
FC_NODES = sg,hk,tokyo

# 未设置 FC_NODES 时 workflow 会显式报错(防止误以为已部署)
```

可用节点键与地域(仅支持自定义容器的 FC 3.0 地域):

海外:`sg`(新加坡)/`hk`(香港)/`tokyo`(东京)/`frankfurt`(法兰克福)/`va`(弗吉尼亚)/`sv`(硅谷)

国内:`hangzhou`(杭州)/`shanghai`(上海)/`beijing`(北京)/`zhangjiakou`(张家口)/`huhehaote`(呼和浩特)/`shenzhen`(深圳)

> 注:首尔/吉隆坡/雅加达/曼谷/伦敦/青岛/乌兰察布/成都等地域的 FC **不支持自定义容器镜像**,已从节点清单排除(2026-08 官方 supported-regions 核对)。

注意事项:
- 各节点 FC 均使用 Docker Hub 公共镜像拉取(`docker.io/<user>/voynix-xray`),仓库必须设为 **Public**(镜像内不含 UUID 等机密,运行时经环境变量注入)
- 国内地域节点已定义于 `fc/s.yaml`,但**代理服务部署国内节点有合规风险,请自行评估**;部分国内地域需向阿里云单独申请开通

### 实测经验(2026-08)

**节点信息**(12 个节点:6 海外 + 6 国内,已实测新加坡/香港,其余由 FC_NODES 部署后生效):

| 节点键 | 地域 | 函数名 | 镜像源 | 客户端地址 |
|--------|------|--------|--------|-----------|
| `sg` | ap-southeast-1 | `voynix-xray-sg` | Docker Hub 公共镜像 | `voynix-xray-sg-xxx.ap-southeast-1.fcapp.run:8089` |
| `hk` | cn-hongkong | `voynix-xray-hk` | Docker Hub 公共镜像 | `voynix-xray-hk-xxx.cn-hongkong.fcapp.run:8089` |
| `tokyo` | ap-northeast-1 | `voynix-xray-tokyo` | Docker Hub 公共镜像 | `voynix-xray-tokyo-xxx.ap-northeast-1.fcapp.run:8089` |
| `frankfurt` | eu-central-1 | `voynix-xray-frankfurt` | Docker Hub 公共镜像 | `voynix-xray-frankfurt-xxx.eu-central-1.fcapp.run:8089` |
| `va` | us-east-1 | `voynix-xray-va` | Docker Hub 公共镜像 | `voynix-xray-va-xxx.us-east-1.fcapp.run:8089` |
| `sv` | us-west-1 | `voynix-xray-sv` | Docker Hub 公共镜像 | `voynix-xray-sv-xxx.us-west-1.fcapp.run:8089` |
| `hangzhou` | cn-hangzhou | `voynix-xray-hangzhou` | Docker Hub 公共镜像 | `voynix-xray-hangzhou-xxx.cn-hangzhou.fcapp.run:8089` |
| `shanghai` | cn-shanghai | `voynix-xray-shanghai` | Docker Hub 公共镜像 | `voynix-xray-shanghai-xxx.cn-shanghai.fcapp.run:8089` |
| `beijing` | cn-beijing | `voynix-xray-beijing` | Docker Hub 公共镜像 | `voynix-xray-beijing-xxx.cn-beijing.fcapp.run:8089` |
| `zhangjiakou` | cn-zhangjiakou | `voynix-xray-zhangjiakou` | Docker Hub 公共镜像 | `voynix-xray-zhangjiakou-xxx.cn-zhangjiakou.fcapp.run:8089` |
| `huhehaote` | cn-huhehaote | `voynix-xray-huhehaote` | Docker Hub 公共镜像 | `voynix-xray-huhehaote-xxx.cn-huhehaote.fcapp.run:8089` |
| `shenzhen` | cn-shenzhen | `voynix-xray-shenzhen` | Docker Hub 公共镜像 | `voynix-xray-shenzhen-xxx.cn-shenzhen.fcapp.run:8089` |

> 各节点均使用 Docker Hub 公共镜像 `docker.io/<user>/voynix-xray`(镜像内不含 UUID 等机密,运行时经环境变量注入)。旧新加坡函数 `proxy_service$xray-exit`(ACR 镜像)已于 2026-08 删除,由 `voynix-xray-sg` 接管。

**镜像推送(Docker Hub)**:本机 `docker push` 会被 Docker Desktop 自动检测出的死代理(3128)拦截,报 `EOF`/`broken pipe`。绕行方案:用 `crane`(go-containerregistry)直连推送,复用 `docker login` 凭据:

```bash
docker save voynix-xray:latest -o /tmp/voynix.tar
crane push /tmp/voynix.tar docker.io/<user>/voynix-xray:latest
```

**客户端端口必须是 8089**:FC gRPC 入口端口为 8089(`fcapp.run:8089` ALPN 协商出 `h2`);443 端口不支持 h2 ALPN,无法用于 gRPC。

**验证方式**:不要用 `curl` 测 FC 节点——curl 发的是 HTTP/1.1 请求,VLESS+gRPC 只接受 HTTP/2,会返回 502(`Process exited unexpectedly`)造成误判。用真实 mihomo 客户端验证:`mihomo -f client-config/clash-verge.yaml` 后 `curl -x http://127.0.0.1:7890 https://www.google.com` 返回 204 即为通。

**函数规格与弹性配置(2026-08 实测)**:`fc/s.yaml` 所有节点统一(锚点复用):

| 配置项 | 值 | 字段 |
|--------|-----|------|
| CPU / 内存 | 0.1 vCPU / 128MB | `cpu` / `memorySize` |
| 单实例并发 | 30 | `instanceConcurrency` |
| 最小实例数 | 0(无请求不收费) | `scalingConfig.minInstances` |
| 预留并发 | 15 | `concurrencyConfig.reservedConcurrency` |

**实例数 vs 并发数(实测结论)**:控制台"弹性实例配额"列显示/编辑的就是 `concurrencyConfig.reservedConcurrency`(预留并发,单位 = 并发请求数),**不是实例数上限**;真正的实例数上限字段 `targetInstances`(GetScalingConfig)未设置时弹性不限。实例数由 FC 按流量弹性创建——压测 100 并发 HTTP(经 mihomo)时监控显示 **3 个活跃实例**,全程**无 429**:gRPC 长连接复用使 FC 端实际并发请求数未触及 15 上限,少量请求失败(SSL/HTTP2 framing)为本机链路问题而非 FC 流控。若需硬性实例数上限,须在 FC 控制台"函数配额"设置(超限返回 429)。

## 客户端配置

### 生成配置文件(多节点 + 自动切换)

`gen-client-config.sh` 会**自动从 FC 查询所有已部署节点的域名**(调用 `aliyun fc GetTrigger` 获取 `urlInternet`),无需手动填写域名。通过 `Voynix-Auto` (url-test) 组按延迟自动选优:

```bash
# 自动获取 fc/s.yaml 中所有已部署节点(未部署的自动跳过)
./scripts/gen-client-config.sh

# 只生成指定节点(空格或逗号分隔均可)
./scripts/gen-client-config.sh sg hk tokyo
./scripts/gen-client-config.sh sg,hk,tokyo

# 也支持 FC_NODES 环境变量(与 CI 部署语义一致,逗号分隔;设置为空/纯空白 → 显式报错)
FC_NODES=sg,hk,tokyo ./scripts/gen-client-config.sh
```

节点选择优先级:**命令行参数 > `FC_NODES` 环境变量 > 全部节点**。`FC_NODES` 未设置时生成全部已部署节点,设置后只生成其中列出的节点(与 CI 部署共用同一套节点键)。

脚本会自动读取 `docker-image/.env` 中的 `UUID` 和 `GRPC_SERVICE_NAME`，并调用 aliyun CLI(需已登录,`aliyun configure` 配置过)查询各节点 URL,生成 `client-config/clash-verge.yaml`。

生成结果包含(示例:已部署 sg/hk/tokyo 三个节点):

| 代理 | 说明 |
|------|------|
| `Voynix-SG` | 新加坡节点 (fcapp.run:8089) |
| `Voynix-HK` | 香港节点 (fcapp.run:8089) |
| `Voynix-Tokyo` | 东京节点 (fcapp.run:8089) |
| `Voynix-Auto` | url-test 组,每 300s 测速(`http://www.gstatic.com/generate_204`),按延迟自动切换,容差 50ms |

> FC 节点端口必须是 **8089**(FC gRPC 入口,支持 HTTP/2 ALPN h2;443 端口不支持 h2,无法用于 gRPC)。

### 使用 mihomo 验证

```bash
# 验证配置文件语法
mihomo -t -f client-config/clash-verge.yaml

# 启动 mihomo
mihomo -f client-config/clash-verge.yaml

# 通过代理测试
curl -x http://127.0.0.1:7890 https://www.google.com

# 查看自动切换组当前选择的节点
curl http://127.0.0.1:9090/proxies/Voynix-Auto
```

### 导入 Clash Verge

1. 打开 Clash Verge
2. 导入生成的 `clash-verge.yaml`
3. 选择 `Voynix-Auto` 代理组并测试连通性（或自行在 HK/SG 间手动选择）

> 客户端必须设置 `skip-cert-verify: true`，因为 FC 网关证书与客户端 servername 不匹配。

### 测速 URL 说明

`Voynix-Auto` 组默认使用 `http://www.gstatic.com/generate_204` 测速（返回 204、无流量消耗、全球可达）。如需更换，修改模板中 `url-test` 的 `url` 字段后重新生成。

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

> 本机 `docker push` 会被 Docker Desktop 自动检测出的死代理(3128)拦截(见故障排查 #6),可用 `crane push` 绕行:

## 环境变量

| 变量 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `UUID` | 是 | (无) | VLESS 客户端认证 UUID |
| `GRPC_SERVICE_NAME` | 否 | `ProxyService` | gRPC 传输的服务名称 |

## 技术细节

### gRPC 配置

```json
{
  "streamSettings": {
    "network": "grpc",
    "security": "tls",
    "grpcSettings": {
      "serviceName": "ProxyService"
    }
  }
}
```

### 自签名证书

Docker 构建时自动生成 ECDSA P-256 自签名证书，域名为 `localhost`（SAN 包含 `127.0.0.1`）。证书存储在容器内 `/etc/xray/cert.pem` 和 `/etc/xray/key.pem`。

客户端需要配置 `skip-cert-verify: true`。

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
# 测试端口是否可达
curl -k https://localhost:8089

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
- 客户端 skip-cert-verify 是否设为 true
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
- 检查函数状态: cd fc && s voynix-hk info   # state: Active 且 resolvedImageUri 已解析
```

**5. mihomo 报 `http2: unexpected ALPN protocol, want h2`**
```
原因: 客户端端口配成了 443,而 FC 的 gRPC 入口是 8089(支持 ALPN h2),443 不支持。
修复: 重新生成配置,端口用 8089
  ./scripts/gen-client-config.sh
```

**6. 本地 docker push 到 Docker Hub 报 EOF / broken pipe**
```
原因: Docker Desktop 自动检测系统代理(被 Clash fake-ip 劫持的 WPAD),配出 3128 死代理。
修复: 用 crane 直连推送绕开 daemon 代理
  docker save voynix-xray:latest -o /tmp/voynix.tar
  crane push /tmp/voynix.tar docker.io/<user>/voynix-xray:latest
```

**7. FC 实例反复创建/销毁,日志显示健康检查通过但请求失败**
```
检查项:
- 用 s 查看函数信息确认镜像已解析: s voynix-hk info
- 确认客户端连的是 8089 端口(不是 443)
- 查看日志: cd fc && s voynix-hk logs --tail  (需 logConfig 已配置)
```

## 注意事项

1. 本项目仅供学习研究
2. 请遵守当地法律法规
3. 作者不对任何滥用行为负责

## 许可证

MIT License

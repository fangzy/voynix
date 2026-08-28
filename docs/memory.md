# Voynix 运维笔记（内部）

> 本文件为项目内部运维记录，**不面向公开用户**。README 只保留对使用者有价值的内容，以下实测数据、部署细节、个人环境问题与历史变更统一归档于此。

## 实测经验（2026-08）

### 节点信息

12 个节点（6 海外 + 6 国内，均使用 Docker Hub 公共镜像 `docker.io/<user>/voynix-xray`）。已实测新加坡/香港，其余由 `FC_NODES` 部署后生效：

| 节点键 | 地域 | 函数名 | 客户端地址 |
|--------|------|--------|-----------|
| `sg` | ap-southeast-1 | `voynix-xray-sg` | `voynix-xray-sg-xxx.ap-southeast-1.fcapp.run:8089` |
| `hk` | cn-hongkong | `voynix-xray-hk` | `voynix-xray-hk-xxx.cn-hongkong.fcapp.run:8089` |
| `tokyo` | ap-northeast-1 | `voynix-xray-tokyo` | `voynix-xray-tokyo-xxx.ap-northeast-1.fcapp.run:8089` |
| `frankfurt` | eu-central-1 | `voynix-xray-frankfurt` | `voynix-xray-frankfurt-xxx.eu-central-1.fcapp.run:8089` |
| `va` | us-east-1 | `voynix-xray-va` | `voynix-xray-va-xxx.us-east-1.fcapp.run:8089` |
| `sv` | us-west-1 | `voynix-xray-sv` | `voynix-xray-sv-xxx.us-west-1.fcapp.run:8089` |
| `hangzhou` | cn-hangzhou | `voynix-xray-hangzhou` | `voynix-xray-hangzhou-xxx.cn-hangzhou.fcapp.run:8089` |
| `shanghai` | cn-shanghai | `voynix-xray-shanghai` | `voynix-xray-shanghai-xxx.cn-shanghai.fcapp.run:8089` |
| `beijing` | cn-beijing | `voynix-xray-beijing` | `voynix-xray-beijing-xxx.cn-beijing.fcapp.run:8089` |
| `zhangjiakou` | cn-zhangjiakou | `voynix-xray-zhangjiakou` | `voynix-xray-zhangjiakou-xxx.cn-zhangjiakou.fcapp.run:8089` |
| `huhehaote` | cn-huhehaote | `voynix-xray-huhehaote` | `voynix-xray-huhehaote-xxx.cn-huhehaote.fcapp.run:8089` |
| `shenzhen` | cn-shenzhen | `voynix-xray-shenzhen` | `voynix-xray-shenzhen-xxx.cn-shenzhen.fcapp.run:8089` |

镜像内不含 UUID 等机密，运行时经环境变量注入（仓库必须设为 Public）。旧新加坡函数 `proxy_service$xray-exit`（ACR 镜像）已于 2026-08 删除，由 `voynix-xray-sg` 接管。

### 地域支持范围

仅列出支持自定义容器镜像的 FC 3.0 地域（2026-08 依据阿里云官方 supported-regions 图标实测核对）。以下地域**不支持**自定义容器镜像，已排除：首尔（ap-northeast-2）/吉隆坡（ap-southeast-3）/雅加达（ap-southeast-5）/曼谷（ap-southeast-7）/伦敦（eu-west-1）/利雅得（me-central-1）/青岛（cn-qingdao）/乌兰察布（cn-wulanchabu）/成都（cn-chengdu）。

### 镜像推送（Docker Hub）

本机 `docker push` 会被 Docker Desktop 自动检测出的死代理（3128）拦截，报 `EOF`/`broken pipe`。绕行方案：用 `crane`（go-containerregistry）直连推送，复用 `docker login` 凭据：

```bash
docker save voynix-xray:latest -o /tmp/voynix.tar
crane push /tmp/voynix.tar docker.io/<user>/voynix-xray:latest
```

### 客户端端口必须是 8089

FC gRPC 入口端口为 8089（`fcapp.run:8089` ALPN 协商出 `h2`）；443 端口不支持 h2 ALPN，无法用于 gRPC。

### FC 节点验证方式

不要用 `curl` 测 FC 节点——curl 发的是 HTTP/1.1 请求，VLESS+gRPC 只接受 HTTP/2，会返回 502（`Process exited unexpectedly`）造成误判。用真实 mihomo 客户端验证：

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

控制台"弹性实例配额"列显示/编辑的就是 `concurrencyConfig.reservedConcurrency`（预留并发，单位 = 并发请求数），**不是实例数上限**；真正的实例数上限字段 `targetInstances`（GetScalingConfig）未设置时弹性不限。实例数由 FC 按流量弹性创建——压测 100 并发 HTTP（经 mihomo）时监控显示 **3 个活跃实例**，全程**无 429**：gRPC 长连接复用使 FC 端实际并发请求数未触及 15 上限，少量请求失败（SSL/HTTP2 framing）为本机链路问题而非 FC 流控。若需硬性实例数上限，须在 FC 控制台"函数配额"设置（超限返回 429）。

## 内部故障排查

### Docker Desktop 死代理导致 docker push 失败（EOF / broken pipe）

原因：Docker Desktop 自动检测系统代理（被 Clash fake-ip 劫持的 WPAD），配出 3128 死代理。
修复：用 `crane` 直连推送绕开 daemon 代理（见上文「镜像推送」）。

### FC 实例反复创建/销毁，日志显示健康检查通过但请求失败

检查项：

- 用 `s` 查看函数信息确认镜像已解析：`cd fc && s voynix-hk info`（state: Active 且 resolvedImageUri 已解析）
- 确认客户端连的是 8089 端口（不是 443）
- 查看日志：`cd fc && s voynix-hk logs --tail`（需 logConfig 已配置）

## 会话记忆补充

（后续实测结论、踩坑记录追加在此处。）

# wg-portal-userspace

带 Web 管理面板的 WireGuard 服务器部署方案，**专门解决内核没有 WireGuard 模块的机器**（典型如群晖 DSM 的 4.4 内核）无法运行 WireGuard 的问题。

`docker compose up -d --build` 一条命令即可拉起全新实例：Web UI 里创建接口/用户、导出客户端配置，隧道由后端容器自动拉起并保持存活；内核有模块走模块，没有模块自动回退 userspace 的 `wireguard-go`。

## 背景 / 为什么有这个项目

上游 [h44z/wg-portal](https://github.com/h44z/wg-portal)（MIT 协议）是优秀的 WireGuard Web 管理面板，但它的隧道管理假定**宿主机内核有 WireGuard 模块**（通过 netlink 建/删 `wireguard` 设备）。在群晖 DSM（内核 4.4，无模块）这类机器上：

- `wg-quick up` 的 `ip link add type wireguard` 返回 `Operation not supported`，wg-portal 保存接口/用户直接报错、事务回滚，Web UI 根本建不出接口；
- 即便绕过去，wg-quick 的 userspace 回退（拉起 `wireguard-go` 子进程）在生产中还有几个坑，本仓库一并修复：
  1. **控制 socket 竞态**：容器 `/run` 里残留的旧 `wg0.sock` 会让 `wg setconf` 打到"哑" daemon（只绑了随机临时端口、没 peer 的进程），配置永远下不去，客户端握手包在服务器上被黑洞；
  2. **`wg setconf` 拒收 wg-quick 专用键**：raw 格式不认 `Address=`/`SaveConfig=`/`MTU=` 等行，必须剥离后再下配；
  3. **NAT 规则重启即丢**：借用 NAS 出口的场景（隧道客户端流量 NAT 成机器自身 IP 再出网）在宿主机重启后 iptables 清空，隧道还在但出网全断。

## 仓库结构

```
├── docker-compose.yml          # 源码构建部署：两容器、host 网络、NET_ADMIN、/dev/net/tun
├── docker-compose.release.yml  # 离线部署：用预构建镜像（固定版本 tag，无 build）
├── config.yml                  # wg-portal 配置（首启 admin 账号、端口、网段、共享目录）
├── backend/                    # 数据面：Dockerfile + wg-watch.sh 看门狗
├── portal/                     # 控制面：wg-portal 源码（含 userspace 补丁 + 完整前端构建）
├── scripts/                    # 维护者脚本（构建并导出离线镜像 tar）
├── data/                       # 运行时生成：SQLite（用户/密钥/peer），勿提交
└── etc-wireguard/              # 运行时生成：隧道 .conf（portal 写、backend 读），勿提交
```

- **wg-portal（控制面）**：Web UI + API，端口 8888。所有状态存 `./data` 的 SQLite；每次变更把 wg-quick 格式配置写到 `/etc/wireguard`（= `./etc-wireguard`）。
- **wireguard / wg-backend（数据面）**：`wg-watch.sh` 监视配置目录，配置变化就**从干净状态重建**（杀旧 daemon、删残留设备与 socket）再拉起隧道，并**验证** daemon 确实监听在配置的 ListenPort（防"哑 daemon"）；每 60s 自检 NAT 规则；支持内核/userspace 双路径自动选择。

### 对上游 wg-portal 的修改（fork 补丁）

1. `internal/adapters/wgcontroller/local.go`（源码内以 `[userspace-fork]` 注释标记）：`LinkAdd`/`LinkDel` 失败（模块缺失）不再回滚整个保存事务——内核操作是"锦上添花"，配置落盘与隧道（由 backend 拉起）才是主体；
2. 前端按上游流程完整构建（vite），避免打包进镜像的前端资产残缺导致控制台 404/TypeError；
3. 其余逻辑与上游一致，欢迎以后游更新为基础 rebase。

## 快速开始

要求：Docker（含 compose 插件）+ `/dev/net/tun` + `NET_ADMIN`。

> 首次构建需要联网：`portal` 镜像会 `npm ci`（前端）+ `go mod download`（后端依赖），`backend` 镜像会 `apt-get install wireguard-go wireguard-tools …`。**不能联网的机器不要用这一节**，直接用「离线部署（预构建镜像）」里的镜像 tar，跳过 build。

```bash
git clone https://github.com/sd133cn/wg-portal-userspace.git && cd wg-portal-userspace

# 1) 按需改 config.yml：
#    - core.admin_password  建议设置自己的密码（留空=内置默认密码）
#    - web.external_url     浏览器访问面板的地址，如 http://<服务器IP>:8888
#    - advanced.start_cidr_v4 / start_listen_port 按需调整
# 2) 借用本机上网（可选）：docker-compose.yml 里 wireguard 服务设置
#    NAT_CIDR=隧道网段(同 start_cidr_v4)、NAT_IFACE=服务器LAN出口网卡
# 3) 构建并启动
docker compose up -d --build
```

然后浏览器打开 `http://<服务器IP>:8888`，用 admin 账号登录：

1. **Interfaces** → 新建接口（如 `wg0`），填 Address（网段网关，如 `10.11.12.1/24`）；
2. **Users** → 为客户端建用户（或直接建 Peer），生成/导出客户端配置；
3. 客户端（手机/WireGuard 官方应用/Windows 等）导入配置，隧道即通；
4. 以后一切增删改都在 Web UI 完成，backend 自动跟随。

### 全新实例会看到什么

- `./data`、`./etc-wireguard` 为空属正常：**首次启动**即自动建库、跑 migration 并创建 `config.yml` 里配置的 admin 账号（日志 `admin user created`），随后开始监听 8888；
- `docker compose logs -f wireguard` 里看 `[wg-watch]` 日志：`kernel module: NOT AVAILABLE (userspace fallback will be used)` 表示走了 userspace，功能完全正常；
- `docker compose logs -f wg-portal` 看面板启动与登录日志。

## 离线部署（预构建镜像，无需联网 / 无需 build）

目标机器**不能联网**时（拿不到 npm / apt / go 依赖，`docker compose up -d --build` 必然失败），直接用 Release 页附带的两个镜像，完全跳过构建：

```bash
# 1) 下载 Release 资产 wg-portal-userspace-images-v1.0.0.tar.gz，载入镜像
gunzip -c wg-portal-userspace-images-v1.0.0.tar.gz | docker load
#    （Windows PowerShell：docker load -i wg-portal-userspace-images-v1.0.0.tar，需先解压）

# 2) 确认镜像已就位（应看到 wg-backend:1.0.0 与 wg-portal:1.0.0）
docker images | findstr wg-          # Linux/macOS: docker images | grep wg-

# 3) 按需改 config.yml（至少设 core.admin_password 与 web.external_url），然后启动
docker compose -f docker-compose.release.yml up -d
```

要点：

- `docker-compose.release.yml` 与 `docker-compose.yml` **只有镜像来源不同**：前者用固定版本的 `image:`（`wg-backend:1.0.0` / `wg-portal:1.0.0`）且没有 `build:`，卷挂载、host 网络、`/dev/net/tun`、`NET_ADMIN`、环境变量完全一致；因此启动后的行为、日志、数据目录位置都与源码构建方式相同。
- Release 里的镜像就是**本仓库这份源码**构建出来的：`wg-portal` 含 userspace fork 补丁与完整的前端构建产物，`wg-backend` 含 `wg-watch.sh` 看门狗。
- 升级/换版本：`docker load` 新版本的 tar，改 `docker-compose.release.yml` 里的 tag，再 `docker compose -f docker-compose.release.yml up -d`。
- 只想把镜像搬到另一台（不经过 Release）：在能联网的机器上 `docker save wg-backend:1.0.0 wg-portal:1.0.0 -o images.tar`，拷过去 `docker load -i images.tar`。

### 维护者：自己重新构建这份镜像 tar

```bash
sh scripts/build-and-save-images.sh 1.0.0     # 产出 dist/wg-portal-userspace-images-v1.0.0.tar.gz
```

> 构建机器必须能联网（见「快速开始」的提示）。**受限网络**（如国内直连 docker.io / deb.debian.org / npmjs / proxy.golang.org 不通）可在构建时改包源，仓库里的 Dockerfile 保持上游原样，改动放在临时副本里即可：
>
> - `backend`：把 `/etc/apt/sources.list.d/debian.sources` 里的 `deb.debian.org` 换成 `mirrors.aliyun.com`。**注意用 `https://` 而不是 `http://`**：本项目的构建验证中发现，部分企业网络会拦截/篡改 80 端口的响应（apt 报 `Clearsigned file isn't valid, got 'NOSPLIT' (does the network require authentication?)`，或索引文件拉一半被 RST），而 443 正常。`debian:bookworm-slim` 里没有 `ca-certificates`，所以首次 `apt-get` 需临时关掉 TLS 校验并随即把 `ca-certificates` 装进镜像：`apt-get update -o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false`（包的真实性仍由 apt 的 GPG 签名保证）；
> - `portal` 前端：`npm config set registry https://registry.npmmirror.com`（并把 `package-lock.json` 里的 `registry.npmjs.org` 一并替换）；
> - `portal` 后端：`go env -w GOPROXY=https://goproxy.cn,direct`；
> - `portal` 终像：把 `/etc/apk/repositories` 里的 `dl-cdn.alpinelinux.org` 换成 `mirrors.aliyun.com`。
>
> 注意：这样构建出的镜像与用原版源构建的镜像**内容等价**，只是拉取依赖的地址不同。

## 使用限制（userspace 模式）

- **Web UI 上看不到 peer 的实时握手/流量状态**：userspace daemon 的实时状态只在进程内存里，netlink 查询不到（`file does not exist`），这是 4.4 无模块内核的硬限制；若安装发行版提供的 WireGuard 内核模块（如群晖官方 WireGuard 包）则自动恢复且走内核路径，UI 状态完整。
- 服务器端与客户端**同跑**在同一台 Linux 机器上时，两端 userspace 也可以互通，但性能低于内核路径。
- 客户端侧不受此限制：Windows 官方客户端自带 userspace/模块双支持。

## 备份与迁移

只需带三样东西即可在新机器完整恢复（含所有客户端密钥，客户端无需重配）：

```bash
docker save wg-backend:latest wg-portal:latest -o images.tar
tar czf state.tar.gz data etc-wireguard config.yml
```

（镜像 tag 取决于你当初怎么装的：源码构建方式是 `:latest`，离线部署的 Release 镜像是 `:1.0.0`，`docker images` 里照实际 tag 写。）

（只带镜像不带 `data/`+`etc-wireguard/` 则是全新空实例：无账号、无 peer，已配过的客户端全部失效。）

## 安全

- `data/` 内含全部隧道私钥，`etc-wireguard/` 内含服务端私钥：**永远不要**提交进 git 或随意拷贝（`.gitignore` 已排除）；
- 面板监听 `0.0.0.0:8888`（容器用 host 网络）：**默认没有 TLS、也没有来源限制**，如要暴露到不可信网络，请自行加反向代理+TLS 或防火墙限制来源 IP；
- 本仓库为 MIT 协议（根目录 `LICENSE`）；本项目是上游 wg-portal 的衍生作品，`NOTICE` 与 `portal/LICENSE.txt` 保留原作者 Christoph Haas 的版权信息。

## 致谢 / 上游

- [h44z/wg-portal](https://github.com/h44z/wg-portal) —— 本项目的基础（MIT）
- [wireguard](https://www.wireguard.com/) 及其 Go 实现

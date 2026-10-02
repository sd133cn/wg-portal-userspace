# portal/ 的上游来源与版本（pin）

`portal/` 不是本项目的原创代码，而是上游 [h44z/wg-portal](https://github.com/h44z/wg-portal) 的源码快照（MIT 协议，`portal/LICENSE.txt` 原样保留），外加**本项目的一处 userspace 补丁**（见 README「对上游 wg-portal 的修改」）。

<!-- 机器可读：scripts/check-upstream.sh 与 scripts/build-and-save-images.sh 会读下面这几行，改格式需同步改脚本 -->
upstream_repo: h44z/wg-portal
upstream_branch: master
upstream_ref: eb44c8c4ff120f34c26b2415c47560f4fba0603c
upstream_ref_date: 2026-09-13T19:56:05Z

| 项 | 值 |
| --- | --- |
| 上游仓库 | `https://github.com/h44z/wg-portal` |
| 分支 | `master` |
| commit | `eb44c8c4ff120f34c26b2415c47560f4fba0603c` |
| commit 日期 | 2026-09-13T19:56:05Z |
| commit 标题 | `chore(deps): bump the actions group across 1 directory with 10 updates (#722)` |
| 本仓库快照日期 | 2026-10-02 |
| 上游协议 | MIT（`portal/LICENSE.txt` 原样保留） |

> **为什么钉 commit 而不是版本号**：上游最新 Release 是 `v2.3.1`（2026-06-12），而本快照取自比它更新的 `master`，因此没有可引用的 tag —— 只能钉 commit SHA。

## 本仓库对上游的改动（全量核对结果）

把上游该 commit 的 tarball（`https://codeload.github.com/h44z/wg-portal/tar.gz/eb44c8c4ff120f34c26b2415c47560f4fba0603c`，3,847,119 字节，sha256 `249e3bd41b0e5df12e72fbe2dfc4071e5af340dcc42c988941b229e5f2760b39`，397 个 git 跟踪文件）与本仓库 `portal/` 逐文件比对，结果是：

| 类别 | 数量 | 说明 |
| --- | --- | --- |
| 内容完全一致 | 318 | — |
| **内容不同** | **1** | `internal/adapters/wgcontroller/local.go` —— 本项目唯一的代码改动（`[userspace-fork]` 标记：内核接口/peer 操作失败不再让整个保存事务回滚，源码里共 12 处 `userspace-fork` 标记） |
| 上游有、本仓库有意不收录 | 78 | 见下表（CI / 部署示例 / 文档 / 开发容器等，构建与运行都不需要） |
| 本仓库有、上游没有 | 186 | `internal/app/api/core/frontend-dist/` 前端构建产物：上游 `.gitignore` 排除，由 `portal/Dockerfile` 构建时生成，本仓库同样不提交。此外 `portal/UPSTREAM.md`（本文件）也是上游没有的 |

即：**除 `local.go` 这一处补丁外，`portal/` 与上游该 commit 逐字节一致**，没有夹带其它改动。

### 有意不收录的 78 个文件

| 路径 | 文件数 | 不收录的原因 |
| --- | --- | --- |
| `docs/` | 40 | 上游 MkDocs 文档站（含图片、`swagger.yaml`）；本项目文档在 README |
| `deploy/helm/` | 21 | 上游 Helm chart；本项目用 docker compose |
| `.github/` | 9 | 上游 CI（`docker-publish.yml` 会向 Docker Hub 推镜像）、issue 模板、dependabot |
| `.run/` | 3 | JetBrains 运行配置 |
| `scripts/wg-portal.service` | 1 | 上游 systemd 单元（裸机安装用） |
| `docker-compose.yml` | 1 | 上游自己的 compose，与本仓库根目录同名文件冲突 |
| `ct.yaml` | 1 | chart-testing 配置（配合上游 CI） |
| `Makefile` | 1 | 上游构建入口（本项目用两份 Dockerfile + compose） |
| `mkdocs.yml` | 1 | 上游文档站配置 |

## 校验证据（可复验）

**方式一（推荐，一条命令）** —— 漂移检测脚本会拉上游 tarball 与 `portal/` 逐文件比对，预期结果是上面那张表（只剩 `local.go` 一处补丁差异）：

```bash
sh scripts/check-upstream.sh            # 与钉住的 commit 比对（应只见 local.go）
sh scripts/check-upstream.sh master     # 与上游最新 master 比对（用来看上游有没有新提交）
```

**方式二（不联网，抽查关键文件）** —— `git hash-object` 得到的 blob SHA-1 与上游该 commit 的记录一致，即内容逐字节相同：

| 文件 | blob SHA-1 |
| --- | --- |
| `portal/go.mod` | `d3bb1f5c9dedb1aecbf7a5d94ff65c025bef557f` |
| `portal/go.sum` | `c36981d710c213d8a32645c59079f4ea8ff9eb8a` |
| `portal/internal/version.go` | `4ff18a07df35a3766f887852e43070e1abe2ad73` |
| `portal/frontend/package-lock.json` | `62e4e4f512844fb82f24a8da37298a6c23d26877` |
| `portal/Dockerfile` | `82553f2f100b2e55b812949d7cf06dcffbec53e1` |
| `portal/README.md` | `c7eda8dd41343bdad13f6a8d073feb34a61fc029` |
| `portal/SECURITY.md` | `0ffebd752849e5693603f38d4578339eb2496329` |

```bash
git hash-object portal/go.mod     # 应输出 d3bb1f5c9dedb1aecbf7a5d94ff65c025bef557f
sh scripts/check-upstream.sh      # 更彻底：整个 portal/ 对着上游逐文件比
```

## 上游有变动时怎么跟进（rebase）

1. **先看上游动了什么**：`sh scripts/check-upstream.sh master`，输出里「内容不同」= 上游改了我们保留的文件，「只在上游有」= 上游新增的文件；
2. **重点看**：`internal/adapters/wgcontroller/`、`internal/adapters/wgquick/`（本项目补丁落在这块）、依赖与安全（`go.mod`、`go.sum`、`frontend/package-lock.json`）；
3. **搬运**：把上游该 ref 的源码覆盖进 `portal/`，**保留** `portal/LICENSE.txt`，并重新审一遍 `local.go` 的 `[userspace-fork]` 补丁是否仍然需要（上游若已合并等价改动就删掉本地补丁）；
4. **更新本文件**：改顶部 `upstream_ref` / `upstream_ref_date` 与两张表，并重跑 `sh scripts/check-upstream.sh` 确认「内容不同」仍是预期的那些文件；
5. **重新构建并验证**：
   ```bash
   docker compose up -d --build
   docker compose logs -f wireguard     # 期望：[wg-watch] wg0: UP and verified (listening port 51820, N peer(s))
   ```
6. **发新版本**：`sh scripts/build-and-save-images.sh <新版本号>`（镜像会带上 `org.opencontainers.image.revision` = 本文件里的上游 commit）。

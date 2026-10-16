# sb - sing-box 节点管理脚本

交互式的 [sing-box](https://github.com/SagerNet/sing-box) 一键部署与管理脚本，安装后通过 `sb` 命令使用。支持多协议共存，可以新增、修改、删除节点，查看运行状态和日志。

## 特性

- **支持协议**：VLESS+Reality、VLESS+WS+TLS、Hysteria2、TUIC v5、AnyTLS
- **端口**：自定义，默认在 20000-60000 随机；监听端口与对外端口分开设置，适配 NAT 小鸡
- **Reality**：Flow（`xtls-rprx-vision`）可选开启或关闭；SNI 支持多轮并发测速优选，展示平均握手耗时与成功率，按排名选择或手动输入，并检测 TLS 1.3、h2 和证书有效性
- **证书**：
  - DNS-01 自动申请（acme.sh，内置 Cloudflare / 阿里云 / DNSPod，也可填写其他 acme.sh DNS 插件），无需 80/443 端口，适合 NAT 机器
  - sing-box 内置 ACME（HTTP-01 / TLS-ALPN-01，需要公网 80 或 443）
  - 手动指定证书文件（自动校验证书与私钥是否匹配、域名是否匹配）
  - 自签证书（无域名或测试用）
- **节点管理**：新增、查看、修改、删除；每个协议一个独立配置文件，互不影响
- **安全变更**：每次修改前自动快照，`sing-box check` 校验通过后才重启，失败自动回滚
- **输出**：分享链接、终端二维码（需 `qrencode`）、客户端 outbound JSON，并保存到 `/etc/sing-box/nodes.txt`
- **系统**：Debian / Ubuntu / CentOS / Alma / Rocky / Alpine，支持 systemd 与 OpenRC
- **架构**：amd64、arm64、armv7、386
- **旧配置兼容**：检测到已有的 `/etc/sing-box/config.json` 时，可选择备份后接管，或保留旧配置只管理新增节点

## 一键安装

需要 root 用户。把下面命令中的 `Jonathan143/sb-install` 换成你的 GitHub 仓库路径（脚本文件名为 `sb.sh`，分支为 `main`）。

```bash
curl -fsSL -o /usr/local/bin/sb https://raw.githubusercontent.com/Jonathan143/sb-install/main/sb.sh && chmod +x /usr/local/bin/sb && SCRIPT_URL=https://raw.githubusercontent.com/Jonathan143/sb-install/main/sb.sh sb
```

安装完成后，以后直接输入 `sb` 即可打开菜单。

也可以不落盘，直接运行（脚本会自动把自己安装为 `sb` 命令）：

```bash
SCRIPT_URL=https://raw.githubusercontent.com/Jonathan143/sb-install/main/sb.sh bash <(curl -fsSL https://raw.githubusercontent.com/Jonathan143/sb-install/main/sb.sh)
```

### 国内或无法直连 GitHub 的机器

给下载地址加上加速前缀，同时设置 `GH_PROXY`，让内核也走加速下载（以下前缀仅为示例，请自行替换为可用的加速服务）：

```bash
export GH_PROXY=https://ghfast.top/
curl -fsSL -o /usr/local/bin/sb ${GH_PROXY}https://raw.githubusercontent.com/Jonathan143/sb-install/main/sb.sh && chmod +x /usr/local/bin/sb && SCRIPT_URL=${GH_PROXY}https://raw.githubusercontent.com/Jonathan143/sb-install/main/sb.sh sb
```

> `GH_PROXY` 只对本次运行生效。之后如需更新内核，可以再次 `export` 后执行 `sb core`。

## 使用方法

直接运行 `sb` 进入交互菜单，也可以使用子命令：

| 命令 | 功能 |
|---|---|
| `sb` | 主菜单 |
| `sb add` | 新增节点 |
| `sb list` | 列出所有节点和监听状态 |
| `sb info [编号]` | 查看分享链接、二维码、客户端 outbound JSON |
| `sb edit [编号]` | 修改端口、SNI/证书、Flow、UUID/密码、连接地址、备注等 |
| `sb del [编号]` | 删除节点（同时关闭防火墙端口，可选清理证书） |
| `sb status` | 服务状态、内核版本、节点监听、证书到期时间 |
| `sb log [-f]` | 查看日志，`-f` 实时跟踪 |
| `sb start` / `stop` / `restart` | 服务控制（启动和重启前会先校验配置） |
| `sb cert` | 查看证书到期时间，强制续期 |
| `sb core` | 安装或更新 sing-box 内核 |
| `sb update` | 更新 sb 脚本本身 |
| `sb uninstall` | 卸载 |

在主菜单选择「9 → 2」更新脚本成功后，按回车会直接重新运行新版 `sb`。使用 `sb update` 命令则在更新完成后退出。
主菜单也会检查正在运行与磁盘安装的脚本版本；版本不一致时会显示两个版本，并提示按回车重新加载。已经运行的旧版脚本需先退出并重新运行一次，才能启用此检查。

## 协议与证书说明

| 协议 | 传输 | 需要证书 |
|---|---|---|
| VLESS + Reality | TCP | 否 |
| VLESS + WS + TLS | TCP | 是 |
| Hysteria2 | UDP | 是 |
| TUIC v5 | UDP | 是 |
| AnyTLS | TCP | 是（需要 sing-box 1.12+） |

### NAT 小鸡注意事项

- **证书**：没有 80/443 端口时，请选择「DNS-01」方式，只需要 DNS 服务商的 API 凭据。
- **端口**：NAT 机器通常是「内部端口 → 外部端口」映射。脚本会分别询问监听端口和对外端口，分享链接使用对外端口。如果商家只给了固定端口段，可以在端口提示处输入 `起-止` 修改随机范围。
- **UDP**：Hysteria2 和 TUIC 使用 UDP，部分商家需要在面板中单独映射 UDP 端口。
- **连接地址**：自动检测到的 IP 可能是共享出口，添加节点时可以手动改成域名或正确的 IP。
- **WS + CDN**：如果要经 Cloudflare CDN，对外端口必须是 443、2053、2083、2087、2096、8443 之一。

### Reality SNI 域名优选

新增 Reality 节点，或执行 `sb edit` 修改 Reality 节点的 SNI 时，默认进入「域名优选」，也可以直接选择手动输入。

- 使用内置候选列表；修改节点时也会测试当前 SNI，并在结果中标记「当前」。
- 最多同时测试 4 个域名，每个域名测试 3 次，单次超时 2 秒。每轮都检查 TLS 1.3、h2、证书信任与域名匹配。
- 连续 3 次通过的域名按平均连接及 TLS 握手耗时升序排名，第一名标记「推荐」。输入排名选择，或回车使用第一名；部分成功及失败结果单独标明，不参与推荐。
- 输入 `r` 重新测试、`m` 手动选择/输入、`0` 取消。手动域名检测失败时，只有明确确认后才会使用。

测速从运行脚本的服务器发起，包含域名解析和连接开销，仅反映当时服务器到目标站点的表现，不代表客户端连接节点的延迟或下载速度。目标站返回 HTTP 403/404 不影响检测，因为测试只建立 TLS 连接。优选需要 `timeout` 和毫秒计时支持（Bash 5 或支持 `%3N` 的 `date`）；缺少 `timeout` 时安装流程会尝试安装 `coreutils`。

### 证书申请凭据

DNS-01 申请前会检查 Let's Encrypt 的 ACME 目录连接，申请时显式指定完整 CA URL，避免 CA 别名或旧默认配置异常。CA 初始化失败、Cloudflare API 连接/授权失败和 DNS 记录操作失败会分别提示。

选择 Cloudflare 时，会先验证 Token 处于 `active` 状态，再逐级查找域名所属 Zone，确认 Token 可以读取该 Zone。支持用户级 Token；账户级 Token 需要填写 `CF_Account_ID`。预检查只读取 API，不修改 DNS，也不代表已确认 DNS 编辑权限；创建验证 TXT 记录仍需 `Zone-DNS-Edit`，查询 Zone 需 `Zone-Zone-Read`。验证失败会停止申请，Token 不会出现在预检查日志或 curl 命令参数中。其他 DNS 服务商仍由 acme.sh 插件校验凭据。

使用 DNS-01 时，acme.sh 会把 DNS API 凭据保存在 `~/.acme.sh/account.conf` 中用于自动续期，请妥善保管服务器权限。续期成功后会自动重启 sing-box。

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/sb` | 管理脚本 |
| `/usr/local/bin/sing-box` | sing-box 内核 |
| `/etc/sing-box/conf.d/` | 节点配置，每个节点一个 JSON 文件 |
| `/etc/sing-box/meta/` | 节点元数据，用于查看和修改节点 |
| `/etc/sing-box/certs/<域名>/` | 证书（`fullchain.pem`、`key.pem`） |
| `/etc/sing-box/backup/` | 变更前的配置快照，保留最近 10 份 |
| `/etc/sing-box/nodes.txt` | 所有节点的分享链接 |
| `/etc/sing-box/sb.conf` | 脚本设置 |

## 常见问题

**提示另一个 sb 实例正在运行？**
脚本会显示持锁进程的 PID、命令，以及系统支持时的父进程、用户和运行时长。在交互终端中，确认目标是唯一的 sb 管理进程后，可以选择终止它并继续，默认不终止。终止前会再次验证进程身份，发送 TERM 后最多等待 5 秒，取得锁才继续启动。

终止管理进程可能中断正在执行的操作。非交互调用、无法确认进程身份或锁仍被子进程占用时，会退出并提示手动处理；不会强制杀死进程、停止 sing-box 服务或删除锁文件。

**内核提示 `cannot execute: required file not found`？**
文件存在时，这通常表示内核所需的动态加载器缺失，例如在 Alpine/musl 系统上使用了不匹配的构建。v1.0.1 起会识别 musl、尝试兼容构建，并在替换旧内核前实际执行 `version` 验证；失败会保留原内核并返回错误。

先将服务器上的 `sb` 更新为修复后的脚本，再运行 `sb`，检测到不可用内核后确认重新安装即可。也可使用 `sb core` 手动安装。仅更新内核、继续使用旧脚本不会获得这些检测和保护。

**客户端导入链接失败？**
`anytls://` 和 `tuic://` 的 URI 格式在各客户端之间并不完全统一。导入失败时，请使用 `sb info` 输出的 sing-box outbound JSON。

**Reality 的 SNI 检测全部不通过？**
检测需要服务器能访问目标站点的 443 端口，且本机 OpenSSL 支持 TLS 1.3、系统时间和 CA 证书正常。全部失败时不会自动选中域名，可重测、手动输入其他域名或取消；修改节点时取消会保留原配置。

**如何更换 Reality 的 SNI 或开关 Flow？**
执行 `sb edit`，选择对应节点和选项即可，修改后自动校验并重启。

**修改后服务启动失败？**
脚本会自动回滚到修改前的配置。详细原因可以用 `sb log` 查看。

**Hysteria2 端口跳跃？**
暂不支持。

## 卸载

```bash
sb uninstall
```

可以选择是否保留 `/etc/sing-box` 下的配置和证书，以及是否同时卸载 acme.sh。

## 版本发布（维护者）

版本号统一维护在 `sb.sh` 的 `SB_VERSION` 中，Git 标签格式为 `vX.Y.Z`。在 `main` 分支提交好全部修改后运行：

```bash
bash scripts/release.sh
```

脚本提供补丁版本、次版本、主版本、自定义版本，以及「发布当前版本」选项。例如当前是 `1.0.1` 时，分别可选择 `1.0.2`、`1.1.0`、`2.0.0`；首次发布现有修复可选择「发布当前版本」。目前仅支持 `X.Y.Z` 稳定版本。

发布前会同步远程标签、检查分支和版本、运行测试。确认后自动修改 `SB_VERSION`（如果需要）、提交版本变更、创建附注标签，并原子推送 `main` 和标签到 `origin`。本地已有但尚未推送的提交也会一并推送，确认前会显示列表。需要本地 Git 已配置提交身份，并拥有仓库推送权限。

- `.github/workflows/ci.yml`：在 `main` 推送或 Pull Request 时检查 Bash 语法和回归测试。
- `.github/workflows/release.yml`：推送 `v*` 标签时，验证标签与脚本版本一致、提交属于 `main`，测试通过后创建 GitHub Release，上传 `sb.sh` 和 `SHA256SUMS`。
- `.github/release.yml`：按 PR 标签归类自动生成的发布说明；直接提交的变更可通过完整变更链接查看。

仓库需启用 GitHub Actions；发布任务使用内置 `GITHUB_TOKEN` 的 `contents: write` 权限，无需额外配置 PAT。若组织策略或分支保护禁止推送/发布，需要按仓库规则处理。首次发布前需将上述工作流和脚本一并提交。

推送失败时，脚本保留本地提交和标签，并输出重试命令；不要直接重复创建同一版本。若推送成功但 Actions 失败，修复环境问题后可在 Actions 页面重新运行失败任务。若标签推送未触发工作流，可在 Actions → Release → Run workflow 中选择 main 并填写已有标签（如 `v1.0.1`），从该标签发布。已成功发布的同名 Release 不会被覆盖；代码修正应发布新版本。

本地检查命令：

```bash
bash scripts/check.sh
```

### 从 Release 安装

首次 Release 成功后，可以使用最新稳定版地址安装，后续 `sb update` 也会使用此地址：

```bash
SCRIPT_URL=https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh
curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/sb && chmod +x /usr/local/bin/sb && SCRIPT_URL="$SCRIPT_URL" sb
```

固定版本可使用 `https://github.com/Jonathan143/sb-install/releases/download/v1.0.1/sb.sh`（替换为实际已发布版本）；固定版本地址不会自动跟随最新版。原先的 `main` 安装地址仍可使用，获取的是分支上的代码。

## 免责声明

本项目仅供学习和技术交流使用，请遵守所在地区的法律法规，作者不对使用本脚本产生的任何后果负责。

## 致谢

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)
- [harenaNow/SNI-TLS-test](https://github.com/harenaNow/SNI-TLS-test)（SNI 多轮测速与排序思路参考）

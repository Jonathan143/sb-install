# sb - sing-box 节点管理脚本

交互式的 [sing-box](https://github.com/SagerNet/sing-box) 一键部署与管理脚本，安装后通过 `sb` 命令使用。支持多协议共存，可以新增、修改、删除节点，查看运行状态和日志。

## 特性

- **支持协议**：VLESS+Reality、VLESS+WS+TLS、Hysteria2、TUIC v5、AnyTLS、AnyTLS+Reality、Shadowsocks
- **端口**：自定义，默认在 20000-60000 随机；监听端口与对外端口分开设置，适配 NAT 小鸡
- **Reality**：Flow（`xtls-rprx-vision`）可选开启或关闭；SNI 支持多轮并发测速优选，展示平均握手耗时与成功率，按排名选择或手动输入，并检测 TLS 1.3、h2 和证书有效性
- **Hysteria2 端口跳跃**：商家/NAT 已配置 UDP 转发时，可设置对外端口范围及跳跃间隔，输出 sing-box / Mihomo 客户端配置
- **多路复用**：VLESS+Reality / VLESS+WS+TLS 可开启 multiplex，自动生成服务端和 sing-box 客户端配置，并显示 mihomo `smux` 配置片段；与 Reality Flow 互斥
- **证书**：
  - DNS-01 自动申请（acme.sh，内置 Cloudflare / 阿里云 / DNSPod，也可填写其他 acme.sh DNS 插件），无需 80/443 端口，适合 NAT 机器
  - sing-box 内置 ACME（HTTP-01 / TLS-ALPN-01，需要公网 80 或 443）
  - 手动指定证书文件（自动校验证书与私钥是否匹配、域名是否匹配）
  - 自签证书（无域名或测试用）
- **出口与分流**：粘贴 VLESS / Shadowsocks 链接添加落地出口，按域名或 IP/CIDR 分流，支持规则排序、启停及出口连通性检测
- **节点管理**：新增、查看、修改、删除；每个协议一个独立配置文件，互不影响
- **安全变更**：修改前快照配置、节点元数据和托管证书；备份失败则取消操作。`sing-box check` 校验通过后才重启，重启和运行状态检查失败时回滚；恢复时先在临时目录解压验证，损坏快照不会删除现有配置
- **输出**：分享链接、终端二维码（需 `qrencode`）、客户端 outbound JSON，并保存链接到 `/etc/sing-box/nodes.txt`；Shadowsocks 额外输出 Mihomo YAML。AnyTLS+Reality 仅输出客户端 JSON，链接文件中记录配置获取提示
- **系统 DNS**：查看当前配置，选择 `1.1.1.1` / `8.8.8.8` 或手动输入 IPv4 / IPv6 地址，支持备份恢复
- **系统**：Debian / Ubuntu / CentOS / Alma / Rocky / Alpine，支持 systemd 与 OpenRC
- **架构**：amd64、arm64、armv7、386
- **旧配置兼容**：检测到已有的 `/etc/sing-box/config.json` 时，可选择备份后接管，或保留旧配置只管理新增节点

## 一键安装

需要 root 用户。把下面命令中的 `Jonathan143/sb-install` 换成你的 GitHub 仓库路径（需已发布含独立 `sb.sh` 的 Release）。

```bash
curl -fsSL -o /usr/local/bin/sb https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh && chmod +x /usr/local/bin/sb && SCRIPT_URL=https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh sb
```

安装完成后，以后直接输入 `sb` 即可打开菜单。

也可以不落盘，直接运行（脚本会自动把自己安装为 `sb` 命令）：

```bash
SCRIPT_URL=https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh bash <(curl -fsSL https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh)
```

### 国内或无法直连 GitHub 的机器

给下载地址加上加速前缀，同时设置 `GH_PROXY`，让内核也走加速下载（以下前缀仅为示例，请自行替换为可用的加速服务）：

```bash
export GH_PROXY=https://ghfast.top/
curl -fsSL -o /usr/local/bin/sb ${GH_PROXY}https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh && chmod +x /usr/local/bin/sb && SCRIPT_URL=${GH_PROXY}https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh sb
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
| `sb edit [编号]` | 修改端口、SNI/证书、Flow、multiplex、UUID/密码、连接地址、备注等 |
| `sb del [编号]` | 删除节点（同时关闭防火墙端口，可选清理证书） |
| `sb status` | 服务状态、内核版本、节点监听、证书到期时间 |
| `sb log [-f]` | 查看日志，`-f` 实时跟踪 |
| `sb start` / `stop` / `restart` | 服务控制（启动和重启前会先校验配置） |
| `sb dns` / `sb dns show` | 修改 / 查看系统 DNS |
| `sb route` / `sb route show` | 出口与分流管理 / 查看规则（凭据隐藏） |
| `sb cert` | 查看证书到期时间，强制续期 |
| `sb core` | 安装或更新 sing-box 内核 |
| `sb update` | 更新 sb 脚本本身 |
| `sb uninstall` | 卸载 |

在主菜单选择「11 → 2」更新脚本成功后，按回车会直接重新运行新版 `sb`。使用 `sb update` 命令则在更新完成后退出。
更新会检查文件非空、版本号、Bash 语法和独立脚本结构；Release 下载地址还必须通过同目录 `SHA256SUMS` 校验。下载、校验或安装失败会保留原命令。自定义下载地址需提供完整的独立构建产物。
主菜单也会检查正在运行与磁盘安装的脚本版本；版本不一致时会显示两个版本，并提示按回车重新加载。已经运行的旧版脚本需先退出并重新运行一次，才能启用此检查。

最新版更新与指定版本安装都先备份内核和配置，再校验配置、重启并确认服务运行；失败会恢复原内核和配置，并尝试恢复更新前的服务状态。内置 ACME 配置会随目标内核版本重新生成：1.14+ 使用 `tls.certificate_provider`，较旧版本保留 `tls.acme`，共存模式的旧 `config.json` 不会被改写。迁移格式见 [sing-box 官方迁移说明](https://sing-box.sagernet.org/migration/#migrate-inline-acme-to-certificate-provider)。

## 出口与域名/IP 分流

运行 `sb route`，或主菜单选择 **13 → 出口与分流**：

1. 选择「粘贴链接新增出口」，粘贴完整 `vless://...` 或 `ss://...` 链接（输入隐藏），检查解析摘要并命名。
2. 选择「新增规则」，填写精确域名、域名后缀或 IP/CIDR，多个值用英文逗号分隔，再选择出口标识。
3. 规则从上到下首条命中生效；可以编辑、启停、移动和删除。未命中默认本机直连，也可更改默认出口。

例如 `example.com` 的域名后缀规则会同时匹配根域和子域；IP 支持 IPv4、IPv6 和 CIDR，单个地址自动转换成 `/32` 或 `/128`。不要填写 URL、`*.` 或前导点。规则作用于全部脚本管理的入口，新建入口自动纳入；不改变客户端分享链接。指定出口故障时连接失败，不自动回退直连。

**链接支持范围**：VLESS 的 TCP、WebSocket、gRPC、HTTP 传输，以及无 TLS、TLS、Reality；识别 UUID、Flow、SNI、指纹、ALPN、公钥、short ID、路径、Host 和 serviceName。Flow 仅支持与 TCP + TLS/Reality 配合的 `xtls-rprx-vision`。Shadowsocks 支持 SIP002、URL-safe Base64 认证及旧式整段 Base64 链接，加密方式为 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`，以及 SS2022 的 AES-128、AES-256、ChaCha20（单用户密钥）。暂不支持插件、XHTTP、TCP HTTP 伪装、SS2022 多用户密钥链和非默认 Reality spiderX。不支持的参数或组合会拒绝导入，不静默丢弃。

更新出口时重新粘贴链接即可，出口标识和规则引用保持不变。仍被规则（包括停用规则）或默认出口引用的出口不能删除。列表与解析摘要不展示密码、UUID 或完整链接；凭据保存在权限为 `600` 的 `meta/routing.json` 和 `conf.d/00-egress.json` 中，随现有快照备份/回滚。

**DNS 与嗅探**：需要 sing-box **1.12.0+**。客户端传入域名时直接匹配；仅传入 IP 时尝试 TLS/HTTP/QUIC 嗅探（不改写目标），无法保证识别所有流量。遇到第一条启用的 IP 规则前，使用服务器的系统 DNS 解析域名，再按 IP 匹配；落地地址也使用系统 DNS。建议把域名规则排在 IP 规则前面。该功能不接管客户端 DNS，也不保证 DNS 请求经过落地。

共存模式下，若原 `config.json` 已有路由规则，会拒绝启用本功能，以免合并规则的优先级产生歧义；请先整合原有规则或采用接管配置。没有已有路由规则时，新规则仅匹配托管入口，并保留原全局默认路由。

每次保存都会校验配置并重启服务，失败则恢复变更前的配置。配置校验不代表网络可达；「检测出口连通性」启动独立的本地检测进程，通过所选出口访问 `https://api.ipify.org` 并显示出口 IP，不修改生产服务。该检测验证 HTTPS/TCP，不代表所有目标或 UDP 均可用。

## 协议与证书说明

| 协议 | 传输 | 需要证书 |
|---|---|---|
| VLESS + Reality | TCP | 否 |
| VLESS + WS + TLS | TCP | 是 |
| Hysteria2 | UDP | 是 |
| TUIC v5 | UDP | 是 |
| AnyTLS | TCP | 是（需要 sing-box 1.12+） |
| AnyTLS + Reality | TCP | 否（需要 sing-box 1.12+；Mihomo 不支持此组合） |
| Shadowsocks | TCP + UDP | 否 |

### AnyTLS + Reality

新增节点菜单选择 `6`，使用密码认证，自动生成 Reality 密钥对和 short ID，并复用 SNI 域名优选。无需申请证书，不提供 VLESS Flow 或 sing-mux 开关。已有的普通 AnyTLS 节点保持独立。

`sb info` 输出含 SNI、uTLS 指纹、Reality 公钥和 short ID 的 sing-box outbound JSON。由于尚未验证可跨客户端使用的分享 URI，此组合不生成分享链接或二维码；`nodes.txt` 会提示运行 `sb info` 获取配置。

**Clash Verge Rev / Mihomo 不支持 AnyTLS + Reality**，参见 [Mihomo 官方说明](https://wiki.metacubex.one/config/proxies/anytls/)。Mihomo 用户可以使用已有的普通 AnyTLS 或 VLESS+Reality 节点。Shadowrocket 等其他客户端需另行确认所用版本是否支持此组合及配置字段；不承诺通用链接导入，不输出 Loon 配置。

### Shadowsocks

新增节点菜单选择 `7`。支持以下加密方式，每个节点使用一个密码或密钥：

| 加密方式 | 凭据 |
|---|---|
| `chacha20-ietf-poly1305`（默认，兼容优先） | 自动生成随机密码 |
| `aes-128-gcm` | 自动生成随机密码 |
| `aes-256-gcm` | 自动生成随机密码 |
| `2022-blake3-aes-128-gcm` | 自动生成 16 字节随机密钥，使用 Base64 编码 |

提供 SIP002 `ss://` 链接、二维码、sing-box outbound JSON 和 Mihomo YAML。SS2022 需要客户端版本支持所选算法，分享链接使用 SIP002 的 AEAD-2022 编码规则；若客户端无法导入，可使用配置输出或手动填写参数。为兼顾 Clash Verge Rev / Mihomo、sing-box、Shadowrocket 和 Loon，默认选择传统 AEAD 算法。

监听和防火墙同时处理 TCP、UDP；NAT 机器需要将两种协议映射到同一个对外端口。节点状态只有在 TCP、UDP 均监听时才显示运行。

`sb edit` 的选项 `2` 修改加密方式并生成新凭据，选项 `4` 重新生成当前算法的密码或密钥；修改后需同步更新客户端。不提供插件、额外 TLS 或 sing-mux 设置。

### NAT 小鸡注意事项

- **证书**：没有 80/443 端口时，请选择「DNS-01」方式，只需要 DNS 服务商的 API 凭据。
- **端口**：NAT 机器通常是「内部端口 → 外部端口」映射。脚本会分别询问监听端口和对外端口，分享链接使用对外端口。如果商家只给了固定端口段，可以在端口提示处输入 `起-止` 修改随机范围。
- **UDP**：Hysteria2 和 TUIC 使用 UDP，部分商家需要在面板中单独映射 UDP 端口。
- **连接地址**：自动检测到的 IP 可能是共享出口，添加节点时可以手动改成域名或正确的 IP。
- **WS + CDN**：如果要经 Cloudflare CDN，对外端口必须是 443、2053、2083、2087、2096、8443 之一。

### Reality SNI 域名优选

主菜单选择「5 · SNI 优选测试」可独立测试内置候选域名，展示分类、排名、平均握手耗时和成功率，不修改节点配置。

新增 Reality 节点，或执行 `sb edit` 修改 Reality 节点的 SNI 时，默认进入「域名优选」，也可以直接选择手动输入。

- 检测范围可选「快速检测」（默认，10 个）或「检测全部」（26 个），不设分类选择菜单。进度、结果和手动候选列表显示「日本高校」「Linux 镜像」等分类；未收录的域名显示「自定义域名」。
- 快速候选为 `www.u-tokyo.ac.jp`、`www.nus.edu.sg`、`www.stanford.edu`、`www.ox.ac.uk`、`dl-cdn.alpinelinux.org`、`www.python.org`、`pypi.org`、`addons.mozilla.org`、`www.lovelive-anime.jp`、`www.cathaypacific.com`。全部候选还包含其他高校、Debian、Rust、Ruby、Perl 和 Homebrew 域名。
- 修改节点时，无论选择哪种范围，都会补测当前 SNI 并在结果中标记「当前」；已在候选中的域名不重复检测，因此快速检测最多会测 11 个域名。
- 选择检测范围后可交互输入并发数（1–4，回车默认 4，`0` / `q` 取消）。也可通过 `SNI_CONCURRENCY=2 sb` 调整输入框默认值。资源受限时可选择 1 或 2。每个域名测试 3 次，单次超时 2 秒，另设 1 秒强制结束宽限。测试会显示逐域名进度；检测到 cgroup v2 进程额度不足时自动降低并发，无法启动单路检测时停止并提示。每轮都检查 TLS 1.3、h2、证书信任与域名匹配。
- 连续 3 次通过的域名按平均连接及 TLS 握手耗时升序排名，第一名标记「本轮最快」。节点选择时输入排名，或回车使用第一名；部分成功及失败结果单独标明，不参与排名。
- 结果页输入 `r` 按本次范围和并发数重测、`s` 切换范围并调整并发数、`0` / `q` 返回。节点选择时还可输入 `m` 手动选择/输入；手动域名检测失败时，只有明确确认后才会使用。

测速从运行脚本的服务器发起，包含域名解析和连接开销，仅反映当时服务器到目标站点的表现，不代表客户端连接节点的延迟或下载速度。目标站返回 HTTP 403/404 不影响检测，因为测试只建立 TLS 连接。优选需要 GNU `timeout` 和毫秒计时支持（Bash 5 或支持 `%3N` 的 `date`）；安装流程会检查 GNU 版本，只有 BusyBox `timeout` 时也会安装 `coreutils`。Alpine 可执行 `apk add --no-cache coreutils`，然后重新运行 `sb`。

### Multiplex 多路复用

支持 VLESS+Reality 和 VLESS+WS+TLS。新增节点时可选择开启（Reality 需先不启用 Flow）；已有节点执行 `sb edit [编号]`，选择 `8` 切换。旧节点默认关闭，新节点默认也不启用。Hysteria2、TUIC 和 AnyTLS 不使用这里的 sing-mux 开关。

开启 multiplex 与开启 Reality Flow 会互相冲突，切换时脚本会询问是否关闭另一项；拒绝则保留原配置。更改仍经过快照、内核校验和服务重启，失败自动回滚。

启用后，服务端配置 `multiplex.enabled: true` 和 `padding: true`；`sb info [编号]` 输出的 sing-box outbound 自动包含匹配的 multiplex 设置。客户端采用 `h2mux`、最多 4 条底层连接、`min_streams: 4`，并开启 padding，不启用 TCP Brutal。字段含义见 [sing-box multiplex 文档](https://sing-box.sagernet.org/configuration/shared/multiplex/)。

mihomo 用户将 `sb info` 显示的以下片段放入对应节点内，与 `server`、`port` 同级，并删除节点的 `flow: xtls-rprx-vision`：

```yaml
smux:
  enabled: true
  protocol: h2mux
  max-connections: 4
  min-streams: 4
  only-tcp: true
  padding: true
```

`only-tcp: true` 表示 mihomo 只对 TCP 流量使用复用，UDP 使用节点原有传输方式。不要再同时设置非零的 `max-streams`。参考 [mihomo 配置说明](https://wiki.metacubex.one/en/config/proxies/#smux)。

**分享链接和二维码不携带 multiplex 设置**，导入后需手动配置客户端，或直接使用输出的 sing-box outbound。关闭服务端 multiplex 后，客户端也需关闭对应的 multiplex/smux；切换到 Flow 时还需同步设置客户端 Flow。

### 证书申请凭据

DNS-01 申请前会检查 Let's Encrypt 的 ACME 目录连接，申请时显式指定完整 CA URL，避免 CA 别名或旧默认配置异常。CA 初始化失败、Cloudflare API 连接/授权失败和 DNS 记录操作失败会分别提示。

选择 Cloudflare 时，会先验证 Token 处于 `active` 状态，再逐级查找域名所属 Zone，确认 Token 可以读取该 Zone。支持用户级 Token；账户级 Token 需要填写 `CF_Account_ID`。预检查只读取 API，不修改 DNS，也不代表已确认 DNS 编辑权限；创建验证 TXT 记录仍需 `Zone-DNS-Edit`，查询 Zone 需 `Zone-Zone-Read`。验证失败会停止申请，Token 不会出现在预检查日志或 curl 命令参数中。其他 DNS 服务商仍由 acme.sh 插件校验凭据。

使用 DNS-01 时，acme.sh 会把 DNS API 凭据保存在 `~/.acme.sh/account.conf` 中用于自动续期，请妥善保管服务器权限。续期成功后会自动重启 sing-box。

节点新增或修改过程中取消、失败时，会恢复托管证书文件。自签证书使用域名下独立的 `self.*` 目录，不覆盖其他节点使用的 DNS 证书。手动指定的外部证书文件不会被修改；已经向 CA 发出的签发请求和 acme.sh 账户记录不属于本地文件回滚范围。

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/sb` | 管理脚本 |
| `/usr/local/bin/sing-box` | sing-box 内核 |
| `/etc/sing-box/conf.d/` | 节点配置，每个节点一个 JSON 文件 |
| `/etc/sing-box/meta/` | 节点元数据，用于查看和修改节点 |
| `/etc/sing-box/certs/<域名>/` | DNS 证书（`fullchain.pem`、`key.pem`）；自签证书保存于独立的 `self.*` 子目录 |
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
支持商家/NAT 已配置 UDP 转发的场景，可在新增节点或 `sb edit` 的选项 `9` 设置对外端口范围及间隔；详见文末说明。脚本不创建本机端口重定向规则。

## 卸载

```bash
sb uninstall
```

可以选择是否保留 `/etc/sing-box` 下的配置和证书，以及是否同时卸载 acme.sh。

## 源码结构与本地开发

源码按功能拆分，根目录 `sb.sh` 只维护版本号、加载模块和调用入口；加载顺序统一记录在 `lib/modules.list`。

| 模块 | 职责 |
|---|---|
| `defaults.sh` / `config.sh` | 路径、默认值、配置与节点元数据 |
| `ui.sh` / `menu.sh` / `cli.sh` | 交互组件、菜单、命令分发 |
| `utils.sh` / `system.sh` / `lock.sh` | 通用工具、系统依赖、运行锁 |
| `core.sh` / `bootstrap.sh` | 内核安装、服务定义、首次初始化与自安装 |
| `network.sh` / `sni.sh` | 端口、防火墙、地址检测、Reality 域名优选 |
| `certificates.sh` | ACME、DNS 验证、证书申请与导入 |
| `protocols.sh` / `sharing.sh` | 服务端协议配置、链接与客户端配置 |
| `nodes.sh` / `transaction.sh` | 节点增删改、快照、应用与回滚 |
| `service.sh` / `maintenance.sh` | 状态、日志、服务控制、更新与卸载 |

克隆完整仓库后运行 `bash sb.sh help`；服务器上可直接运行 `bash sb.sh`，首次安装会自动打包为独立的 `/usr/local/bin/sb`。修改功能时编辑对应的 `lib/` 模块。

```bash
bash scripts/check.sh       # 语法、功能、交互及独立产物回归检查
bash scripts/build.sh       # 生成 dist/sb.sh（不提交生成文件）
bash dist/sb.sh help        # 无需 lib 目录即可运行
```

有本地 sing-box 内核时，可运行 `SB_TEST_CORE=/绝对路径/sing-box bash tests/integration.sh`：使用真实内核校验全部协议及内置 ACME 配置，并在回环地址验证 Shadowsocks 客户端到服务端的 HTTP 请求。CI 另在 systemd 和 Alpine/OpenRC 中测试 1.12.0、1.14.4 的服务启停、重启和内核激活；这些测试不申请公网证书、不访问外部代理目标。

出口与分流可以单独验证（仅使用回环地址，不需要 root）：

```bash
TEST_SING_BOX=/绝对路径/sing-box bash tests/routing.sh
TEST_SING_BOX=/绝对路径/sing-box bash tests/routing-integration.sh
```

后者验证 VLESS/SS 的域名、域名后缀、IP 分流、域名解析后匹配 IP、落地故障不回退、停用规则后直连，以及独立出口检测。CI 在 1.12.0、1.14.4 上运行这两项测试。


Release 工作流自动生成独立脚本并计算校验和；部署时无需额外下载模块。新建模块后，记得加入 `lib/modules.list`。

菜单按功能分组，支持 `0` / `q` 返回或退出；无效选项会重新提示。确认操作只接受完整的 y/yes 或 n/no，输入结束不会自动确认。非终端输出自动禁用颜色，也可设置 `NO_COLOR=1`。输入提示写入标准错误，便于保留命令输出。

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

固定版本可使用 `https://github.com/Jonathan143/sb-install/releases/download/v1.0.1/sb.sh`（替换为实际已发布版本）；固定版本地址不会自动跟随最新版。仓库根目录的 `sb.sh` 现在是模块入口，不能单独下载运行。原先使用 `raw.../main/sb.sh` 的用户，请执行 `SCRIPT_URL=https://github.com/Jonathan143/sb-install/releases/latest/download/sb.sh sb update`，切换到独立发布脚本。

## 免责声明

本项目仅供学习和技术交流使用，请遵守所在地区的法律法规，作者不对使用本脚本产生的任何后果负责。

## 致谢

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)
- [harenaNow/SNI-TLS-test](https://github.com/harenaNow/SNI-TLS-test)（SNI 多轮测速与排序思路参考）

### 系统 DNS

主菜单选择「9 · 系统 DNS 配置」，或运行 `sb dns`。进入后显示当前配置；可选择 Cloudflare、Google、两者组合，或手动输入 1–3 个以空格分隔的 IPv4 / IPv6 地址（IPv6 使用纯十六进制形式，不含接口标识）。`sb dns show` 仅查看，无需安装 sing-box 或联网安装依赖。

确认修改后写入静态 `/etc/resolv.conf`，保留 search、domain、options；如果原文件是符号链接，会替换链接而不修改链接目标。首次修改前将原文件或链接保存至 `/etc/resolv.conf.sb-backup`，菜单可恢复。DHCP、NetworkManager、云初始化等仍可能覆盖此文件；此功能不修改这些服务的配置。只读文件或容器挂载点无法替换时会报错。

### Hysteria2 端口跳跃

新增 Hysteria2 节点时可填写跳跃范围；已有节点使用 `sb edit` →「9 · Hysteria2 端口跳跃」。输入连续对外端口范围（例如 `20000-30000`，有效端口为 1–65535），再设置间隔（5–86400 秒，默认 30 秒）。输入 `0` 关闭跳跃，恢复使用原对外端口；输入 `q` 取消设置。旧节点默认关闭。

此功能用于**商家/NAT 已完成 UDP 转发**的场景：范围内所有对外端口都应转发到同一个节点监听端口。脚本仅保存跳跃设置并生成客户端配置，不创建本机端口重定向规则，也不改变服务端监听端口。

- sing-box 客户端需要 **1.11.0+**：开启时使用 `server_ports` 与 `hop_interval`，关闭时使用 `server_port`。
- `sb info` 同时提供完整 Mihomo 配置，包含 `ports` 和 `hop-interval`。
- 分享链接和二维码采用 Hysteria2 官方 URI 的端口范围格式；部分客户端可能不支持导入范围，请核对生成的配置。链接不携带跳跃间隔，自定义间隔需使用完整配置或在客户端手动设置。

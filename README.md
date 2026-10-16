# sb - sing-box 节点管理脚本

交互式的 [sing-box](https://github.com/SagerNet/sing-box) 一键部署与管理脚本，安装后通过 `sb` 命令使用。支持多协议共存，可以新增、修改、删除节点，查看运行状态和日志。

## 特性

- **支持协议**：VLESS+Reality、VLESS+WS+TLS、Hysteria2、TUIC v5、AnyTLS
- **端口**：自定义，默认在 20000-60000 随机；监听端口与对外端口分开设置，适配 NAT 小鸡
- **Reality**：Flow（`xtls-rprx-vision`）可选开启或关闭；SNI 内置常用推荐列表，可手动输入，默认随机，并自动检测目标站是否支持 TLS1.3 + h2
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

### 证书申请凭据

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

**客户端导入链接失败？**
`anytls://` 和 `tuic://` 的 URI 格式在各客户端之间并不完全统一。导入失败时，请使用 `sb info` 输出的 sing-box outbound JSON。

**Reality 的 SNI 检测全部不通过？**
检测需要服务器能访问目标站点的 443 端口。如果服务器所在网络限制了对外访问，检测会失败，脚本会给出警告并使用随机选中的站点。

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

## 免责声明

本项目仅供学习和技术交流使用，请遵守所在地区的法律法规，作者不对使用本脚本产生的任何后果负责。

## 致谢

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)

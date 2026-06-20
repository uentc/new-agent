# New Agent / 新代理节点一键脚本

English | 中文

New Agent is a Linux one-click installer for a sing-box + Xray multi-protocol proxy stack. It generates fresh credentials locally, enables BBR, configures certificates, and publishes sing-box-compatible subscription files.

New Agent 是一个 Linux 一键部署脚本，用于安装 sing-box + Xray 多协议节点。脚本会在 VPS 本机生成全新密钥，启用 BBR，配置证书，并生成可导入 sing-box 的订阅链接。

## Features / 功能

- VLESS TCP Reality Vision, sing-box
- VLESS XHTTP Reality, Xray
- NaiveProxy
- AnyTLS with certificate / 证书版 AnyTLS
- AnyTLS Reality
- Hysteria2 with UDP port hopping / Hysteria2 高端口跳跃
- TUIC v5 with UDP port hopping / TUIC v5 高端口跳跃
- ShadowTLS v3 over Shadowsocks / ShadowTLS v3 + Shadowsocks 内层
- BBR
- Subscription over HTTPS / HTTPS 订阅服务

## Domain And Certificate / 域名与证书规则

With your own domain:

- Pass `--domain example.com`.
- The script uses ACME/Let's Encrypt.
- Certificate renewal is installed automatically by acme.sh.
- No client-side skip verification is needed.

使用自己的域名：

- 传入 `--domain example.com`。
- 脚本会使用 ACME/Let's Encrypt 签发正式证书。
- acme.sh 会自动安装续签任务。
- 客户端不需要跳过证书验证。

Without a domain, or when forcing self-signed mode:

- Omit `--domain`, or use `--skip-cert`.
- The script uses the VPS public IPv4 as the server address.
- A self-signed certificate is generated.
- When importing the subscription or using certificate-based nodes, enable `insecure`, `allow insecure`, or `skip certificate verification`.
- Reality-based nodes do not depend on this self-signed certificate.

没有域名，或者强制使用自签证书：

- 不填写 `--domain`，或者使用 `--skip-cert`。
- 脚本会自动使用 VPS 公网 IPv4 作为服务器地址。
- 脚本会生成自签证书。
- 导入订阅或使用证书类节点时，需要开启 `insecure`、`allow insecure` 或“跳过证书验证”。
- Reality 类节点不依赖这个自签证书。

## Reality Target / Reality 目标域名

You can set it manually:

```bash
--reality-target www.cuhk.edu.hk
```

If left empty, the script tests a built-in list of public university websites from the VPS and selects a reachable low-latency HTTPS target.

可以手动指定：

```bash
--reality-target www.cuhk.edu.hk
```

如果留空，脚本会从内置的公开大学官网候选列表中自动测试 VPS 到这些站点的 HTTPS 连通性和延迟，并选择一个可用目标。

## Requirements / 系统要求

- Root access / root 权限
- Debian 11+, Ubuntu 20.04+, CentOS Stream, Rocky Linux, AlmaLinux, or Fedora
- Open ports / 放行端口：
  - TCP: `80`, `443`, `2053`, `5443`, `7443`, `8443`, `8444`, `9443`
  - UDP: `30000`, `30001`, `40000-40100`, `41000-41100`, `9443`

If using Cloudflare DNS for your own domain, keep the record in DNS-only mode while issuing the certificate.

如果域名在 Cloudflare 上，签发证书时建议先保持 DNS-only，不要开小云朵代理。

## One Command / 一个命令

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/uentc/new-agent/main/install.sh)
```

Run the command above, then choose from the menu.

复制上面这一条命令运行，然后在菜单里选择功能。

Menu / 菜单：

- `1` Install / 一键安装
- `2` Change domain / 更换域名
- `3` Show links / 查看订阅
- `4` Status / 查看状态
- `5` Clean uninstall / 一键彻底卸载
- `6` Detect existing nodes / 查看已有节点
- `0` Exit / 退出

Advanced non-interactive mode is still supported for automation.

脚本仍然保留参数模式，方便高级用户自动化使用。

## Output / 输出内容

The installer prints:

- SingBox GUI subscription
- Full sing-box config
- Raw share links
- Base64 share links

脚本安装完成后会输出：

- SingBox GUI 订阅
- 完整 sing-box 配置
- 原始分享链接
- Base64 分享链接

## Change Domain And Uninstall / 更换域名与卸载

Change domain:

- Choose menu option `2`.
- Enter a new domain, or leave it blank to switch to VPS IP + self-signed certificate mode.
- Existing node passwords and UUIDs are kept.
- The script reissues the certificate, rewrites configs, regenerates subscriptions, and restarts services.

更换域名：

- 选择菜单 `2`。
- 输入新域名，或者留空切换为 VPS IP + 自签证书模式。
- 原有节点密码和 UUID 会保留。
- 脚本会重新签发证书、重写配置、重新生成订阅并重启服务。

Clean uninstall:

- Choose menu option `5`.
- It removes systemd services, iptables hop rules, configs, certificates, subscription files, generated credentials, sing-box/Xray binaries, and the BBR sysctl file created by this script.

彻底卸载：

- 选择菜单 `5`。
- 会删除 systemd 服务、端口跳跃规则、配置、证书、订阅文件、生成的密钥、sing-box/Xray 核心文件，以及本脚本创建的 BBR 配置。

## Existing Install Detection / 已有节点检测

Choose menu option `6` to detect an existing installation.

选择菜单 `6` 可以检测当前 VPS 上已有的节点。

- If installed by New Agent, it prints the subscription links.
- If it finds the legacy `/etc/proxy-node` layout, it prints compatible subscription links.
- If another script such as lightclone installed the stack, New Agent will try to parse sing-box/Xray configs and show protocols, ports, and running services.
- If that script stores credentials in a private custom path, New Agent cannot reconstruct full share links unless the path is known.

- 如果是 New Agent 安装的，会直接显示订阅链接。
- 如果检测到旧版 `/etc/proxy-node` 结构，会显示兼容订阅链接。
- 如果是 lightclone 这类其他脚本安装的，会尽量解析 sing-box/Xray 配置，显示协议、端口和运行服务。
- 如果对方脚本把密钥存在私有路径，且路径未知，New Agent 无法还原完整分享链接，只能显示检测到的配置摘要。

## Important Notes / 注意事项

- ShadowTLS is exported as `vps-shadowtls-v3`, backed by hidden transport `vps-shadowtls-v3-transport`.
- ShadowTLS 会显示为 `vps-shadowtls-v3`，底层通过隐藏承载节点 `vps-shadowtls-v3-transport` 工作。
- Hysteria2 listens on UDP `30000` and accepts hop range `40000-40100`.
- Hysteria2 主端口为 UDP `30000`，跳跃端口为 `40000-40100`。
- TUIC listens on UDP `30001` and accepts hop range `41000-41100`.
- TUIC 主端口为 UDP `30001`，跳跃端口为 `41000-41100`。
- Secrets are stored in `/etc/new-agent/credentials.env`.
- 密钥保存在 `/etc/new-agent/credentials.env`。

## Disclaimer / 免责声明

Use this project only on servers and networks you own or are authorized to administer. You are responsible for complying with local laws, provider rules, and network policies.

请仅在你拥有或被授权管理的服务器和网络中使用本项目。你需要自行遵守所在地法律、服务商规则和网络政策。

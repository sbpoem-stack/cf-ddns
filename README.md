# cf-ddns

Cloudflare DDNS 脚本，**同时更新 A (IPv4) 和 AAAA (IPv6) 记录**。适合 AWS 等公网 IP 会变的云服务器。

- 默认同时同步 IPv4 和 IPv6，本机没有 IPv6 时自动跳过
- IPv6 优先读取网卡上的全局地址（AWS 的 IPv6 直接配在网卡上），读不到再查外部服务
- 已有记录只改 IP，保留原有 TTL 和代理（小云朵）设置
- 同名重复记录自动清理，只保留一条
- 一条命令安装为每分钟执行的定时任务，带防重入锁和日志轮转
- 一台机器可以安装多个记录名，互不影响
- 只依赖 `bash`、`curl`、`sed`、`grep`

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sbpoem-stack/cf-ddns/main/cf-ddns.sh) \
  --install-cron --token <你的API令牌> example.com node1.example.com
```

执行后会：
1. 把脚本安装到 `/usr/local/bin/cf-ddns.sh`
2. 写入每分钟执行一次的 crontab
3. 立即同步一次

日志在 `/var/log/cf-ddns.log`：

```bash
tail -f /var/log/cf-ddns.log
```

## 用法

```
cf-ddns.sh [选项] --token <API令牌> <zone> <记录名>
cf-ddns.sh --install-cron [选项] --token <API令牌> <zone> <记录名>
cf-ddns.sh --uninstall <记录名>
```

| 选项 | 说明 |
|---|---|
| `-4`, `--ipv4-only` | 只更新 A 记录 |
| `-6`, `--ipv6-only` | 只更新 AAAA 记录 |
| `--ip4 <地址>` | 手动指定 IPv4，不自动检测 |
| `--ip6 <地址>` | 手动指定 IPv6，不自动检测 |
| `--ttl <秒>` | 新建记录的 TTL，默认 60（1 = 自动） |
| `--install-cron` | 安装为每分钟执行的定时任务 |
| `--uninstall` | 删除该记录名的定时任务 |

令牌也可以通过环境变量 `CF_API_TOKEN` 传入。

## 创建 API 令牌

Cloudflare 后台 → 我的个人资料 → API 令牌 → 创建令牌 → 使用“编辑区域 DNS”模板：

- 权限：`Zone:Zone:Read`、`Zone:DNS:Edit`
- 区域资源：只选需要的域名

**不要使用 Global API Key**，也不要把令牌提交到仓库或发给别人。

## AWS 开启 IPv6

1. VPC → 编辑 CIDR → 添加 Amazon 提供的 IPv6 CIDR
2. 子网 → 编辑 IPv6 CIDR → 分配一段
3. 路由表 → 添加 `::/0` 指向 Internet Gateway
4. 安全组 → 入站规则为需要的端口添加 `::/0`
5. EC2 实例 → 联网 → 管理 IP 地址 → 分配 IPv6

确认本机已有 IPv6：

```bash
ip -6 addr show scope global
```

AWS 分配的 IPv6 在停机、重启后不会变化。

## 卸载

```bash
cf-ddns.sh --uninstall node1.example.com
rm -f /usr/local/bin/cf-ddns.sh /etc/logrotate.d/cf-ddns   # 不再需要时
```

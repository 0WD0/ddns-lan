## 🚀 DDNS-Lan
### 📌 项目简介

DDNS-Lan 是一个基于 **Cloudflare API** 的动态 DNS 工具，使用 **Bash** 脚本实现。它通过 **SSH** 连接到 ImmortalWrt/OpenWrt 路由器，自动检测路由器的 WAN 口 IP 地址，并更新 Cloudflare 域名对应的 A 记录，从而实现你在内网中通过一个自定义的域名访问你的本地服务（如：Web、SSH、API、文件共享系统等）。

### 💡 开发动机

作者在使用 **Sunshine** 和 **Moonlight** 进行游戏串流时，需要知道设备的准确 IP 地址才能建立连接。由于学校/企业网络环境中路由器被分配到的 IP 地址不是固定的，每次重连网络后都需要手动查找新的 IP 地址，非常不便。

这个脚本相当于实现了一个**简陋但实用的内网 DDNS 解决方案**，通过域名自动跟踪设备 IP 变化，让串流连接变得更加便捷。

> ⚠️ 本项目仅在**局域网 / 虚拟内网 / 学校网**中使用 DNS 解析，不提供公网访问或反向代理功能。

### 🌐 适用场景

- **游戏串流**：使用 Sunshine/Moonlight、Steam Remote Play、Parsec 等串流服务时，通过域名连接设备
- **内网服务搭建**：在学校或公司内网中搭建 Web 服务，希望别人用域名访问
- **设备管理**：统一设备访问方式，使用 `myserver.yourdomain.com` 代替 IP
- **动态 IP 追踪**：自动跟踪路由器 IP 变化，避免每次重连网络后手动查找 IP

### 🚧 配置要求

| 组件 | 要求 |
|------|------|
| 路由器 | ImmortalWrt/OpenWrt 路由器，需要能通过 SSH 访问 |
| DNS 域名 | 需要在 [Cloudflare](https://dash.cloudflare.com/) 注册管理，并有 API Token |
| 环境 | Linux/macOS 系统，支持 Bash 4.0+ |
| 依赖工具 | sshpass、jq、curl |
| 访问权限 | 你的脚本必须具有定时运行能力（如 crontab / systemd / Docker 定时任务） |


### 🔧 安装与配置

#### 1. 安装依赖

```bash
# Ubuntu/Debian
sudo apt-get install sshpass jq curl

# CentOS/RHEL
sudo yum install sshpass jq curl

# Arch Linux
sudo pacman -S sshpass jq curl

# macOS
brew install sshpass jq curl
```

#### 2. 初始化配置文件

```bash
# 创建配置文件模板
./ddns-lan.sh --init

# 编辑配置文件
vi config.json
```

#### 3. 配置文件 `config.json`

```json
{
  "router": {
    "ssh_host": "192.168.110.1",
    "ssh_port": 22,
    "username": "root",
    "password": "your_password"
  },
  "cloudflare": {
    "api_token": "your_api_token",
    "zone_id": "your_zone_id",
    "record_name": "myserver.yourdomain.com",
    "ttl": 120,
    "proxied": false
  },
  "network": {
    "use_private_ip": true,
    "allowed_private_networks": ["10.150.0.0/16"],
    "fallback_to_local_ip": true
  },
  "logging": {
    "verbose": true,
    "log_file": ""
  }
}
```

### 🧪 运行方式

#### 单次运行

```bash
# 使用默认配置文件
./ddns-lan.sh

# 使用指定配置文件
./ddns-lan.sh --config my-config.json

# 仅检查配置，不更新 DNS
./ddns-lan.sh --check
```

#### 定时更新（推荐）

使用 `cron` 每小时执行一次更新：

```bash
crontab -e
```

添加一行：

```bash
0 * * * * cd /path/to/ddns-lan && ./ddns-lan.sh > /dev/null 2>&1
```


### 🔐 安全说明

- **务必使用最小权限 token**，不要用主账号的 API Token。
- **不要在 public 仓库中提交 `config.json` 文件**！
- **SSH 密码安全**：建议使用密钥认证或限制SSH访问权限。
- **建议将 IP 更新任务限制在局域网环境中运行**。

### 🛠️ 工作原理

脚本通过以下方式获取路由器 IP：

1. **SSH 连接**：通过 SSH 连接到 ImmortalWrt/OpenWrt 路由器
2. **多命令尝试**：依次尝试多个命令获取 WAN IP
   - `ip route | grep default` - 从路由表获取源IP（优先）
   - `ubus call network.interface.wan status` - 从 ubus 接口获取IP
   - `ifconfig` - 从网络接口获取IP
   - `ip addr show` - 从地址配置获取IP
3. **IP 智能筛选**：
   - 优先使用路由表中的源IP（本机IP）
   - 验证IP是否在允许的网络段内
   - 排除无效和保留IP地址
4. **备用方案**：如果路由器连接失败，使用本机IP作为备用

### 🔍 IP 检测逻辑

脚本具有智能的IP检测逻辑：

- **内网IP支持**：可配置允许的私有网络段（如 `10.150.0.0/16`）
- **公网IP检测**：自动识别和使用公网IP
- **源IP优先**：优先使用路由表中的源IP（更准确的本机IP）
- **多重验证**：排除回环地址、链路本地地址等无效IP


### ✅ 使用效果

- **串流体验提升**：Moonlight 客户端直接输入域名即可连接，无需每次查找 IP
- **自动更新**：每次重连网络后脚本自动更新 Cloudflare DNS 记录
- **多设备支持**：内网其他设备访问 `myserver.yourdomain.com` 即可访问你的服务
- **智能检测**：在学校网络环境中自动选择最合适的IP地址
- **通用性强**：可用于搭建 Nextcloud、Jellyfin、SSH 服务、开发环境等各种应用

### 🎉 支持与扩展

你也可以考虑扩展以下功能：

- 多个域名支持
- 自动获取子域名（如 `pi.myserver.yourdomain.com`）
- 日志记录（已支持日志文件配置）
- 失败通知（如通过 Telegram、邮件通知）
- Docker 化部署
- 每天自动运行，只在 IP 变更时更新
- 支持 IPv6
- SSH 密钥认证支持
- 更多路由器固件支持（如 DD-WRT、Padavan 等）

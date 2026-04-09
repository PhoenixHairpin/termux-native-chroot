# 快速入门指南

## 🚀 5 分钟上手

### 步骤 1: 下载脚本

```bash
# 克隆仓库
git clone https://github.com/PhoenixHairpin/termux-native-chroot.git
cd termux-native-chroot

# 或直接下载
curl -LO https://raw.githubusercontent.com/PhoenixHairpin/termux-native-chroot/main/start-ubuntu-full.sh
curl -LO https://raw.githubusercontent.com/PhoenixHairpin/termux-native-chroot/main/chroot-mcp-safe.sh
chmod +x *.sh
```

### 步骤 2: 安装 rootfs (三种方式)

#### 方式 A: 使用 proot-distro (最简单)

```bash
pkg install proot-distro
proot-distro install ubuntu
su -c ./start-ubuntu-full.sh --distro ubuntu --permissive
```

#### 方式 B: 手动下载 rootfs (推荐)

```bash
su -c 'mkdir -p /data/local/chroot/ubuntu'
su -c 'cd /data/local/chroot/ubuntu && curl -L "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64-root.tar.xz" | tar -xJf -'
su -c 'chown root:root /data/local/chroot/ubuntu && chmod 755 /data/local/chroot/ubuntu'
su -c ./start-ubuntu-full.sh --rootfs /data/local/chroot/ubuntu --permissive
```

#### 方式 C: 交互式向导

```bash
su -c ./start-ubuntu-full.sh --interactive
# 按提示选择发行版、下载 rootfs
```

### 步骤 3: 配置编译环境

进入 chroot 后执行：

```bash
apt update
apt install -y build-essential clang cmake git python3 python3-pip
```

### 步骤 4: 开始编译/部署

```bash
# 编译示例
git clone https://github.com/example/project.git
cd project
cmake -B build
cmake --build build

# MCP 工具部署
pip3 install anthropic-mcp
```

### 步骤 5: 安全退出

```bash
exit  # 自动清理所有挂载点，恢复 SELinux
```

## ⚡ 一键命令

```bash
# 最快启动方式
su -c ./start-ubuntu-full.sh --permissive --distro ubuntu
```

## 📋 常用命令速查

| 操作 | 命令 |
|------|------|
| 启动 Ubuntu | `su -c ./start-ubuntu-full.sh --permissive --distro ubuntu` |
| 启动 Debian | `su -c ./start-ubuntu-full.sh --permissive --distro debian` |
| 指定 rootfs | `su -c ./start-ubuntu-full.sh --permissive --rootfs /path/to/rootfs` |
| 只读 /data | `su -c ./start-ubuntu-full.sh --permissive --ro-data` |
| 交互模式 | `su -c ./start-ubuntu-full.sh -i` |
| 查看帮助 | `su -c ./start-ubuntu-full.sh --help` |
| 安装建议 | `su -c ./start-ubuntu-full.sh --print-install --distro ubuntu` |

## 🔧 常见问题速解

### Q: chroot 失败 "Operation not permitted"

```bash
# 添加 --permissive 参数
su -c ./start-ubuntu-full.sh --permissive
```

### Q: 缺少 chroot 命令

```bash
pkg install chroot
```

### Q: rootfs 目录权限问题

```bash
su -c 'chown -R root:root /data/local/chroot/ubuntu'
su -c 'chmod 755 /data/local/chroot/ubuntu'
```

### Q: 残留挂载点清理

```bash
su -c 'cat /proc/self/mountinfo | grep chroot'
su -c 'umount -l /path/to/mountpoint'
```

## 📱 移动设备优化

```bash
# 使用 --ro-data 保护用户数据
su -c ./start-ubuntu-full.sh --permissive --ro-data --distro ubuntu
```

## ✅ 成功验证

进入 chroot 后执行：

```bash
# 检查挂载点
ls /android_root /android_data /android_system /sdcard

# 检查编译工具
gcc --version
clang --version
cmake --version

# 检查 Python
python3 --version
pip3 --version
```

# 技术架构文档

## 📐 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Android 宿主系统                           │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                    Termux 环境                           │ │
│  │  ┌─────────────────────────────────────────────────────┐ │ │
│  │  │           start-ubuntu-full.sh (入口)                │ │ │
│  │  │                      ↓                               │ │ │
│  │  │           chroot-mcp-safe.sh (核心)                  │ │ │
│  │  │                      ↓                               │ │ │
│  │  │    ┌─────────────────────────────────────┐           │ │ │
│  │  │    │      Mount Namespace (隔离层)        │           │ │ │
│  │  │    │  ┌───────────────────────────────┐  │           │ │ │
│  │  │    │  │      Linux Rootfs (chroot)     │  │           │ │ │
│  │  │    │  │                               │  │           │ │ │
│  │  │    │  │  /android_root  ← / (宿主)    │  │           │ │ │
│  │  │    │  │  /android_data  ← /data       │  │           │ │ │
│  │  │    │  │  /android_system← /system     │  │           │ │ │
│  │  │    │  │  /sdcard        ← 内置存储    │  │           │ │ │
│  │  │    │  │  /dev, /proc, /sys            │  │           │ │ │
│  │  │    │  │                               │  │           │ │ │
│  │  │    │  │  [完整编译环境 + MCP 工具]     │  │           │ │ │
│  │  │    │  └───────────────────────────────┘  │           │ │ │
│  │  │    └─────────────────────────────────────┘           │ │ │
│  │  └─────────────────────────────────────────────────────┘ │ │
│  │  exit → 自动清理所有挂载 + 恢复 SELinux                  │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## 🔧 核心组件

### 1. 入口脚本 (start-ubuntu-full.sh)

- **职责**: 检查并调用核心脚本
- **特点**: 简洁入口，确保脚本可执行

### 2. 核心脚本 (chroot-mcp-safe.sh)

主要功能模块：

#### 2.1 参数解析模块
- 支持 9 个命令行参数
- 交互式向导模式
- 发行版预设路径自动检测

#### 2.2 SELinux 处理模块
```bash
check_selinux()   # 检测当前 SELinux 状态
setenforce 0      # 临时切换到 Permissive
setenforce 1      # 退出时恢复原状态
```

#### 2.3 命名空间隔离模块
```bash
unshare --mount --propagation private  # 创建私有 mount namespace
mount --make-rprivate /                 # 锁定根目录传播属性
mount --make-private $dst               # 每个挂载点设为 private
```

#### 2.4 挂载管理模块
```bash
do_mount()           # 统一挂载函数
resolve_mount_path() # Android 分区路径兼容
MOUNT_STACK[]        # 挂载点栈（用于清理）
```

#### 2.5 进程清理模块
```bash
chroot_pids()        # 查找 chroot 内所有进程
kill_pid_tree()      # 递归终止进程树
cleanup()            # 安全清理函数（trap 绑定）
```

#### 2.6 兼容性补丁模块
```bash
prepare_chroot_compat()  # 注入 run-parts/pidof 兼容实现
prepare_and_start_sshd() # SSH 服务自检与启动
```

## 🔄 执行流程

```
1. 检查 root 权限
2. 创建 Mount Namespace
3. 预检 chroot syscall 可用性
4. 检测并处理 SELinux
5. 锁定根目录传播属性为 private
6. 依次挂载：
   - /proc (nosuid,noexec,nodev)
   - /sys (ro,nosuid,noexec,nodev)
   - /dev (bind,nosuid,noexec)
   - /dev/pts (devpts,newinstance)
   - /tmp, /run, /dev/shm (tmpfs)
   - /android_root (bind,ro)
   - /android_data (bind,rw 或 ro)
   - /android_system, /vendor, /product, /odm, /boot (bind,ro)
   - /sdcard (bind,rw)
   - /etc/resolv.conf (bind,ro)
7. 注入兼容性补丁
8. 启动 SSH 服务（如可用）
9. 进入 chroot shell
10. 用户退出 → cleanup() 自动执行
```

## 🔒 安全设计

### 原则 1: 最小权限原则
- 系统分区默认只读 (`ro,nosuid`)
- `/data` 可配置只读 (`--ro-data`)
- `/dev` 无 suid 执行权限

### 原则 2: 防御性编程
- 所有挂载点设置为 `private` 传播属性
- `set -u` 检测未定义变量
- `set -o pipefail` 检测管道失败
- 预检 chroot syscall 可用性

### 原则 3: 原子性清理
- `trap cleanup EXIT SIGINT SIGTERM` 绑定清理函数
- 挂载点按栈逆序卸载
- SELinux 状态自动恢复
- 三轮进程终止（TERM → TERM → KILL）

### 原则 4: 防嵌套保护
```bash
if [ -f "$CHROOT_MARKER" ] || grep -Fq " $TARGET " /proc/self/mountinfo; then
  echo_err "检测到疑似嵌套chroot，已拒绝执行"
fi
```

## 📊 挂载点权限矩阵

| 源路径 | 目标路径 | 类型 | 权限选项 | 传播属性 |
|--------|----------|------|----------|----------|
| proc | /proc | proc | nosuid,noexec,nodev | private |
| sysfs | /sys | sysfs | ro,nosuid,noexec,nodev | private |
| /dev | /dev | bind | nosuid,noexec | private |
| devpts | /dev/pts | devpts | nosuid,noexec,newinstance | private |
| tmpfs | /tmp | tmpfs | nosuid,nodev,mode=1777 | private |
| tmpfs | /run | tmpfs | nosuid,nodev,mode=755,size=200M | private |
| / | /android_root | bind | ro | private |
| /data | /android_data | bind | rw/ro | private |
| /system | /android_system | bind | ro,nosuid | private |
| /vendor | /android_vendor | bind | ro,nosuid | private |
| /sdcard | /sdcard | bind | rw | private |

## 🧪 测试用例

### 功能测试
1. 基本启动测试：`su -c ./start-ubuntu-full.sh --permissive`
2. 交互模式测试：`su -c ./start-ubuntu-full.sh -i`
3. SELinux 恢复测试：验证退出后 SELinux 状态恢复
4. 挂载清理测试：验证退出后无残留挂载点
5. 嵌套拒绝测试：在 chroot 内再次执行脚本应被拒绝

### 兼容性测试
1. 不同 rootfs 路径测试
2. 不同发行版测试 (Ubuntu/Debian/Arch/Fedora/Alpine)
3. 不同 root 方案测试 (KernelSU/Magisk/su)
4. 不同 Android 版本测试 (10/11/12/13/14)

## 📈 性能特性

| 特性 | 原生 chroot | proot-distro |
|------|-------------|--------------|
| 启动速度 | ~2-3 秒 | ~5-8 秒 |
| syscall 开销 | 0 (原生) | 高 (ptrace 模拟) |
| 编译性能 | 100% | 30-50% |
| root 权限 | 完整 | 模拟 |
| 系统访问 | 完整 | 受限 |

## 🔮 扩展方向

1. 支持更多发行版 (Gentoo, NixOS)
2. 自动化 rootfs 下载与验证
3. 图形化配置工具
4. 与 Docker/Podman 集成
5. 云端 rootfs 预构建服务

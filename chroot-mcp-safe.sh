#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

TERMUX_PREFIX="/data/data/com.termux/files/usr"
export PATH="$TERMUX_PREFIX/bin:$TERMUX_PREFIX/sbin:$PATH"
CHROOT_BIN="$TERMUX_PREFIX/bin/chroot"
[ -x "$CHROOT_BIN" ] || CHROOT_BIN="$TERMUX_PREFIX/sbin/chroot"
[ -x "$CHROOT_BIN" ] || CHROOT_BIN="$(command -v chroot 2>/dev/null || echo /system/bin/chroot)"

# ==============================================
# 配置区（保持能力不阉割，仅做防误触加固）
# ==============================================
# 默认rootfs路径（优先非proot目录；兼容历史proot目录）
if [ -z "${TARGET:-}" ]; then
  if [ -d "/data/local/chroot/ubuntu" ]; then
    TARGET="/data/local/chroot/ubuntu"
  elif [ -d "/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu" ]; then
    TARGET="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
  else
    TARGET="/data/local/chroot/ubuntu"
  fi
fi
DISTRO_NAME=""
PRINT_INSTALL_GUIDE=0
INTERACTIVE_MODE=0
LOG_FILE="/data/data/com.termux/files/usr/tmp/chroot-mcp-$(date +%s).log"

HOST_ROOT_OPT="ro"
SYS_MOUNT_OPT="ro,nosuid"
DATA_MOUNT_OPT="rw"
SDCARD_MOUNT_OPT="rw"

CHROOT_MARKER="/.chroot_marker"
MOUNT_STACK=()
ORIGINAL_SELINUX_STATE=""
PERMISSIVE=0
RO_DATA=0
IN_CLEANUP=0
CLEANUP_DONE=0
FALLBACK_PROOT=0
USE_PROOT_FALLBACK=0
ORIG_ARGC=$#

while [ $# -gt 0 ]; do
  case "$1" in
    --distro)
      [ $# -lt 2 ] && { echo "错误: --distro 需要一个参数(ubuntu/debian/arch/fedora/alpine)" >&2; exit 2; }
      DISTRO_NAME="$2"
      shift 2
      ;;
    --permissive)
      PERMISSIVE=1
      shift
      ;;
    --ro-data)
      RO_DATA=1
      shift
      ;;
    --proot-fallback)
      FALLBACK_PROOT=1
      shift
      ;;
    --no-proot-fallback)
      FALLBACK_PROOT=0
      shift
      ;;
    --rootfs)
      [ $# -lt 2 ] && { echo "错误: --rootfs 需要一个目录参数" >&2; exit 2; }
      TARGET="$2"
      shift 2
      ;;
    --print-install)
      PRINT_INSTALL_GUIDE=1
      shift
      ;;
    --interactive|-i)
      INTERACTIVE_MODE=1
      shift
      ;;
    --help|-h)
      cat <<USAGE
用法: $0 [--interactive] [--permissive] [--ro-data] [--distro <名称>] [--rootfs <目录>] [--proot-fallback] [--print-install]
  --interactive     交互式向导（选择发行版/下载rootfs/启动参数）
  --permissive      临时 setenforce 0，退出自动恢复
  --ro-data         将 /data 以只读方式挂载到 chroot
  --distro <名称>   使用预设rootfs路径: ubuntu/debian/arch/fedora/alpine
  --rootfs <目录>   指定要进入的Linux rootfs目录（不依赖proot-distro）
  --proot-fallback  仅在你主动启用时，chroot失败回退到proot-distro
  --print-install   输出对应发行版的安装/编译环境建议命令
USAGE
      exit 0
      ;;
    *)
      echo "警告: 忽略未知参数: $1" >&2
      shift
      ;;
  esac
done

if [ "$ORIG_ARGC" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  INTERACTIVE_MODE=1
fi

dialog_extract_text() {
  sed -n 's/.*"text":"\([^"]*\)".*/\1/p'
}

choose_option() {
  local prompt="$1"; shift
  local options=("$@")
  local selected=""

  if command -v termux-dialog >/dev/null 2>&1; then
    local csv
    csv=$(IFS=,; echo "${options[*]}")
    selected=$(termux-dialog radio -t "$prompt" -v "$csv" 2>/dev/null | dialog_extract_text | head -n1)
  fi

  if [ -z "$selected" ]; then
    echo "$prompt" >&2
    local i=1 opt idx
    for opt in "${options[@]}"; do
      echo "  [$i] $opt" >&2
      i=$((i+1))
    done
    read -r -p "请输入编号: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#options[@]}" ]; then
      selected="${options[$((idx-1))]}"
    else
      selected="${options[0]}"
    fi
  fi
  echo "$selected"
}

ask_text() {
  local prompt="$1"
  local val=""
  if command -v termux-dialog >/dev/null 2>&1; then
    val=$(termux-dialog text -t "$prompt" 2>/dev/null | dialog_extract_text | head -n1)
  fi
  if [ -z "$val" ]; then
    read -r -p "$prompt: " val
  fi
  echo "$val"
}

download_rootfs_archive() {
  local url="$1"
  local rootfs_dir="$2"
  local archive="/data/data/com.termux/files/usr/tmp/rootfs-$(date +%s).tar"

  mkdir -p "$rootfs_dir" || return 1
  curl -fL "$url" -o "$archive" || return 1
  tar -xf "$archive" -C "$rootfs_dir" || return 1
  chown root:root "$rootfs_dir" 2>/dev/null || true
  chmod 755 "$rootfs_dir" 2>/dev/null || true
  rm -f "$archive" 2>/dev/null || true
}

bootstrap_rootfs_from_termux_source() {
  local distro="$1"
  local pd_root="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$distro"
  if ! command -v proot-distro >/dev/null 2>&1; then
    # 交互模式兜底：自动安装 proot-distro（仅用于获取内置rootfs源）
    if command -v pkg >/dev/null 2>&1; then
      pkg install -y proot-distro >/dev/null 2>&1 || return 1
    fi
    command -v proot-distro >/dev/null 2>&1 || return 1
  fi
  # 若已存在可用rootfs，直接复用（避免 "already installed" 触发失败）
  if [ -x "$pd_root/bin/bash" ]; then
    TARGET="$pd_root"
    return 0
  fi

  proot-distro install "$distro" >/dev/null 2>&1 || true

  # 某些机型/环境下 proot-distro 会返回非0，但rootfs可能已成功落盘
  if [ -x "$pd_root/bin/bash" ]; then
    TARGET="$pd_root"
    return 0
  fi

  return 1
}

apply_distro_preset() {
  [ -z "$DISTRO_NAME" ] && return 0
  case "$DISTRO_NAME" in
    ubuntu|debian|arch|fedora|alpine) ;;
    *)
      echo "错误: 不支持的 --distro 值: $DISTRO_NAME" >&2
      exit 2
      ;;
  esac

  # 未显式传 --rootfs 时，按发行版预设路径自动设置（优先 /data/local/chroot）
  if [ "${TARGET:-}" = "/data/local/chroot/ubuntu" ] || [ "${TARGET:-}" = "/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu" ]; then
    if [ -d "/data/local/chroot" ] || [ ! -d "/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs" ]; then
      TARGET="/data/local/chroot/$DISTRO_NAME"
    else
      TARGET="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$DISTRO_NAME"
    fi
  fi
}

print_install_guide() {
  local distro="${DISTRO_NAME:-ubuntu}"
  cat <<EOF
[安装建议] 面向“高权限 + 编译能力”优先

推荐优先级:
  1) Ubuntu 24.04 / Debian 12  (兼容性最稳，工具链最全)
  2) Arch Linux                (滚动更新，新工具最快)
  3) Fedora                    (较新编译链)

一、快速拉起rootfs（纯chroot，不依赖proot）
  pkg update -y
  pkg install -y curl tar xz-utils
  su -c 'mkdir -p /data/local/chroot/$distro'
  # 将 ROOTFS_URL 替换成你要的发行版 rootfs 压缩包地址（arm64）
  ROOTFS_URL="<替换为${distro} rootfs tar包URL>"
  su -c "cd /data/local/chroot/$distro && curl -L \"\$ROOTFS_URL\" | tar -xJf -"
  su -c 'chown root:root /data/local/chroot/$distro && chmod 755 /data/local/chroot/$distro'
  su -c ./start-ubuntu-full.sh --permissive --rootfs /data/local/chroot/$distro --no-proot-fallback

  交互模式下若URL留空：脚本会自动尝试使用 Termux 内置源（proot-distro）下载同名发行版，仅用于取rootfs。

二、进入后安装常用编译工具（按发行版）
  Debian/Ubuntu:
    apt update && apt install -y build-essential clang lld cmake ninja-build git pkg-config python3 python3-pip gdb lldb rustc cargo golang

  Arch:
    pacman -Syu --noconfirm base-devel clang lld cmake ninja git pkgconf python python-pip gdb lldb rust go

  Fedora:
    dnf groupinstall -y "Development Tools" && dnf install -y clang lld cmake ninja-build git pkgconf-pkg-config python3 python3-pip gdb lldb rust cargo golang

  Alpine:
    apk add --no-cache build-base clang lld cmake ninja git pkgconf python3 py3-pip gdb lldb rust cargo go
EOF
}

interactive_wizard() {
  local action distro url permissive_choice ro_choice fallback_choice rootfs_input
  action=$(choose_option "选择操作" "启动已存在rootfs" "下载rootfs后启动" "只打印安装建议")
  distro=$(choose_option "选择发行版" ubuntu debian arch fedora alpine)
  DISTRO_NAME="$distro"
  apply_distro_preset

  if [ "$action" = "只打印安装建议" ]; then
    PRINT_INSTALL_GUIDE=1
    return 0
  fi

  if [ "$action" = "下载rootfs后启动" ]; then
    rootfs_input=$(ask_text "输入rootfs目录(默认 /data/local/chroot/$distro)")
    [ -z "$rootfs_input" ] && rootfs_input="/data/local/chroot/$distro"
    TARGET="$rootfs_input"
    url=$(ask_text "输入${distro} rootfs下载URL(arm64 tar包)")
    if [ -z "$url" ]; then
      echo "未提供URL，尝试使用Termux内置发行版源(proot-distro)下载: $distro" >&2
      if bootstrap_rootfs_from_termux_source "$distro"; then
        echo "已通过Termux内置源完成rootfs准备: $TARGET" >&2
      else
        echo "错误: 无URL且无法使用proot-distro内置源。请先执行 'pkg install proot-distro' 或提供rootfs URL。" >&2
        exit 2
      fi
    else
      echo "开始下载并解压rootfs到: $TARGET" >&2
      download_rootfs_archive "$url" "$TARGET" || { echo "错误: rootfs下载/解压失败" >&2; exit 2; }
    fi
  fi

  permissive_choice=$(choose_option "SELinux模式" "permissive(推荐)" "保持当前")
  [ "$permissive_choice" = "permissive(推荐)" ] && PERMISSIVE=1

  ro_choice=$(choose_option "/data挂载模式" "读写" "只读")
  [ "$ro_choice" = "只读" ] && RO_DATA=1

  fallback_choice=$(choose_option "chroot失败回退proot?" "否(纯原生chroot)" "是(兼容)")
  [ "$fallback_choice" = "是(兼容)" ] && FALLBACK_PROOT=1 || FALLBACK_PROOT=0
}

if [ "$INTERACTIVE_MODE" -eq 1 ]; then
  interactive_wizard
else
  apply_distro_preset
fi
if [ "$PRINT_INSTALL_GUIDE" -eq 1 ]; then
  print_install_guide
  exit 0
fi

log() {
  local content="[$(date '+%H:%M:%S')] $1"
  echo -e "$content" | tee -a "$LOG_FILE"
}

echo_info() { log "\e[32m[INFO]\e[0m $1"; }
echo_warn() { log "\e[33m[WARN]\e[0m $1"; }
echo_err()  {
  log "\e[31m[ERROR]\e[0m $1"
  if [ "$IN_CLEANUP" -eq 0 ]; then
    cleanup
  fi
  exit 1
}

is_mounted() {
  local dst="$1"
  grep -Fq " $dst " /proc/self/mountinfo
}

get_mount_opts() {
  local dst="$1"
  awk -v p="$dst" '$2==p {print $4; exit}' /proc/mounts
}

# 读取 mountinfo optional fields（"-" 前的字段）判断传播属性
get_propagation() {
  local dst="$1"
  local line
  line=$(grep -F " $dst " /proc/self/mountinfo | tail -1)
  [ -z "$line" ] && { echo "unknown"; return; }

  local optional
  optional=$(echo "$line" | awk -F' - ' '{print $1}' | cut -d' ' -f7-)
  case "$optional" in
    *shared:*) echo "shared" ;;
    *master:*) echo "slave" ;;
    *) echo "private" ;;
  esac
}

check_cmds() {
  local missing=0
  local cmds=(unshare mount umount awk grep readlink)
  local c
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { echo_warn "缺少命令: $c"; missing=1; }
  done
  [ ! -x "$CHROOT_BIN" ] && { echo_warn "缺少可用chroot命令: $CHROOT_BIN"; missing=1; }
  [ "$missing" -eq 1 ] && echo_err "依赖命令不完整，无法安全执行"
}

check_selinux() {
  if [ -x /system/bin/getenforce ]; then
    ORIGINAL_SELINUX_STATE=$(getenforce)
    echo_info "当前SELinux状态: $ORIGINAL_SELINUX_STATE"

    if [ "$PERMISSIVE" -eq 1 ]; then
      echo_warn "⚠️ 临时切换SELinux为Permissive，退出自动恢复"
      setenforce 0 2>/dev/null || echo_warn "setenforce 0 失败，请确认KernelSU root策略"
    elif [ "$ORIGINAL_SELINUX_STATE" = "Enforcing" ]; then
      echo_warn "SELinux Enforcing 可能限制部分路径写入（可加 --permissive）"
    fi
  fi
}

preflight_chroot() {
  local owner
  owner=$(stat -c "%u:%g" "$TARGET" 2>/dev/null || echo "unknown")
  [ "$owner" != "0:0" ] && echo_warn "rootfs目录属主不是root($owner)，可能导致chroot被拒绝"
  [ ! -x "$TARGET/bin/bash" ] && echo_err "rootfs缺少可执行 /bin/bash，请检查你下载/解压的rootfs是否完整"

  # 仅检测 chroot syscall 能力，避免在完成大量挂载后才失败
  local preflight_err=""
  preflight_err=$("$CHROOT_BIN" / /system/bin/sh -c "exit 0" 2>&1 1>/dev/null)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    local seccomp_mode
    local no_new_privs
    local selctx
    seccomp_mode=$(awk '/^Seccomp:/ {print $2}' /proc/self/status 2>/dev/null || echo "unknown")
    no_new_privs=$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || echo "unknown")
    # /proc/self/attr/current 在部分内核会包含结尾 NUL，直接命令替换会触发
    # "ignored null byte in input" 警告；这里显式剔除 NUL，避免误报噪音。
    selctx=$(tr -d '\000' < /proc/self/attr/current 2>/dev/null || echo "unknown")
    preflight_err=$(echo "$preflight_err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    [ -z "$preflight_err" ] && preflight_err="(无stderr输出)"
    echo_warn "预检诊断: seccomp=$seccomp_mode no_new_privs=$no_new_privs selinux_ctx=$selctx chroot_stderr=$preflight_err"
    if echo "$preflight_err" | grep -q "cannot change root directory to '/': Operation not permitted"; then
      if [ "$FALLBACK_PROOT" -eq 1 ] && command -v proot-distro >/dev/null 2>&1; then
        USE_PROOT_FALLBACK=1
        echo_warn "检测到当前su上下文完全禁止chroot(/也被拒绝)，将自动回退到 proot-distro login ubuntu"
        return 0
      fi
      echo_err "预检失败：当前su上下文(如 u:r:ksu:s0)完全禁止chroot syscall（连 chroot / 都被拒绝）。请改用 adb shell su 0 / 更高权限shell；如你接受兼容模式，可加 --proot-fallback。"
    fi
    if [ "$seccomp_mode" = "2" ]; then
      echo_err "预检失败：当前进程受seccomp过滤(模式2)，chroot syscall被拦截。请改用不受APP seccomp限制的root shell（如 adb shell su 0）或改用proot。"
    fi
    if [ -x /system/bin/getenforce ] && [ "$(getenforce)" = "Enforcing" ] && [ "$PERMISSIVE" -eq 0 ]; then
      echo_err "预检失败：SELinux=Enforcing时chroot被拒绝，请使用 --permissive"
    fi
    if [ "$FALLBACK_PROOT" -eq 1 ] && command -v proot-distro >/dev/null 2>&1; then
      USE_PROOT_FALLBACK=1
      echo_warn "当前环境不允许chroot syscall(退出码$rc)，将自动回退到 proot-distro login ubuntu"
      return 0
    fi
    echo_err "预检失败：当前环境不允许chroot syscall(退出码$rc)，请检查KernelSU策略/SELinux/seccomp"
  fi
}

run_proot_fallback() {
  echo_warn "已进入兼容回退模式（proot），非原生chroot能力模型"
  echo_info "执行: proot-distro login ubuntu"
  exec proot-distro login ubuntu
}

prepare_chroot_compat() {
  local run_parts_wrapper="$TARGET/usr/local/bin/run-parts"
  local pidof_wrapper="$TARGET/usr/local/bin/pidof"

  if [ ! -x "$TARGET/usr/bin/run-parts" ] && [ ! -x "$TARGET/bin/run-parts" ]; then
    mkdir -p "$TARGET/usr/local/bin" 2>/dev/null || true
    cat > "$run_parts_wrapper" <<'EOF'
#!/bin/sh
# minimal run-parts fallback for slim rootfs: execute executable files in directory
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) dir="$arg" ;;
  esac
done
[ -n "${dir:-}" ] || exit 0
[ -d "$dir" ] || exit 0
for f in "$dir"/*; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || continue
  "$f"
done
EOF
    chmod 755 "$run_parts_wrapper" 2>/dev/null || true
    echo_warn "rootfs缺少 run-parts，已注入最小兼容实现: /usr/local/bin/run-parts"
  fi

  if [ ! -x "$TARGET/usr/bin/pidof" ] && [ ! -x "$TARGET/bin/pidof" ] && [ ! -x "$TARGET/sbin/pidof" ]; then
    if [ -x /system/bin/pidof ]; then
      mkdir -p "$TARGET/usr/local/bin" 2>/dev/null || true
      cat > "$pidof_wrapper" <<'EOF'
#!/bin/sh
exec /android_root/system/bin/pidof "$@"
EOF
      chmod 755 "$pidof_wrapper" 2>/dev/null || true
      echo_warn "rootfs缺少 pidof，已注入兼容包装器: /usr/local/bin/pidof -> /android_root/system/bin/pidof"
    elif [ -x /system/bin/toybox ]; then
      mkdir -p "$TARGET/usr/local/bin" 2>/dev/null || true
      cat > "$pidof_wrapper" <<'EOF'
#!/bin/sh
exec /android_root/system/bin/toybox pidof "$@"
EOF
      chmod 755 "$pidof_wrapper" 2>/dev/null || true
      echo_warn "rootfs缺少 pidof，已注入兼容包装器: /usr/local/bin/pidof -> /android_root/system/bin/toybox pidof"
    else
      echo_warn "rootfs缺少 pidof，且宿主 /system/bin/pidof 不存在"
    fi
  fi
}

get_rootfs_sshd_port() {
  local cfg="$TARGET/etc/ssh/sshd_config"
  if [ -f "$cfg" ]; then
    awk '
      /^[[:space:]]*#/ {next}
      tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}
    ' "$cfg" 2>/dev/null
    return 0
  fi
  echo "22"
}

prepare_and_start_sshd() {
  local sshd_bin=""
  local cand
  local port
  local check_err

  for cand in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd /bin/sshd; do
    if [ -x "$TARGET$cand" ]; then
      sshd_bin="$cand"
      break
    fi
  done

  [ -z "$sshd_bin" ] && return 0

  mkdir -p "$TARGET/run/sshd" 2>/dev/null || true
  chmod 755 "$TARGET/run/sshd" 2>/dev/null || true

  check_err=$("$CHROOT_BIN" "$TARGET" /usr/bin/env -i PATH="$CHROOT_EXEC_PATH" /bin/sh -c \
    "mkdir -p /run/sshd && chmod 755 /run/sshd && \
     if command -v ssh-keygen >/dev/null 2>&1; then ssh-keygen -A >/dev/null 2>&1 || true; fi && \
     $sshd_bin -t" 2>&1 1>/dev/null || true)

  if [ -n "$check_err" ]; then
    echo_warn "sshd配置预检有告警: $(echo "$check_err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  fi

  "$CHROOT_BIN" "$TARGET" /usr/bin/env -i PATH="$CHROOT_EXEC_PATH" /bin/sh -c \
    "if command -v pgrep >/dev/null 2>&1; then pgrep -x sshd >/dev/null 2>&1; \
     elif command -v pidof >/dev/null 2>&1; then pidof sshd >/dev/null 2>&1; \
     else ps -ef 2>/dev/null | grep -q '[s]shd'; fi" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    "$CHROOT_BIN" "$TARGET" /usr/bin/env -i PATH="$CHROOT_EXEC_PATH" /bin/sh -c \
      "$sshd_bin >/dev/null 2>&1" || true
  fi

  port=$(get_rootfs_sshd_port)
  [ -z "$port" ] && port="22"
  "$CHROOT_BIN" "$TARGET" /usr/bin/env -i PATH="$CHROOT_EXEC_PATH" /bin/sh -c \
    "if command -v pgrep >/dev/null 2>&1; then pgrep -x sshd >/dev/null 2>&1; \
     elif command -v pidof >/dev/null 2>&1; then pidof sshd >/dev/null 2>&1; \
     else ps -ef 2>/dev/null | grep -q '[s]shd'; fi" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo_info "SSH自检: 已准备 /run/sshd，sshd运行中 (Port: $port)"
  else
    echo_warn "SSH自检: 已尝试启动 sshd，但未确认存活 (Port: $port)，请在chroot内执行 'sshd -t' 排查"
  fi
}

# 安卓分区路径兼容：只在路径真实存在时返回
resolve_mount_path() {
  local candidate="$1"
  [ -e "$candidate" ] && echo "$candidate" && return

  case "$candidate" in
    /system)
      [ -e /system_root/system ] && echo "/system_root/system" && return
      ;;
    /vendor)
      [ -e /system/vendor ] && echo "/system/vendor" && return
      ;;
    /product)
      [ -e /system/product ] && echo "/system/product" && return
      ;;
  esac

  echo ""
}

do_mount() {
  local src="$1" dst="$2" type="$3" opt="$4"

  [ -z "$src" ] && return 0
  if [ "$type" = "bind" ] && [ ! -e "$src" ]; then
    echo_warn "源路径不存在，跳过: $src"
    return 0
  fi

  if [ ! -e "$dst" ]; then
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if [ -d "$src" ]; then
      mkdir -p "$dst"
    else
      : > "$dst"
    fi
  fi

  if is_mounted "$dst"; then
    echo_warn "已挂载，跳过: $dst"
    return 0
  fi

  if [ "$type" = "bind" ]; then
    mount --bind "$src" "$dst" || echo_err "bind挂载失败: $src -> $dst"

    if [ -n "$opt" ]; then
      mount -o "remount,bind,$opt" "$dst" || {
        echo_warn "remount失败，回退只读: $dst"
        mount -o remount,bind,ro "$dst" 2>/dev/null || echo_err "回退只读失败: $dst"
      }
    fi
  else
    mount -t "$type" -o "$opt" "$src" "$dst" || echo_err "挂载失败: $src -> $dst"
  fi

  if ! mount --make-private "$dst" 2>/dev/null; then
    local check_prop
    check_prop=$(get_propagation "$dst")
    [ "$check_prop" != "private" ] && echo_warn "make-private失败且当前非private: $dst"
  fi

  local actual_opt actual_prop
  actual_opt=$(get_mount_opts "$dst")
  actual_prop=$(get_propagation "$dst")
  echo_info "挂载成功: $src -> $dst [权限: ${actual_opt:-unknown}] [传播: ${actual_prop:-unknown}]"

  MOUNT_STACK+=("$dst")
}

chroot_pids() {
  local p link
  for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    link=$(readlink "$p/root" 2>/dev/null || true)
    case "$link" in
      "$TARGET"* ) echo "${p##*/}" ;;
    esac
  done
}

kill_pid_tree() {
  local sig="$1" pid="$2" child
  kill "-$sig" "$pid" 2>/dev/null || true
  for child in $(ps -o pid= -o ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
    kill_pid_tree "$sig" "$child"
  done
}

cleanup() {
  [ "$CLEANUP_DONE" -eq 1 ] && return 0
  IN_CLEANUP=1
  CLEANUP_DONE=1
  echo
  echo_info "触发安全清理机制..."

  if [ -n "$ORIGINAL_SELINUX_STATE" ] && [ -x /system/bin/setenforce ]; then
    if [ "$ORIGINAL_SELINUX_STATE" = "Enforcing" ]; then
      setenforce 1 2>/dev/null || true
    else
      setenforce 0 2>/dev/null || true
    fi
    echo_info "已恢复SELinux状态: $ORIGINAL_SELINUX_STATE"
  fi

  if [ "${#MOUNT_STACK[@]}" -gt 0 ]; then
    local retry pids pid
    for retry in 1 2 3; do
      pids="$(chroot_pids | xargs 2>/dev/null || true)"
      [ -z "$pids" ] && break

      if [ "$retry" -lt 3 ]; then
        echo_info "第$retry轮优雅终止: $pids"
        for pid in $pids; do kill_pid_tree TERM "$pid"; done
        sleep 1
      else
        echo_warn "第$retry轮强制终止: $pids"
        for pid in $pids; do kill_pid_tree KILL "$pid"; done
        sleep 0.5
      fi
    done
  fi

  local i mnt
  for ((i=${#MOUNT_STACK[@]}-1; i>=0; i--)); do
    mnt="${MOUNT_STACK[$i]}"
    if is_mounted "$mnt"; then
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    fi
  done

  rm -f "$TARGET$CHROOT_MARKER" 2>/dev/null || true

  local residual
  residual=$(grep -F " $TARGET" /proc/self/mountinfo | wc -l)
  if [ "$residual" -gt 0 ]; then
    echo_warn "检测到残留挂载: $residual"
    grep -F " $TARGET" /proc/self/mountinfo | tee -a "$LOG_FILE"
  else
    echo_info "✅ 挂载已清理"
  fi

  log "会话结束，日志: $LOG_FILE"
}

if [ -z "${_ISOLATED_NAMESPACE:-}" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要root后再进入命名空间。请用: su -c $0 [参数]" >&2
    exit 1
  fi
  export _ISOLATED_NAMESPACE=1
  if unshare --help 2>&1 | grep -q -- "--propagation"; then
    exec unshare --mount --propagation private env _ISOLATED_NAMESPACE=1 "$0" "$@"
  fi
  exec unshare -m env _ISOLATED_NAMESPACE=1 "$0" "$@"
fi

trap cleanup EXIT SIGINT SIGTERM SIGHUP QUIT

check_cmds
[ "$(id -u)" -ne 0 ] && echo_err "必须使用root权限执行（KernelSU/su）"
[ ! -d "$TARGET" ] && echo_err "rootfs目录不存在: $TARGET（可用 --rootfs 指定自定义rootfs路径）"

if [ -f "$CHROOT_MARKER" ] || grep -Fq " $TARGET " /proc/self/mountinfo 2>/dev/null; then
  echo_err "检测到疑似嵌套chroot，已拒绝执行"
fi

check_selinux
preflight_chroot
if [ "$USE_PROOT_FALLBACK" -eq 1 ]; then
  run_proot_fallback
fi

if ! mount --make-rprivate / 2>/dev/null; then
  root_prop=$(get_propagation "/")
  [ "$root_prop" != "private" ] && echo_warn "make-rprivate / 失败且根传播非private，隔离性可能下降"
fi
echo_info "已锁定根目录传播属性为private"

echo_info "开始构建MCP专属Chroot环境..."

do_mount "proc" "$TARGET/proc" "proc" "nosuid,noexec,nodev"
do_mount "sysfs" "$TARGET/sys" "sysfs" "nosuid,noexec,nodev,ro"

do_mount "/dev" "$TARGET/dev" "bind" "nosuid,noexec"
mkdir -p "$TARGET/dev/pts"
do_mount "devpts" "$TARGET/dev/pts" "devpts" "nosuid,noexec,newinstance,ptmxmode=0666"

do_mount "tmpfs" "$TARGET/tmp" "tmpfs" "nosuid,nodev,mode=1777"
do_mount "tmpfs" "$TARGET/run" "tmpfs" "nosuid,nodev,mode=755,size=200M"
do_mount "tmpfs" "$TARGET/dev/shm" "tmpfs" "nosuid,nodev,size=100M"

do_mount "/" "$TARGET/android_root" "bind" "$HOST_ROOT_OPT"

if [ "$RO_DATA" -eq 1 ]; then
  DATA_MOUNT_OPT="ro"
  echo_warn "⚠️ 已启用/data只读模式"
fi
do_mount "/data" "$TARGET/android_data" "bind" "$DATA_MOUNT_OPT"

REAL_SYSTEM=$(resolve_mount_path "/system")
REAL_VENDOR=$(resolve_mount_path "/vendor")
REAL_PRODUCT=$(resolve_mount_path "/product")
REAL_ODM=$(resolve_mount_path "/odm")
REAL_BOOT=$(resolve_mount_path "/boot")

do_mount "$REAL_SYSTEM" "$TARGET/android_system" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_VENDOR" "$TARGET/android_vendor" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_PRODUCT" "$TARGET/android_product" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_ODM" "$TARGET/android_odm" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_BOOT" "$TARGET/android_boot" "bind" "$SYS_MOUNT_OPT"

if [ -d "/storage/emulated/0" ]; then
  do_mount "/storage/emulated/0" "$TARGET/sdcard" "bind" "$SDCARD_MOUNT_OPT"
fi

if [ -f "/etc/resolv.conf" ]; then
  do_mount "/etc/resolv.conf" "$TARGET/etc/resolv.conf" "bind" "ro"
fi

touch "$TARGET$CHROOT_MARKER"
prepare_chroot_compat
CHROOT_EXEC_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/android_root/system/bin:/android_root/system/xbin:/android_root/apex/com.android.runtime/bin"
prepare_and_start_sshd

echo_info "✅ 环境构建完成"
echo_info "   /android_root    -> / [默认ro]"
echo_info "   /android_data    -> /data [默认rw，可 --ro-data]"
echo_info "   /android_system  -> system类分区 [默认ro]"
echo_info "   /dev             -> 完整设备节点"
echo_info "   /sdcard          -> 内置存储 [默认rw]"
echo_info "提示: 修改系统前手动 remount,rw，用完 remount,ro"

echo_info "🚀 进入Ubuntu chroot，exit 可安全退出"

cd "$TARGET" || echo_err "切换到chroot根目录失败"
if [ -x "$TARGET/usr/bin/run-parts" ] || [ -x "$TARGET/bin/run-parts" ]; then
  "$CHROOT_BIN" "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm-256color}" PATH="$CHROOT_EXEC_PATH" /bin/bash -l
else
  echo_warn "rootfs内缺少 run-parts，跳过login shell初始化以避免报错（可在容器内安装 debianutils 后恢复 -l）"
  "$CHROOT_BIN" "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm-256color}" PATH="$CHROOT_EXEC_PATH" /bin/bash
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ -x /system/bin/getenforce ] && [ "$(getenforce)" = "Enforcing" ] && [ "$PERMISSIVE" -eq 0 ]; then
    echo_err "chroot失败(EPERM概率高)：当前SELinux=Enforcing，请改用 --permissive 重试"
  fi
  owner_now=$(stat -c "%u:%g" "$TARGET" 2>/dev/null || echo "unknown")
  echo_err "chroot启动失败，退出码: $rc；请检查KernelSU授权、rootfs属主(当前$owner_now)及SELinux策略"
fi

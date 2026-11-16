#!/bin/bash
#
# 【风扇控制 / iFeng】安装脚本 —— 需要管理员权限
#
#   sudo bash install.sh
#
# 做四件事：
#   1. 把 fanctl 装到 /usr/local/bin 并设为 setuid root（写 SMC 必需）
#   2. 把 风扇控制.app 复制到 /Applications
#   3. 自检 SMC 可读性
#   4. 以当前登录用户身份启动
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="风扇控制.app"
BIN="iFeng"
BUILD_DIR="build"

# 登录用户：App 要归他所有，否则应用内自动更新无法替换自身
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || echo "")"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要管理员权限，请执行：sudo bash install.sh"
    exit 1
fi

if [ ! -x "$BUILD_DIR/fanctl" ]; then
    echo "错误：未找到 build/fanctl，请先执行 bash build.sh"
    exit 1
fi
if [ ! -d "$BUILD_DIR/$APP_NAME" ]; then
    echo "错误：未找到 build/$APP_NAME，请先执行 bash build.sh"
    exit 1
fi

echo "==> [1/4] 安装 fanctl 到 /usr/local/bin（setuid root）"
install -d -o root -g wheel -m 755 /usr/local/bin
install -o root -g wheel -m 4755 "$BUILD_DIR/fanctl" /usr/local/bin/fanctl
ls -l /usr/local/bin/fanctl

echo "==> [2/4] 安装 $APP_NAME 到 /Applications"
rm -rf "/Applications/$APP_NAME"
cp -R "$BUILD_DIR/$APP_NAME" "/Applications/$APP_NAME"
xattr -dr com.apple.quarantine "/Applications/$APP_NAME" 2>/dev/null || true
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    chown -R "$CONSOLE_USER":staff "/Applications/$APP_NAME"
fi
codesign --force --deep --sign - "/Applications/$APP_NAME" 2>/dev/null || true

echo "==> [3/4] 自检"
echo ""
/usr/local/bin/fanctl diag || true
echo ""

echo "==> [4/4] 启动"
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || echo "")"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    sudo -u "$CONSOLE_USER" open -a "/Applications/$APP_NAME"
else
    open -a "/Applications/$APP_NAME"
fi

echo ""
echo "安装完成。菜单栏右上角出现风扇图标，点击即可调节。"
echo "卸载：sudo bash uninstall.sh"

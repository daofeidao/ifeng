#!/bin/bash
#
# 【风扇控制 / iFeng】覆盖安装 —— 需 root（sudo bash publish.sh）
#
#  1. 安装新版 fanctl 到 /usr/local/bin（setuid root，写 SMC 必需）
#  2. 覆盖安装 App 到 /Applications
#  3. 删除桌面上的旧副本
#  4. 自检并启动
#
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="风扇控制.app"
OWNER_USER="${SUDO_USER:-lion}"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要管理员权限，请执行：sudo bash $0"
    exit 1
fi

echo "==> [1/5] 停止正在运行的实例"
pkill -x iFeng 2>/dev/null || true
sleep 1

echo "==> [2/5] 安装 fanctl（setuid root）"
install -d -o root -g wheel -m 755 /usr/local/bin
install -o root -g wheel -m 4755 "$SRC/build/fanctl" /usr/local/bin/fanctl
ls -l /usr/local/bin/fanctl

echo "==> [3/5] 覆盖安装到 /Applications"
rm -rf "/Applications/$APP_NAME"
cp -R "$SRC/build/$APP_NAME" "/Applications/$APP_NAME"
chown -R "$OWNER_USER":staff "/Applications/$APP_NAME"
xattr -dr com.apple.quarantine "/Applications/$APP_NAME" 2>/dev/null || true
codesign --force --deep --sign - "/Applications/$APP_NAME" 2>/dev/null || true
ls -ld "/Applications/$APP_NAME"

echo "==> [4/5] 刷新桌面副本（~/Desktop/app）"
DESK_DIR="/Users/$OWNER_USER/Desktop/app"
mkdir -p "$DESK_DIR"
rm -rf "$DESK_DIR/$APP_NAME"
ditto "/Applications/$APP_NAME" "$DESK_DIR/$APP_NAME"
chown -R "$OWNER_USER":staff "$DESK_DIR/$APP_NAME" 2>/dev/null || true
xattr -cr "$DESK_DIR/$APP_NAME" 2>/dev/null || true
echo "    $DESK_DIR/$APP_NAME"

echo "==> [5/5] 自检"
/usr/local/bin/fanctl diag || true

echo ""
echo "以 $OWNER_USER 身份启动"
launchctl asuser "$(id -u "$OWNER_USER")" open -a "/Applications/$APP_NAME" 2>/dev/null || \
    sudo -u "$OWNER_USER" open -a "/Applications/$APP_NAME" || true

echo "完成。"

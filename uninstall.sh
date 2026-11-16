#!/bin/bash
#
# 【风扇控制 / iFeng】卸载脚本
#
#   sudo bash uninstall.sh
#
set -euo pipefail

APP_NAME="风扇控制.app"
LABEL="com.local.ifeng"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要管理员权限，请执行：sudo bash uninstall.sh"
    exit 1
fi

echo "==> 把风扇交还系统控制"
if [ -x /usr/local/bin/fanctl ]; then
    /usr/local/bin/fanctl auto all || true
fi

echo "==> 结束进程"
pkill -x iFeng 2>/dev/null || true

echo "==> 移除登录项"
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || echo "")"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    USER_HOME="$(dscl . -read /Users/"$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')"
    PLIST="$USER_HOME/Library/LaunchAgents/$LABEL.plist"
    if [ -f "$PLIST" ]; then
        UID_NUM="$(id -u "$CONSOLE_USER")"
        sudo -u "$CONSOLE_USER" launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        echo "    已移除 $PLIST"
    fi
fi

echo "==> 删除文件"
rm -rf "/Applications/$APP_NAME"
rm -f /usr/local/bin/fanctl

echo "==> 清理偏好设置"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    sudo -u "$CONSOLE_USER" defaults delete com.local.ifeng 2>/dev/null || true
fi

echo "卸载完成。"

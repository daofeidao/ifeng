#!/bin/bash
#
# 【风扇控制 / iFeng】构建脚本 —— 必须在 Mac 上执行（本地或 GitHub Actions）
#
#   bash build.sh                # 本机架构
#   UNIVERSAL=1 bash build.sh    # Intel + Apple Silicon 通用二进制
#
# 产物：
#   build/风扇控制.app        （内含 Resources/fanctl 辅助工具）
#   dist/风扇控制-<版本>.zip   （可直接分发 / 拖进「应用程序」）
#
set -euo pipefail
cd "$(dirname "$0")"

APP="build/风扇控制.app"
BIN="iFeng"
ARCH="$(uname -m)"
VERSION="2.0.1"
UNIVERSAL="${UNIVERSAL:-0}"
SOURCES="src/App.swift src/Fanctl.swift src/FanModel.swift src/ContentView.swift src/Updater.swift src/NetMonitor.swift src/StatusBar.swift"

echo "==> 环境检查"
if ! command -v clang >/dev/null 2>&1; then
    echo "错误：找不到 clang。请安装 Xcode 命令行工具：xcode-select --install"
    exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "错误：找不到 swiftc。若已装 Xcode，请执行："
    echo "      sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi
echo "    swiftc : $(swiftc --version | head -1)"
echo "    架构   : ${ARCH}（UNIVERSAL=${UNIVERSAL}）"
echo "    系统   : $(sw_vers -productVersion)"

mkdir -p build

echo "==> 编译 fanctl（C / IOKit）"
if [ "$UNIVERSAL" = "1" ]; then
    clang -O2 -Wall -Wextra -Wno-unused-parameter \
          -arch x86_64 -arch arm64 \
          -o build/fanctl src/fanctl.c \
          -framework IOKit -framework CoreFoundation
else
    clang -O2 -Wall -Wextra -Wno-unused-parameter \
          -o build/fanctl src/fanctl.c \
          -framework IOKit -framework CoreFoundation
fi
echo "    OK -> build/fanctl ($(lipo -archs build/fanctl 2>/dev/null || echo "$ARCH"))"

echo "==> 编译 风扇控制.app（Swift / SwiftUI）"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

if [ "$UNIVERSAL" = "1" ]; then
    swiftc -O -swift-version 5 -parse-as-library \
           -target x86_64-apple-macos13.0 -o build/iFeng-x86 $SOURCES
    swiftc -O -swift-version 5 -parse-as-library \
           -target arm64-apple-macos13.0 -o build/iFeng-arm $SOURCES
    lipo -create -output "$APP/Contents/MacOS/${BIN}" build/iFeng-x86 build/iFeng-arm
else
    swiftc -O -swift-version 5 -parse-as-library \
           -target "${ARCH}-apple-macos13.0" \
           -o "$APP/Contents/MacOS/${BIN}" $SOURCES
fi

echo "==> 内嵌 fanctl 到 App 资源（供「一键启用」使用）"
cp build/fanctl "$APP/Contents/Resources/fanctl"
chmod 755 "$APP/Contents/Resources/fanctl"
echo "    已嵌入 $(du -h "$APP/Contents/Resources/fanctl" | awk '{print $1}')"

if [ -f assets/icon-1024.png ]; then
    echo "==> 生成 AppIcon.icns"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z "$((s * 2))" "$((s * 2))" assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    echo "    OK -> AppIcon.icns ($(du -h "$APP/Contents/Resources/AppIcon.icns" | awk '{print $1}'))"
else
    echo "==> 跳过图标（assets/icon-1024.png 不存在）"
fi

echo "==> ad-hoc 签名（必须在嵌入资源之后）"
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
    echo "    已签名（ad-hoc）"
else
    echo "    ad-hoc 签名失败，本地运行通常不受影响，继续"
fi

echo "==> 校验产物"
echo "    App 架构: $(lipo -archs "$APP/Contents/MacOS/${BIN}" 2>/dev/null || echo unknown)"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "    签名校验: 通过"
else
    echo "    签名校验: 未通过（不影响本地运行）"
fi

echo "==> 打包 zip"
mkdir -p dist
ZIP="dist/iFeng-${VERSION}.zip"
rm -f "$ZIP"
# ditto 保留可执行权限、符号链接与扩展属性，解压后即可直接双击运行
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "    OK -> $ZIP ($(du -h "$ZIP" | awk '{print $1}'))"

# 投放（用户约定：成品直接放 ~/Desktop/myapp/）
DELIVER_USER="${SUDO_USER:-$USER}"
DELIVER_HOME="$(eval echo "~${DELIVER_USER}")"
if [ -d "$DELIVER_HOME/Desktop" ]; then
    DESK_DIR="$DELIVER_HOME/Desktop/myapp"
    mkdir -p "$DESK_DIR"
    rm -rf "$DESK_DIR/风扇控制.app"
    ditto "$APP" "$DESK_DIR/风扇控制.app"
    xattr -cr "$DESK_DIR/风扇控制.app" 2>/dev/null || true
    echo "==> 已投放到桌面：$DESK_DIR/风扇控制.app"
else
    echo "==> 跳过桌面投放（未找到 $DELIVER_HOME/Desktop）"
fi

echo ""
echo "构建完成。产物："
echo "    $(pwd)/$APP"
echo "    $(pwd)/$ZIP"
echo "    桌面副本：$DELIVER_HOME/Desktop/myapp/风扇控制.app"
echo ""
echo "本机安装（写入 /usr/local/bin，需要管理员密码）："
echo "    sudo bash install.sh"
echo "也可以不装脚本：双击桌面副本，打开后在「设置」里点「一键启用风扇写入」。"

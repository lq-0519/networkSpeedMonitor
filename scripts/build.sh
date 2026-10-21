#!/bin/bash
set -euo pipefail

# 固定已存在的本机证书指纹；证书缺失时停止，保持所有升级的授权身份一致。
SIGNING_IDENTITY="659A2CD838DF7ADCB88F313BDE6572A223C4923C"
# 主程序、登录项和偏好使用同一个不可变 Bundle ID。
BUNDLE_ID="com.local.NetworkSpeedMonitor"
# 安装路径是应用长期运行的位置，不从临时构建目录启动。
INSTALL_PATH="/Applications/NetworkSpeedMonitor.app"
# 从脚本位置定位项目，允许在任意工作目录执行。
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 中间产物全部在仓库外，退出时自动清理。
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/network-speed-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "$SIGNING_IDENTITY"; then
    echo "缺少固定签名证书 InputHoldSwitcher Local Code Signing。" >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJECT_DIR/Info.plist")" != "$BUNDLE_ID" ]]; then
    echo "Bundle ID 不匹配，停止构建。" >&2
    exit 1
fi

# 零第三方依赖的原生 Swift 构建，不执行 Go/包管理器依赖冷编译。
APP_DIR="$BUILD_DIR/NetworkSpeedMonitor.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Library/LaunchServices" "$BUILD_DIR/modules"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$PROJECT_DIR/Sources/NetworkSampler.c" "$PROJECT_DIR/Sources/NativeRoutes.c" \
    -o "$APP_DIR/Contents/MacOS/NetworkSampler"
/usr/bin/xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/modules" \
    -framework Foundation \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PROJECT_DIR/Helper/Info.plist" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist -Xlinker "$PROJECT_DIR/Helper/Launchd.plist" \
    "$PROJECT_DIR"/Shared/*.swift "$PROJECT_DIR/Helper/main.swift" \
    -o "$APP_DIR/Contents/Library/LaunchServices/com.local.NetworkSpeedMonitor.CPUHelper"
/usr/bin/xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/modules" \
    -framework AppKit -framework Network -framework SystemConfiguration -framework ServiceManagement -framework Security -framework IOKit -lsqlite3 -lz \
    "$PROJECT_DIR"/Shared/*.swift "$PROJECT_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/NetworkSpeedMonitor"
/usr/bin/codesign --force --timestamp=none --identifier com.local.NetworkSpeedMonitor.CPUHelper \
    --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/Library/LaunchServices/com.local.NetworkSpeedMonitor.CPUHelper"
/usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/MacOS/NetworkSampler"
/usr/bin/codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict \
    -R "=identifier \"$BUNDLE_ID\" and certificate root = H\"$SIGNING_IDENTITY\"" "$APP_DIR"
"$APP_DIR/Contents/MacOS/NetworkSpeedMonitor" --self-check

if [[ "${1:-}" == "--install" || "${1:-}" == "--run" ]]; then
    # 更新前校验已有安装身份，防止意外覆盖同名的其他软件。
    if [[ -e "$INSTALL_PATH" ]]; then
        /usr/bin/codesign --verify --deep --strict \
            -R "=identifier \"$BUNDLE_ID\" and certificate root = H\"$SIGNING_IDENTITY\"" "$INSTALL_PATH"
    fi
    # 使用临时同卷目录准备完整安装包，构建或校验失败时不会破坏现有版本。
    STAGE_DIR="$(mktemp -d /Applications/.network-speed-stage.XXXXXX)"
    trap 'rm -rf "$BUILD_DIR" "$STAGE_DIR"' EXIT
    /usr/bin/ditto "$APP_DIR" "$STAGE_DIR/NetworkSpeedMonitor.app"
    /usr/bin/codesign --verify --deep --strict "$STAGE_DIR/NetworkSpeedMonitor.app"
    # 精确匹配固定安装路径的进程，让应用正常执行退出清理。
    /usr/bin/pkill -TERM -f '^/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor($| )' || true
    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! /usr/bin/pgrep -f '^/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor($| )' > /dev/null; then break; fi
        /bin/sleep 0.1
    done
    if /usr/bin/pgrep -f '^/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor($| )' > /dev/null; then
        echo "现有应用尚未退出，保留原安装版本。" >&2
        exit 1
    fi
    if [[ -e "$INSTALL_PATH" ]]; then /bin/mv "$INSTALL_PATH" "$STAGE_DIR/previous.app"; fi
    if ! /bin/mv "$STAGE_DIR/NetworkSpeedMonitor.app" "$INSTALL_PATH"; then
        if [[ -e "$STAGE_DIR/previous.app" ]]; then /bin/mv "$STAGE_DIR/previous.app" "$INSTALL_PATH"; fi
        exit 1
    fi
    /usr/bin/codesign --verify --deep --strict "$INSTALL_PATH"
    echo "已安装：$INSTALL_PATH"
    if [[ "${1:-}" == "--run" ]]; then /usr/bin/open "$INSTALL_PATH" --args --show; fi
else
    echo "构建与检查通过。安装运行：./scripts/build.sh --run"
fi

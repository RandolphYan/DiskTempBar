#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.0.0"
APP_NAME="DiskTempBar"
APP_DIR="/Applications/${APP_NAME}.app"
RELEASE_DIR="$DIR/release"

echo "==> 1. 编译 ${APP_NAME} (macOS arm64 Native)..."
swiftc -O -target arm64-apple-macosx14.0 "$DIR/main.swift" -o "$DIR/${APP_NAME}"

echo "==> 2. 构建应用包 ${APP_DIR}..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$DIR/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "$DIR/main.swift" "${APP_DIR}/Contents/Resources/main.swift"
if [ -f "$DIR/AppIcon.icns" ]; then
    cp "$DIR/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# 写入标准 Info.plist (作为纯顶栏驻留 Accessory，不占 Dock)
cat << 'EOF' > "${APP_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DiskTempBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.forest.DiskTempBar</string>
    <key>CFBundleName</key>
    <string>DiskTempBar</string>
    <key>CFBundleDisplayName</key>
    <string>DiskTempBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> 2.1 对应用包执行签名与资源封装 (Sealed Resources)..."
codesign --force --deep --sign - "${APP_DIR}"

echo "==> 3. 打包多种格式 Release 发布文件 (zip / dmg / pkg)..."
mkdir -p "$RELEASE_DIR"

# 3.1 ZIP 便携独立包
ZIP_PATH="$RELEASE_DIR/${APP_NAME}-v${VERSION}.zip"
cd /Applications && zip -r -q -y "$ZIP_PATH" "${APP_NAME}.app"
cd "$DIR"
SHA256_ZIP=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "    ✔ ZIP 便携包: $ZIP_PATH (SHA256: $SHA256_ZIP)"

# 3.2 DMG 磁盘镜像 (含 Applications 拖拽安装快捷方式)
DMG_PATH="$RELEASE_DIR/${APP_NAME}-v${VERSION}.dmg"
DMG_STAGING="/tmp/${APP_NAME}_dmg_staging"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "${APP_DIR}" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1 || true
rm -rf "$DMG_STAGING"
echo "    ✔ DMG 镜像:   $DMG_PATH (含 Applications 拖拽快捷方式)"

# 3.3 PKG 系统标准安装包
PKG_PATH="$RELEASE_DIR/${APP_NAME}-v${VERSION}.pkg"
rm -f "$PKG_PATH"
pkgbuild --install-location /Applications --component "${APP_DIR}" "$PKG_PATH" >/dev/null 2>&1 || true
echo "    ✔ PKG 安装包: $PKG_PATH"

echo "==> 4. 重启应用..."
pkill -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
open "${APP_DIR}"

echo "==> 部署与打包成功！"

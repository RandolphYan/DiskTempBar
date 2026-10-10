#!/bin/bash
set -e

echo "================================================="
echo "  DiskTempBar 一键安装 / 构建脚本 (macOS Native)"
echo "================================================="

# 1. 检查 Homebrew 与 smartctl
if ! command -v smartctl >/dev/null 2>&1; then
    echo "==> 检测到尚未安装 smartctl，正在通过 Homebrew 安装 smartmontools..."
    if ! command -v brew >/dev/null 2>&1; then
        echo "❌ 错误: 未检测到 Homebrew，请先安装 Homebrew (https://brew.sh) 后重试。"
        exit 1
    fi
    brew install smartmontools
else
    echo "✔ smartctl 已就绪 ($(smartctl --version | head -n 1))"
fi

# 2. 检查 swift 编译器
if ! command -v swiftc >/dev/null 2>&1; then
    echo "❌ 错误: 未检测到 Xcode Command Line Tools，请运行 'xcode-select --install' 安装。"
    exit 1
fi

# 3. 编译并安装
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/build.sh"

echo "================================================="
echo "🎉 安装完成！DiskTempBar 已在屏幕右上角菜单栏启动。"
echo "================================================="

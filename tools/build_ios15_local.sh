#!/usr/bin/env bash
# build_ios15_local.sh
#
# 在本机 macOS 上一键构建 OpenMinis 的 iOS 15.4 降级移植版，产出未签名 IPA。
# 用于「手头有 Mac」的场景，等价于 .github/workflows/build-ios15-ipa.yml。
#
# 前置要求：
#   Xcode（含 iOS SDK）、Go 1.25+、Python 3
#   brew install ninja llvm libarchive pkg-config
#   python3 -m pip install meson
#
# 用法：
#   ./tools/build_ios15_local.sh
#
# 产出：build/out/Minis-ios15.4-unsigned.ipa

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> 0/8 检查工具链"
xcodebuild -version
go version || { echo "缺少 Go 1.25+，请先安装"; exit 1; }
python3 --version

echo "==> 1/8 生成构建期配置"
cp -n src/ios/Configs/ProviderCustomization.xcconfig.example \
      src/ios/Configs/ProviderCustomization.xcconfig 2>/dev/null \
  && echo "  已生成 ProviderCustomization.xcconfig" \
  || echo "  已存在，跳过"

echo "==> 2/8 Metal Toolchain（缺失不致命）"
xcodebuild -downloadComponent MetalToolchain || echo "  下载失败，继续"

echo "==> 3/8 构建 LAME"
./deps/build_lame.sh

echo "==> 4/8 构建 FFmpeg"
./deps/build_ffmpeg.sh

echo "==> 5/8 构建 iSH 内核"
./deps/build_ish.sh

echo "==> 6/8 准备 Alpine rootfs"
./deps/prepare_alpine_rootfs.sh

echo "==> 7/8 构建 rclone"
./deps/build_rclone_ios.sh

echo "==> 8/8 构建 App 并打包 IPA"
xcodebuild \
  -project src/ios/Minis.xcodeproj \
  -scheme Minis \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  IPHONEOS_DEPLOYMENT_TARGET=15.4 \
  build

APP="$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)"
echo "APP = $APP"
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$APP/Info.plist"

rm -rf build/out && mkdir -p build/out/Payload
cp -R "$APP" build/out/Payload/
( cd build/out && zip -qry "Minis-ios15.4-unsigned.ipa" Payload )

echo
echo "完成：$(pwd)/build/out/Minis-ios15.4-unsigned.ipa"

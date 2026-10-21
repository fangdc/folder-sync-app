#!/bin/bash
# 构建 FolderSync App
#
#   ./build.sh              编译（arm64 + x86_64 通用二进制）并打包成 .app
#   ./build.sh --fast       只编译当前架构，速度快（本机自用够了）
#   ./build.sh --run        编译完直接启动 App
#   ./build.sh --install    编译后安装到 /Applications（需要管理员权限）
#   ./build.sh --test       只编译并运行同步引擎的自动化测试
#   ./build.sh --dmg        打包成可分享的 DMG（含 Applications 快捷方式），输出到桌面
#   ./build.sh --zip        打包成可分享的 zip，输出到桌面
#
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="FolderSync"
VERSION="1.1.0"
MIN_MACOS="14.0"
BUILD_DIR="build"
DIST_DIR="dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MCACHE="$PWD/$BUILD_DIR/mcache"

# 分发产物（DMG / zip）的输出目录，优先级：
#   1. ZIP_DIR 环境变量（临时指定用）
#   2. 本机的 .dist-out 文件（一行路径；已进 .gitignore，不会跟着源码公开）
#   3. 桌面
dist_output_dir() {
    if [ -n "${ZIP_DIR:-}" ]; then
        echo "$ZIP_DIR"
    elif [ -f "$PWD/.dist-out" ]; then
        head -1 "$PWD/.dist-out"
    else
        echo "$HOME/Desktop"
    fi
}

MODE="${1:-build}"
UNIVERSAL=1
[ "$MODE" = "--fast" ] && UNIVERSAL=0

mkdir -p "$BUILD_DIR" "$MCACHE"

# ---------------------------------------------------------------- 测试
if [ "$MODE" = "--test" ]; then
    echo "==> 编译同步引擎测试"
    xcrun --sdk macosx swiftc \
        -module-cache-path "$MCACHE" \
        -swift-version 5 \
        -target "$(uname -m)-apple-macos$MIN_MACOS" \
        Sources/Models.swift Sources/Formatters.swift Sources/SyncEngine.swift Tests/main.swift \
        -o "$BUILD_DIR/foldersync-tests"
    echo "==> 运行测试"
    "$BUILD_DIR/foldersync-tests"
    exit $?
fi

# ---------------------------------------------------------------- 编译
SOURCE_FILES=(Sources/*.swift)

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

if [ "$UNIVERSAL" = "1" ]; then
    ARCHS="arm64 x86_64"
    echo "==> 编译通用二进制（Apple 芯片 + Intel）"
else
    ARCHS="$(uname -m)"
    echo "==> 编译（仅 ${ARCHS}）"
fi

SLICES=()
for ARCH in $ARCHS; do
    OUT="$BUILD_DIR/$APP_NAME-$ARCH"
    echo "    - $ARCH"
    xcrun --sdk macosx swiftc \
        -module-cache-path "$MCACHE" \
        -swift-version 5 \
        -O \
        -Xfrontend -disable-sandbox \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        "${SOURCE_FILES[@]}" \
        -o "$OUT"
    SLICES+=("$OUT")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create -output "$APP_DIR/Contents/MacOS/$APP_NAME" "${SLICES[@]}"
else
    cp "${SLICES[0]}" "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

echo "==> 组装应用包"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# 图标统一由下面的 Icon Composer 工程生成，旧的 FolderSync.icns 不再使用

# macOS 26 的新图标格式：用 Icon Composer 工程（Resources/FolderSync.icon）编译出
# Assets.car + icns。只提供旧的 .icns 时，系统会判定图标不符合新规范，
# 在 Dock / Finder 里给图标外面再套一层标准底板。走这条路才是原生玻璃图标。
ICON_SRC="Resources/$APP_NAME.icon"
if [ -d "$ICON_SRC" ]; then
    echo "==> 编译图标（Icon Composer 工程）"
    rm -rf "$BUILD_DIR/iconout" "$BUILD_DIR/iconwork"
    mkdir -p "$BUILD_DIR/iconout" "$BUILD_DIR/iconwork"
    # 复制一份再改，不动 Resources 里的源工程
    cp -R "$ICON_SRC" "$BUILD_DIR/iconwork/$APP_NAME.icon"
    # Icon Composer 新建工程默认按 iOS 来（supported-platforms.squares = "shared"），
    # 每次在 Icon Composer 里保存都会把平台声明写回去，所以放在构建流程里自动修正成 macOS。
    python3 - "$BUILD_DIR/iconwork/$APP_NAME.icon/icon.json" <<'PYEOF'
import collections, json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle, object_pairs_hook=collections.OrderedDict)
    data["supported-platforms"] = collections.OrderedDict([("squares", ["macOS"])])
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print("   平台声明已修正为 macOS")
except Exception as error:
    print("   平台声明修正失败：", error)
PYEOF
    # actool 内部有个自我沙盒的辅助进程（TDDistiller）：在受限环境里它**写不了工作区**，
    # 报「You don't have permission to save the file」并把失败静默掉 ——
    # 表现是 App 少了 Assets.car，体积从 3.4M 掉到 1.4M，图标退回系统默认底板。
    # 写临时目录它是允许的，所以先编译到临时目录，再把产物拷进 App 包。
    ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/foldersync-icon.XXXXXX")"
    if xcrun actool --compile "$ICON_TMP" \
        --platform macosx --minimum-deployment-target "$MIN_MACOS" \
        --app-icon "$APP_NAME" \
        --output-partial-info-plist "$ICON_TMP/partial.plist" \
        "$PWD/$BUILD_DIR/iconwork/$APP_NAME.icon" >/dev/null 2>&1 \
        && [ -f "$ICON_TMP/Assets.car" ] && [ -f "$ICON_TMP/$APP_NAME.icns" ]; then
        cp "$ICON_TMP/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
        cp "$ICON_TMP/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
        # actool 输出的键（CFBundleIconFile / CFBundleIconName）已经写在 Resources/Info.plist 里
        echo "   Assets.car + $APP_NAME.icns"
    else
        # 不再静默失败：图标缺失在 Finder / Dock 里表现为「套了一层底板」，很难联想到打包环节
        echo "   actool 失败：图标没有生成，App 会退回系统默认图标底板"
    fi
    rm -rf "$ICON_TMP"
fi

# 只删隔离属性；不要用 -c 形式（会清全部属性，包括系统保护的
# com.apple.provenance，反而报 Operation not permitted）
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
# 签名必须成功：没有 bundle 签名的 App 在 macOS 眼里身份不稳定，
# TCC（隐私授权）记不住授权 —— 表现为「每次定时同步都弹『想访问硬盘上的文件』」。
if ! codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1; then
    echo "   ✗ 签名失败（codesign 返回非 0）—— 这样的包在系统里授权不会持久，请勿分发"
    exit 1
fi
# 复核：Identifier 必须是 Info.plist 里的 bundle id，而不是二进制切片名（如 FolderSync-arm64）
SIGN_ID="$(codesign -dvv "$APP_DIR" 2>&1 | awk -F= '/^Identifier=/{print $2}')"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist" 2>/dev/null)"
if [ "$SIGN_ID" != "$BUNDLE_ID" ]; then
    echo "   ✗ 签名标识不对：$SIGN_ID（应为 $BUNDLE_ID）—— bundle 没有被重签，授权不会持久"
    exit 1
fi
echo "   签名：$SIGN_ID"

echo "==> 完成：$APP_DIR"
echo "   架构：$(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"
echo "   体积：$(du -sh "$APP_DIR" | awk '{print $1}')"

case "$MODE" in
    --run)
        echo "==> 启动 App"
        open "$APP_DIR"
        ;;
    --install)
        echo "==> 安装到 /Applications"
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
        xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
        echo "   已安装：/Applications/$APP_NAME.app"
        ;;
    --dmg)
        echo "==> 打包分发文件（DMG）"
        # 分发用的 dmg 统一放到桌面（方便直接发给别人）；
        # 工作区里的 dist/ 只作为打包中转目录。
        OUT_DIR="$(dist_output_dir)"
        STAGE="$DIST_DIR/dmg"
        rm -rf "$DIST_DIR"
        mkdir -p "$STAGE" "$OUT_DIR"
        cp -R "$APP_DIR" "$STAGE/"
        [ -f Resources/使用说明.txt ] && cp Resources/使用说明.txt "$STAGE/使用说明.txt"
        # MIT 要求「随软件副本附带版权与许可声明」，所以许可文件也要进卷
        [ -f LICENSE ] && cp LICENSE "$STAGE/LICENSE"
        # 指向 /Applications 的软链接：打开 dmg 后可以直接把 app 拖进去安装
        ln -s /Applications "$STAGE/Applications"
        DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
        rm -f "$DMG"
        # UDZO = 压缩只读，体积小、挂载快
        hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
            -ov -format UDZO "$DMG"
        echo "   已生成：${DMG}（$(du -sh "$DMG" | awk '{print $1}')）"
        echo "   卷内含：$APP_NAME.app + 使用说明.txt + LICENSE + Applications 快捷方式"
        ;;
    --zip)
        echo "==> 打包 zip"
        OUT_DIR="$(dist_output_dir)"
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR/$APP_NAME" "$OUT_DIR"
        cp -R "$APP_DIR" "$DIST_DIR/$APP_NAME/"
        [ -f Resources/使用说明.txt ] && cp Resources/使用说明.txt "$DIST_DIR/$APP_NAME/"
        [ -f LICENSE ] && cp LICENSE "$DIST_DIR/$APP_NAME/"
        ditto -c -k --sequesterRsrc --keepParent \
              "$DIST_DIR/$APP_NAME" "$OUT_DIR/$APP_NAME-$VERSION.zip"
        echo "   已生成：$OUT_DIR/$APP_NAME-$VERSION.zip"
        ;;
esac

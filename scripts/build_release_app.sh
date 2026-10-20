#!/bin/zsh
# 构建剪坊公开预览版。输出目录已存在时拒绝覆盖。
# 用法：scripts/build_release_app.sh [--app 路径] [--log-dir 目录]
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
app="$project_root/dist/剪坊.app"
log_dir="$project_root/build-logs/release"
while (( $# )); do
  case "$1" in
    --app) app="$2"; shift 2;;
    --log-dir) log_dir="$2"; shift 2;;
    *) print -u2 "未知参数：$1"; exit 2;;
  esac
done
[[ ! -e "$app" ]] || { print -u2 "目标已存在，不覆盖：$app"; exit 1; }
[[ ! -e "$log_dir" ]] || { print -u2 "日志目录已存在，不覆盖：$log_dir"; exit 1; }
sample_media=(source01.mp4 source02.mp4 source03.mp4 tone01.wav tone02.wav tone03.wav tone04.wav srgb-chart.png srgb-chart.jpg)
for media in "${sample_media[@]}"; do
  [[ -f "fixtures/media/$media" ]] || {
    print -u2 "缺少演示素材；请先安装 Python 3 与 FFmpeg，并运行 python3 scripts/generate_fixtures.py"
    exit 1
  }
done
mkdir -p "${log_dir:h}"
mkdir "$log_dir"

# 映射编译路径，避免在分发二进制中带入构建者的主目录与源码目录。
build_flags=(--scratch-path "$project_root/.build-release" -c release --arch arm64)
swift build "${build_flags[@]}" --product IndependentEditor \
  -Xswiftc -file-prefix-map -Xswiftc "$project_root=/jianfang" \
  -Xswiftc -debug-prefix-map -Xswiftc "$project_root=/jianfang" \
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build-home" \
  -Xcc "-ffile-prefix-map=$project_root=/jianfang" \
  > "$log_dir/build.log" 2>&1
build_bin="$(swift build "${build_flags[@]}" --show-bin-path)"
mkdir -p "${app:h}"
mkdir "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Samples/media"
cp -X "$build_bin/IndependentEditor" "$app/Contents/MacOS/IndependentEditor"
strip -S "$app/Contents/MacOS/IndependentEditor"

# 只复制内置示例所需资源，测试记录、其他测试媒体和本机副本均不进 App。
for fixture in F1.json F2.json; do
  cp -X "fixtures/$fixture" "$app/Contents/Resources/Samples/$fixture"
done
for media in "${sample_media[@]}"; do
  cp -X "fixtures/media/$media" "$app/Contents/Resources/Samples/media/$media"
done
"$build_bin/IndependentEditor" app-icon "$log_dir/AppIcon.iconset" > "$log_dir/app-icon.log" 2>&1
iconutil -c icns "$log_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IndependentEditor</string>
<key>CFBundleIdentifier</key><string>io.github.jianfang.editor</string>
<key>CFBundleName</key><string>剪坊</string>
<key>CFBundleDisplayName</key><string>剪坊</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.video</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist" > "$log_dir/plist.log"
# 清理新构建包的 Finder 元数据；不修改用户已有 App 或系统安全设置。
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
# Apple Silicon 可执行文件使用 ad-hoc 签名；没有 Developer ID 证书，也未公证。
codesign --force --options runtime --timestamp=none --sign - "$app" > "$log_dir/codesign.log" 2>&1
codesign --verify --deep --strict "$app"
codesign -dv --verbose=2 "$app" > "$log_dir/signature.txt" 2>&1
shasum -a 256 "$app/Contents/MacOS/IndependentEditor" > "$log_dir/binary-sha256.txt"
printf '%s\n' "$app"

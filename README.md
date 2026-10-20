# 剪坊

一个用 AI 做出来的本地 macOS 视频剪辑软件：不登录、不订阅，断网可用，素材不上传。

剪坊提供素材导入、时间线剪辑、视频预览、中文字幕、配乐混音、工程保存与 MP4 导出。当前为 **0.2.1 公开预览版**。

[下载最新版 App](https://github.com/tuyetloanpham08-png/jianfang/releases/latest)

## 主要功能

- 横版或竖版 1080p 工程，30 fps，最长 10 分钟。
- 2 条视频轨、4 条音轨和字幕轨；支持分割、裁剪、移动、撤销与重做。
- 导入视频自动附带原声；支持独立配乐、音量与淡入淡出。
- 添加或编辑中文字幕，导入与导出 SRT。
- 保存、重开、自动恢复、素材重连与工程收集。
- 在本机预览并导出 H.264/AAC MP4。

支持 SDR H.264 MP4/MOV、PNG/JPEG、WAV/AAC。HDR、可变帧率素材、自动语音识别、变速和转场不在当前支持范围内。App 只依赖 macOS 系统框架，不需要其他视频剪辑软件或 FFmpeg。

## 系统要求

- **Apple Silicon Mac，macOS 26 或更高版本。**
- 发布的 ZIP 为 arm64 版本，尚未验证 Intel Mac。
- 直接下载 Release 中的 App 即可使用，**不需要安装 Xcode、Swift 或其他开发工具**。

## 三步开始使用

1. 打开 [Releases](https://github.com/tuyetloanpham08-png/jianfang/releases)，下载 `Jianfang-0.2.1-macOS.zip`，不要选源码压缩包。
2. 解压 ZIP，把 **剪坊.app** 拖进“应用程序”文件夹。
3. 打开剪坊，选择“新建横版工程”“新建竖版工程”或“打开工程”。

首次打开遇到安全提示时，请先阅读下一节。

## 未签名与首次打开提示

此预览版**没有 Apple Developer ID 签名，也未经过 Apple 公证**；为满足 Apple Silicon 可执行要求，仅使用 ad-hoc 签名。因此 macOS 可能阻止首次启动。

可以先在“应用程序”中右键点“剪坊”，选择“打开”。**macOS 26 上仅靠右键“打开”可能无法放行**。确认下载来源和文件后，按照系统提示前往：

**系统设置 → 隐私与安全性 → 仍要打开 → 打开**。

若系统要求身份验证，请在系统窗口中完成。不要全局关闭 Gatekeeper；若提示包含恶意软件或文件损坏，不要直接忽略，应先核对下载和校验值。详见 [Apple 官方打开说明](https://support.apple.com/zh-cn/102445)。

## 使用流程

**点开推文链接 → 进入 GitHub 仓库页 → 点右侧 Releases → 下载 ZIP → 解压 → 拖到“应用程序” → 右键“打开” → 按需在“隐私与安全性”点“仍要打开” → 启动剪坊。**

在 GitHub 窄屏页面中，Releases 入口也可能位于页面下方；可直接使用上方“下载最新版 App”链接。推文只是访问入口，使用 App 不需要 X 账号。

启动后导入素材，在时间线上编辑，添加字幕和配乐，再保存工程、导出 MP4。需要将工程搬到其他位置时，使用“文件 → 收集工程”，保留整个文件夹中的工程与媒体文件。

## 从源码编译

只有开发或自行编译才需要工具链：

- macOS 26 或更高版本；
- Xcode（包含 macOS 26 或更新 SDK），Swift 6 工具链；
- Git；不需要第三方 Swift 包。
- Python 3 和包含 `libx264`、`libx265` 的 FFmpeg，仅用于在开发机上生成演示与测试媒体；下载 Release 使用 App 不需要这些工具。

仓库不提交二进制测试媒体。首次源码构建前先生成内置演示素材：

```sh
git clone https://github.com/tuyetloanpham08-png/jianfang.git
cd jianfang
python3 scripts/generate_fixtures.py
zsh scripts/build_release_app.sh
```

输出为 `dist/剪坊.app`，日志位于 `build-logs/release/`。脚本拒绝覆盖已有目标；再次构建时指定新的目录：

```sh
zsh scripts/build_release_app.sh \
  --app dist/剪坊-test.app \
  --log-dir build-logs/test
```

`scripts/build_core_app.sh` 是同一构建入口的兼容包装。构建脚本生成 arm64 App、图标和最小内置示例，并使用 ad-hoc 签名；不会请求签名证书或公证凭据。

开发检查（先生成回归测试输入）：

```sh
python3 scripts/make_step7_fixtures.py
swift run CoreChecks
swift test
```

测试媒体均为合成图形、声音或格式边界探针，不包含用户影片素材。
生成脚本拒绝覆盖已有目标。媒体文件只保存在本机，不进入源码提交。

## 当前边界

这是公开预览版。本机测试不能代替每台设备上的验证；请保留原始素材和工程备份。完整主观听感、动态穿帮、影片叙事质量由创作者审看决定。

收集工程后素材可能显示为内容哈希文件名，仍可编辑，但按镜号查找不够方便。剪坊没有账号系统、云端渲染或素材上传功能；下载 App 和访问 GitHub 需要网络，下载后本地剪辑不需要联网。

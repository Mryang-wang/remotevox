# T1 Controller

<img src="Assets/T1AppIcon.png" alt="T1 Controller 图标" width="96">

把蓝牙 T1 遥控器用作 Mac 的麦克风和控制器。支持简体中文本机听写、Codex 草稿听写、系统 App 菜单和逐 App 按键映射。

## 安装

[在 GitHub Releases 下载 macOS 安装包](https://github.com/Mryang-wang/t1-controller/releases/tag/v0.17.1)。安装包面向 Apple Silicon Mac 和 macOS 27 或更新版本。需要管理员权限安装 Core Audio 驱动。

1. 打开 `T1-Controller-0.17.1-arm64.pkg`，完成安装并按提示重启。App 安装在 `/Applications/T1 Controller.app`，驱动安装在 `/Library/Audio/Plug-Ins/HAL/T1SiriInput.driver`。
2. 在「系统设置 → 蓝牙」连接 `T1-Remote`。打开「应用程序」里的 T1 Controller，允许蓝牙访问。
3. 在应用的「权限与启动」点「检查并请求控制权限」，在系统设置为 T1 Controller 开启「辅助功能」和「输入监控」。如果 macOS 要求退出重开，按提示操作。
4. 在「系统设置 → 声音 → 输入」选择 **T1 USB-Compatible Mic**。在「输出」选择平时使用的扬声器或耳机。Codex 和通话 App 如有单独的麦克风权限请求，按需在「隐私与安全性 → 麦克风」允许。
5. 如需普通 App 听写，在「权限与启动」点「准备简体中文模型」，然后在「按键映射 → 通用设置」开启「语音键使用本机听写」。首次准备模型由 macOS 联网下载，听写本身在本机执行。
6. 如需登录后后台待命，在「权限与启动」点「开启登录启动」，并按 macOS 提示确认。双击 App 可随时打开设置窗口。

安装包使用本地构建，未使用 Apple Developer ID Installer 签名或公证。如果 macOS 阻止打开，先核对 Release 提供的 SHA-256 校验值，再按系统设置的提示操作。系统授权由每台 Mac 的用户确认。 [Apple 的安装与公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

### 从早期测试版迁移

早期测试版在用户的 `~/Applications` 内。安装正式路径的版本前，先从测试版窗口退出应用，把旧 App 移到其他位置作备份，并在登录项设置中停用旧的 T1 启动任务。如旧任务来自 `~/Library/LaunchAgents/local.codex.t1microphone.login.plist`，可退出并移走该文件后重新登录。首次运行新路径的 App 时，在「权限与启动」检查授权状态。

## 默认操作

| 按键 | 单击 | 双击 | 长按 |
| --- | --- | --- | --- |
| 语音 | 开始或结束听写 | Codex 录音中作废本次听写 | 遥控器原生行为 |
| 三横线 | 打开系统 App 菜单 | 复制 | 粘贴 |
| 主页 | 显示桌面 | 系统 App 切换器 | Codex 新建对话 |
| 返回 | 关闭系统 App 菜单、切换器或 Codex 查找。飞鼠模式下可右击 | 可配置 | 可配置 |
| 静音 | 切换静音 | 可配置 | 可配置 |
| 上、下、左、右 | 原生方向键 | 可配置 | 可配置 |
| OK | 原生确认或飞鼠左键 | 键盘模式下可配置 | 键盘模式下可配置 |
| 电源 | 锁屏 | 锁屏并熄屏 | 弹出关机确认 |

普通 App 听写时，先把光标放进可编辑文本框。第一次轻按语音键开始，屏幕下方的波纹随音量变化，安静时显示静止点线。第二次轻按结束，识别结果写入当前文本框。在 Codex 中使用其专用听写，结束后文字留在草稿。

## 自定义按键

在「按键映射」编辑通用配置，或用「添加 App」配置指定应用。可给四个方向键和键盘模式的 OK 设置单击、双击、长按，并录入自定义快捷键。只设置双击或长按时，单击仍可选择「使用原生按键」。前台 App 配置可继承通用设置，也可启用原生模式。

飞鼠模式下的 OK 保持点击与拖选。遥控器前后按键发出相同键码时，共用映射。系统 App 菜单、切换器和其他键盘的方向键按系统原生方式工作。

## 构建与验证

安装配有 macOS 27 SDK 的 Xcode Command Line Tools，然后在项目目录运行：

```sh
./test.sh
./build.sh
./package.sh
```

应用构建在 `Build/T1 Controller.app`。安装包和 SHA-256 校验文件在 `Build/`。本地构建生成的签名身份保存在当前用户的应用支持目录。

- `Sources/` 存放 Swift 应用、蓝牙音频桥接、听写和按键逻辑。
- `Driver/` 存放兼容音频驱动的对应源码、许可证与构建信息。
- `Packaging/` 存放安装器定义和登录启动组件。
- `Tests/` 覆盖手势、逐 App 配置、快捷键录入和界面渲染。

蓝牙音频在会话期间解码。普通 App 本机听写的音频与转写文本由应用在内存中处理，识别后写入原文本框。Codex 听写由 Codex 处理。

## 音频驱动

T1SiriInput 基于 Existential Audio 的 BlackHole 源码，按 GNU GPL v3 发布。当前包使用 T1SiriInput 的名称和标识。对应源文件、上游版本和构建参数见 [Driver](Driver/README.md)。[BlackHole 上游项目](https://github.com/ExistentialAudio/BlackHole)

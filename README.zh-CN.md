# Audio Router Lite

[English](README.md) | 简体中文

Audio Router Lite 是一个轻量的原生 macOS 应用，可以把任意 Core Audio 输入设备的实时音频送到任意 Core Audio 输出设备。支持 USB、内置和虚拟设备。

## 下载

在 [Releases](https://github.com/Rexcain/audio-router-lite/releases) 页面下载 `Audio-Router-Lite-<版本号>.zip`，解压后把 **Audio Router Lite** 拖进「应用程序」文件夹。应用需要 macOS 15 或更高版本，在 Apple Silicon 和 Intel Mac 上都原生运行。

应用没有经过 Apple 公证，所以第一次打开时 macOS 会提示「无法验证开发者」并阻止运行。允许它运行的方法：
1. 双击应用一次，关掉弹出的警告。
2. 打开 **系统设置 → 隐私与安全性**，向下滚动，在「Audio Router Lite」旁边点 **仍要打开**，然后确认。

也可以在终端执行：`xattr -dr com.apple.quarantine "/Applications/Audio Router Lite.app"`。

## 从源码编译

需要 macOS 15 或更高版本，以及 Swift 6（只装 Command Line Tools 即可，不需要 Xcode）。脚本默认生成同时支持 Apple Silicon 和 Intel 的通用版本；只想编译一种架构、加快速度的话，用 `ARCHS="arm64" ./scripts/build-app.sh`。

```bash
./scripts/build-app.sh            # → build/Audio Router Lite.app
open "build/Audio Router Lite.app"
```

## 使用方法

1. 在 **Routing** 页面选择 **Source**（输入设备和声道）和 **Destination**（输出设备和声道）。
2. 点 **Start**（⌘R）。第一次使用时允许麦克风权限，macOS 读取任何音频输入都需要它。
3. 在路由卡片上调节 **Gain**（增益）或 **Mute**（静音）。**Test tone** 会播放 1 kHz 测试音，用来检查输出。
4. 点 **Add Route** 添加更多路由。用 **Save Preset…** 保存当前设置，从 **Preset** 菜单加载。

不同的采样率和设备时钟会自动处理，路由设置也会自动保存。

## 测试

```bash
swift run -c release RouterTests        # 25 项 DSP/引擎自动测试（约 3 秒）
swift run -c release ardiag list        # 列出所有设备的详细信息
swift run -c release ardiag level --dev "<Audio Device 1>" --seconds 10   # 测量输入设备实际送来的峰值和 RMS 电平
# 经过 Core Audio 的真实端到端测试（需要两个虚拟回环设备）：
swift run -c release ardiag e2e --src "<Audio Device 1>" --dst "<Audio Device 2>" --seconds 30 --mode balanced
```

`ardiag` 是内部诊断工具，不是产品本身。`ardiag probe …` 用来测量图形界面应用实际做的路由，`ardiag hotplug --dev …` 用来模拟设备拔出再插入。

测试实测结果：采样率转换的 THD+N 低于 −110 dB，20 kHz 以内频响偏差不超过 0.0001 dB，共用时钟时比特级直通，通过 Core Audio 在虚拟回环设备上连续运行 10 分钟没有一次断音。

## 许可证

Copyright © 2026 Rexcain.

Audio Router Lite 是自由软件：你可以按照自由软件基金会发布的 GNU 通用公共许可证第 3 版（或者你选择的任何更新版本）重新分发和修改它。本软件不提供任何担保。完整条款见 [LICENSE](LICENSE)。法律效力以英文原文为准。

## 致谢

本项目在 Anthropic 的 AI 编程工具 [Claude Code](https://claude.com/claude-code) 协助下完成。

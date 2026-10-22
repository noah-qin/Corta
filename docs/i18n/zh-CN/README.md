<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="Corta 的穿山甲吉祥物，身体蜷成字母 C，尾巴是一个青色光标">

# Corta

**快速、专注的终端。为 Mac 而生，用 Swift 打造。**

Metal 4 渲染 · 原生中日韩输入法 · SSH、SFTP 与远程编辑

> 献给长时间待在终端里的人：清晰的文字、原生的输入、强大的远程工作流，以及**零**第三方依赖的 Swift 终端核心。快到足以应付高强度输出，细致到适合每天的工作。

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)

**[↓ 下载](https://github.com/noah-qin/Corta/releases/latest)** ·
**[用户指南](USER-GUIDE.md)** ·
[文档（英文）](../../README.md) ·
[参与贡献](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[报告问题](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="Corta 的三个分屏：git log 与中日韩及 emoji 对齐表、在终端中显示的穿山甲图片、24 位色彩渐变">

</div>

> 本文译自英文版 [README.md](../../../README.md)，对应提交
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/README.md)。
> 此后英文版如有更新，或两者有出入，以英文版为准。

## 安装

需要 **macOS 26.0 或更高版本**、**Apple 芯片**（M1 或更新）以及**支持 Metal 4 的 GPU**。
不支持使用半虚拟化 GPU 的虚拟机。Intel Mac 可以使用旧版
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1)。

从 [GitHub Releases](https://github.com/noah-qin/Corta/releases/latest) 下载 `.dmg`
和对应的 `.dmg.sha256` 文件，两者放在同一个文件夹里，并在那里校验：

```sh
# 把 x.y.z 换成你下载的版本号。
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

打开磁盘映像，把 **Corta** 拖进“应用程序”，然后推出映像。正式版本均经过 Developer ID
签名和 Apple 公证。之后的更新可以用 **Corta ▸ 检查更新…**，或者下载新版本。
安装问题和卸载方法见[故障排除](TROUBLESHOOTING.md)。

## 上手

| 想要… | 操作 |
| :--- | :--- |
| 向右 / 向下分屏 | ⌘D / ⇧⌘D |
| 搜索终端输出 | ⌘F |
| 打开命令面板 | ⇧⌘P |
| 打开设置 | ⌘, |

开启“目录补全”（默认开启）时，标准的本地 zsh 会话会自动加载内置的 shell 集成钩子。
要在 zsh、bash 或 fish 的启动文件中安装，请使用 **设置 ▸ 终端 ▸ Shell 集成**；
只有你点了“安装”，才会修改 shell 的启动文件。已安装的集成过时了，就点“更新”，再打开一个新 shell。
详见 [Shell 集成指南](USER-GUIDE.md#shell-integration)。

## 为什么选 Corta

| | |
| :--- | :--- |
| **原生 Mac 输入** | 中日韩输入法与组字、Core Text 字体回退、VoiceOver、安全键盘输入、服务、快捷终端和快捷指令操作——通过 AppKit 实现，而不是绕开它。 |
| **快，而且有证据** | 核心吞吐量是 1.1 的 2.3 倍，全屏输入延迟少一帧，10 万行历史只占 11 MiB（原来是 185 MiB）。每个数字都公开了测量方法和局限（见下文）。 |
| **内置远程工作流** | 使用系统 OpenSSH 和你的 `~/.ssh/config`；类似 Finder 的 SFTP 浏览器，支持拖放；远程文件可以在本地编辑器中打开，上传前会检查冲突。 |
| **一个设置文件** | 原生设置窗口和 `~/.config/corta/config` 编辑的是同一份配置；自动化检查保证文档中的配置项和快捷键与代码一致。 |
| **小核心，严防护** | Swift 终端核心没有任何第三方依赖，对不可信输出设有资源上限，图片解码在沙盒中进行；应用只额外使用 [Sparkle](https://sparkle-project.org) 做更新。读取剪贴板和查询标题是有意不支持的（[安全模型](../../SECURITY.md)，英文）。 |

分屏、回滚搜索、真彩色、OSC 8 链接、Kitty 键盘协议与图形协议、shell 集成和布局恢复都已具备；
[功能参考](../../FEATURES.md)（英文）列出了全部功能及其要求和限制，描述的是 `main` 分支——
已发布的版本不一定包含其中每一项。Corta 与 iTerm2、Ghostty 的比较，以及什么时候该选它们，见
[Features → How Corta compares](../../FEATURES.md#how-corta-compares)（英文）。
Corta 只做 macOS，不支持 tmux 控制模式、内置 AI 和脚本引擎，这些都是
[已定的决策](../../DECISIONS.md)（英文）；普通的 tmux 会话作为终端程序在 Corta 里照常运行。

## 按你的方式来

设置保存在 `~/.config/corta/config`。原生设置窗口和这个文本文件编辑的是同一份配置。

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**显示 ▸ 主题编辑器…** 提供取色器以及分开的浅色/深色预览。**设置 ▸ 外观 ▸ 光标**
可以选择方块、竖线或下划线，并单独开关闪烁；默认是不闪烁的方块。主字体只支持系统等宽字体，
字号可调，缺少的字符由系统字体补上。**设置 ▸ 终端 ▸ 底部状态栏** 可以开启本机各项指标
（默认关闭）；点击状态栏可查看主机详情，也可以用 **显示 ▸ 本机详情…**。
具体步骤、网络接口的选择和热状态的局限，见[个性化教程](USER-GUIDE.md#personalizing-the-terminal)。

[配置参考](../../CONFIGURATION.md)（英文）列出了每个配置项、默认值以及修改何时生效。
[用户指南](USER-GUIDE.md)逐一介绍每个功能以及在哪里找到它。

## 从源码构建

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # 只测终端核心，不构建应用
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # 与已安装的 Corta 并存的开发版应用
```

[贡献指南](../../../CONTRIBUTING.md)（英文）写明了环境要求（macOS 26、Apple 芯片、
[`.xcode-version`](../../../.xcode-version) 中指定的 Xcode）、本地签名和仓库结构；
[测试指南](../../TESTING.md)（英文）说明每类改动需要哪些检查。

## 质量，有证据

Corta 仍在积极开发中，也有已知问题。下面的测量是快照，不保证在每台机器、每种负载下都成立。
每一行都注明了是在哪个版本上测的。

| 检查项 | 记录结果 | 测量版本 | 依据 |
| :--- | :--- | :--- | :--- |
| 核心吞吐量（解析器、网格和回滚；不含 PTY 和渲染） | **317.3 MiB/s**，原为 137.2 | 1.2 对比 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| 解析器 + 网格吞吐量 | **355.9 MiB/s**，原为 158.0 | 1.2 对比 1.1 | 同上 |
| 回滚内存，10 万行 × 120 列 | **11.4 MiB**，原为 185 | 1.2 对比 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| 区域滚动，每帧 CPU，p50 | **0.026 ms**，原为 0.130 | 1.2 对比 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| 帧 CPU，120 × 40 完整重建，Release | **0.37–0.39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| 按键到上屏，全屏、单窗格、60 Hz、真人打字 | p50 **49.1–50.8 ms**，p99 82.9–84.2 ms（原 p50 为 64–68 ms） | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| 空闲 CPU，Release，20 秒 | 0.05% | **1.0.0**（2026-09-18）；1.2 的空闲唤醒优化之后未重测 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 通过 131，已知问题 334，失败 102；共 567 | **1.1.5**（2026-10-07） | [原始结果](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

测量机器为 Apple M5 MacBook Air（macOS 27.0.1）；1.2 的各行测于 2026-10-09 至 2026-10-13，
每组前后对比都在同一台机器、同一套工具链上完成。[Performance](../../PERFORMANCE.md)（英文）
中带日期的章节记录了测量条件、每一次运行，以及一个数字不能说明什么。有时被引用的 esctest2
82.0% 把通过数**加上已知问题**一起算了，并不是通过率；如何解读见
[Conformance](../../CONFORMANCE.md)（英文）。

已知的局限包括：窗口模式下按键到上屏的延迟高于一帧的目标（全屏单窗格最接近）、VT 一致性尚不完整、
内置 shell 集成只支持 zsh、bash 和 fish，以及 Kitty 图形协议只支持直接传输。
详见[局限说明](../../FEATURES.md#known-limits)（英文）。

## 从哪里开始

| 我想… | 从这里开始 |
| :--- | :--- |
| 了解每个功能以及它在哪里 | [用户指南](USER-GUIDE.md) |
| 配置 Corta | [Configuration](../../CONFIGURATION.md)（英文） |
| 弄清某个功能或局限 | [Features](../../FEATURES.md)（英文） |
| 排查问题 | [故障排除](TROUBLESHOOTING.md) |
| 从 iTerm2、Ghostty 或 Terminal.app 迁移过来 | [从其他终端迁移](USER-GUIDE.md#coming-from-another-terminal) |
| 看看有什么计划，或者提个建议 | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| 找点事情做 | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| 第一次贡献 | [Contributing](../../../CONTRIBUTING.md)（英文） |
| 运行或添加测试 | [Testing](../../TESTING.md)（英文） |
| 读懂代码 | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)（英文） |
| 阅读完整文档 | [文档索引](../../README.md)（英文） |

## 参与

欢迎提交 bug 复现、文档、翻译、无障碍测试和代码。可以从
[good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue)
或 [help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) 开始，
环境搭建和评审要求见 [CONTRIBUTING.md](../../../CONTRIBUTING.md)。社区参与遵循
[行为准则](../../../CODE_OF_CONDUCT.md)。

试用后换回了原来的终端？这也很值得听：
[Went back 表单](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
不需要复现步骤，“就是感觉不对”也是可以接受的回答。

安全漏洞请通过[私密安全渠道](../../../SECURITY.md)报告。
想和其他用户及维护者聊天，欢迎加入 [Discord](https://discord.gg/QNdWfdwr7j)。
希望答案能被别人搜到的使用问题，请发到 [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a)，中文提问同样欢迎；
想分享主题或配置，请发到 [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell)。
其他问题请[提交 issue](https://github.com/noah-qin/Corta/issues/new/choose)。
如果你愿意支持项目的维护，可以[赞助本项目](https://github.com/sponsors/noah-qin)。

### 贡献者

感谢每一位为 Corta 做出贡献的人。

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## 许可与标识

源代码采用 [Apache 2.0](../../../LICENSE) 许可。Corta 名称、穿山甲吉祥物和应用图标另有条款，见
[NOTICE](../../../NOTICE)。穿山甲蜷起的身体组成字母 C，青色的尾巴是终端光标。
[品牌素材](../../brand/README.md)包括吉祥物和社交预览图。

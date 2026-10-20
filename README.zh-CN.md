<div align="center">

<img src="docs/brand/corta-pangolin-mascot.png" width="160" alt="Corta 的穿山甲吉祥物，身体蜷成字母 C，尾巴是一个青色光标">

# Corta

**快速、专注的 Mac 终端，用 Swift 打造。**

Metal 4 渲染 · 原生中日韩输入法 · SSH、SFTP 与远程编辑

[English](README.md) ·
**[↓ 下载](https://github.com/noah-qin/Corta/releases/latest)** ·
[用户指南（英文）](docs/USER-GUIDE.md) ·
[报告问题](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml) ·
[Discord](https://discord.gg/QNdWfdwr7j)

<img src="docs/brand/screenshot.png" width="960" alt="Corta 的三个分屏：git log 与中日韩及 emoji 对齐表、在终端中显示的穿山甲图片、24 位色彩渐变">

</div>

> 本页是英文 [README](README.md) 首屏与安装步骤的简体中文摘要。其余文档目前只有英文版；
> 两者如有出入，以英文为准，也欢迎提 issue 指出。

## 系统要求

需要 **macOS 26.0 或更高版本**、**Apple 芯片**（M1 或更新）以及**支持 Metal 4 的 GPU**。
不支持使用半虚拟化 GPU 的虚拟机。Intel Mac 可以使用旧版
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1)。

## 安装

从 [GitHub Releases](https://github.com/noah-qin/Corta/releases/latest) 下载 `.dmg`
和对应的 `.dmg.sha256` 文件，放在同一个文件夹里，在那里校验：

```sh
# 把 x.y.z 换成你下载的版本号。
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

打开磁盘映像，把 **Corta** 拖进“应用程序”，然后推出映像。正式版本均经过 Developer ID
签名和 Apple 公证。之后的更新可以用 **Corta ▸ Check for Updates…**，或者下载新版本。
安装问题和卸载方法见 [Troubleshooting](docs/TROUBLESHOOTING.md)。

## 上手

| 想要… | 操作 |
| :--- | :--- |
| 向右 / 向下分屏 | ⌘D / ⇧⌘D |
| 搜索终端输出 | ⌘F |
| 打开命令面板 | ⇧⌘P |
| 打开设置 | ⌘, |

本地 zsh 会话默认自动加载内置的 shell 集成。zsh、bash 或 fish 要写入启动文件，请到
**Settings ▸ Terminal ▸ Shell Integration** 选择 Install；只有你点了 Install 才会修改启动文件。

所有设置都存放在 `~/.config/corta/config`，原生设置窗口改的就是这个文件，手动编辑也可以。
每个配置项见 [Configuration](docs/CONFIGURATION.md)。从 iTerm2、Ghostty 或 Terminal.app
迁移过来，请看
[Coming from another terminal](docs/USER-GUIDE.md#coming-from-another-terminal)。

## 为什么选 Corta

- **原生 Mac 输入。** 通过 AppKit 实现中日韩输入法组字、Core Text 字体回退、VoiceOver、
  安全键盘输入、快捷指令和 Quick Terminal。
- **快，而且有证据。** 核心吞吐量是 1.1 的 2.3 倍；全屏单窗格时按键到上屏少一帧；
  10 万行历史只占 11 MiB（原来是 185 MiB）。每个数字都公开了测量方法和局限，
  见 [Performance](docs/PERFORMANCE.md)。
- **内置远程工作流。** 使用系统 OpenSSH 和你的 `~/.ssh/config`；类似 Finder 的 SFTP 浏览器，
  支持拖放；远程文件可以用本地编辑器打开，上传前会检查远程冲突。
- **小核心，严防护。** 终端核心没有任何第三方依赖，对不可信输出设有资源上限，
  图片解码在沙盒辅助进程中进行；应用只额外使用 Sparkle 做更新。见 [Security](docs/SECURITY.md)。

## 参与

欢迎提交 bug 复现、文档、翻译、无障碍测试和代码。可以从
[good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue) 开始，
先读 [CONTRIBUTING.md](CONTRIBUTING.md)。使用问题请到
[Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a)，
中文提问同样欢迎；想和其他用户及维护者实时交流，欢迎加入 [Discord](https://discord.gg/QNdWfdwr7j)。试用后换回了原来的终端？欢迎用
[Went back 表单](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
告诉我们原因，不需要复现步骤。安全漏洞请通过 [SECURITY.md](SECURITY.md) 私下报告。

## 许可

源代码采用 [Apache 2.0](LICENSE) 许可。Corta 名称、穿山甲吉祥物和应用图标另有条款，见
[NOTICE](NOTICE)。

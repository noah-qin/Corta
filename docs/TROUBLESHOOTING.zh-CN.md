# 故障排除

[文档索引（英文）](README.md) · [项目概览](../README.zh-CN.md)

🇺🇸 [English](TROUBLESHOOTING.md) · 🇨🇳 [简体中文](TROUBLESHOOTING.zh-CN.md) · 🇭🇰 [繁體中文](TROUBLESHOOTING.zh-Hant.md) · 🇯🇵 [日本語](TROUBLESHOOTING.ja.md) · 🇰🇷 [한국어](TROUBLESHOOTING.ko.md) · 🇩🇪 [Deutsch](TROUBLESHOOTING.de.md) · 🇫🇷 [Français](TROUBLESHOOTING.fr.md) · 🇪🇸 [Español](TROUBLESHOOTING.es.md) · 🇧🇷 [Português](TROUBLESHOOTING.pt-BR.md)

> 本文译自英文版 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)，对应提交
> [`04ad320`](https://github.com/noah-qin/Corta/blob/04ad320438030e3ba4a7c19761b0279e39c42afc/docs/TROUBLESHOOTING.md)。
> 此后英文版如有更新，或两者有出入，以英文版为准。macOS 的提示文字以英文原文为准，中文为对照译文。

Corta 装不上、打不开，或者做了你以前的终端不会做的事时，该怎么办。每一条都说明你会看到什么、原因是什么、
如何修复——最后一节说明如果都没用，如何干净地回到你原来的终端，因为一份“我换回去了，原因是这样”的报告
是你能提交的最有用的东西之一。

如果这里的某一条有误或缺失，请用 **Installation blocker** 或 **Went back to my old terminal** 模板提交 issue：
<https://github.com/noah-qin/Corta/issues/new/choose>。

---

<a id="installing"></a>

## 安装

### “无法打开 Corta，因为 Apple 无法检查其是否包含恶意软件”（"Corta can't be opened because Apple cannot check it for malicious software"）

正式版本都经过 Developer ID 签名和公证，从源码构建的版本可能没有。对于下载的正式版本，
请先校验其校验和，并做下面的映像和应用检查，然后连同版本号报告确切的提示信息。

### “Corta 已损坏，无法打开”（"Corta is damaged and can't be opened"）

磁盘映像可能不完整、被改动过，或者被 macOS 的签名验证拒绝。先用旁边一同发布的 `.sha256` 文件校验它。
把两个文件都放在下载文件夹里，并把 `x.y.z` 换成你下载的版本号：

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

不匹配就重新下载。每个发布包在发布前都会与它的校验文件核对（`corta-release-check`），所以不匹配就是停下来重新下载的理由。
如果校验和匹配，再检查映像和复制出来的应用。在所有命令中把 `x.y.z` 换成下载的版本号，并在下载文件夹中运行：

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

报告时请附上版本号、macOS 的错误信息和这些结果。不要为了测试正式版本而绕过 Gatekeeper。
1.1.8 及更早的版本保留原来的 ZIP 校验和；请使用那个版本中的文件名。

### Corta 提出把自己移到 /Applications

Corta 是从 `~/Downloads` 或其他文件夹启动的。它在哪里都能运行；`/Applications` 是 Sparkle 更新和聚焦搜索期望它所在的位置。
选择“暂不”后它就不再询问——也可以在 `~/.config/corta/config` 中设置 `suggest-applications-folder = false`。

直接从磁盘映像打开时，macOS 会从一个临时的只读位置运行 Corta，所以它无法移动自己；它会请你把它拖进“应用程序”。
如果那里已经有更新版本的 Corta，它会提出打开那个版本，而不是用较旧的副本替换它。

### 程序坞里有两个 Corta 图标

其中一个是开发版。访达称它为 **Corta Dev**，菜单栏称它为 **CortaDev**，它的图标背景是橙色而不是蓝色，
它的 bundle identifier 是 `dev.noahqin.Corta.dev`。它把配置和状态保存在 `~/Library/Application Support/Corta Dev/`，
从不使用 `~/.config/corta/config` 或 `~/Library/Application Support/Corta/`，而且它没有“检查更新…”菜单项——
所以无论两者以什么顺序出现，蓝色图标的那个就是已安装的 Corta。退出或删除其中一个不会影响另一个。
只有从源码构建 Corta 的人才会有开发版（`CONTRIBUTING.md`，“Developing Corta in Corta”）。

### “此版本的 Corta 需要 macOS 26.0 或更高版本”（"This version of Corta requires macOS 26.0 or later"）

Corta 的部署目标是 macOS 26.0，并使用该版本的 Metal 4 和 Core Text API。没有面向更早系统的版本，
项目也不打算提供（`DESIGN.md` §6）。

### “你无法打开应用程序“Corta”，因为这台 Mac 不支持此应用程序”（"You can't open the application "Corta" because it is not supported on this type of Mac"）

从 1.1.0 起，Corta 只为 Apple 芯片构建——即配备 M1 或更新芯片的 Mac（`DECISIONS.md` D21）。Intel Mac 无法运行它。
**1.0.1** 是支持 Intel Mac 的最后一个版本，仍可在
[1.0.1 发布页面](https://github.com/noah-qin/Corta/releases/tag/v1.0.1)下载：下载 `Corta-1.0.1.zip`，
校验后替换 `/Applications` 中的副本。已经在运行 1.0.x 的 Intel Mac 不会通过 **检查更新…** 收到 1.1.0，
所以会继续正常使用；只有手动下载并打开了更新的压缩包，才会出现这条提示。

要查看 Mac 用的是哪种芯片，请选择苹果菜单 ▸ 关于本机：Apple 芯片的 Mac 会有一行 *芯片*，写着 Apple 芯片（M1、M2……）；
Intel 的 Mac 则有一行 *处理器*，写着 Intel 的型号。

---

<a id="starting"></a>

## 启动

### 窗口打开后一片空白，或者打开后又关闭

从 Terminal.app 启动，看看原因：

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

无法启动 shell 的窗格会显示带 **重试** 按钮的失败视图，而不是空白画布；如果你看到的是没有失败视图的空白画布，
那是渲染 bug，值得附上控制台输出报告。

### shell 不是我预期的那个，或者没有 PATH

Corta 以登录 shell（`-l`）的方式启动它被启动时所在环境中的 `$SHELL`（没有则用 `/bin/zsh`），
所以 `~/.zprofile` 和 `~/.zshrc` 都会执行。`$SHELL` 指向的程序已不存在时，会依次退回到 `/bin/zsh`、`/bin/sh`，
并在窗格中提示用了哪一个。如果在 Terminal.app 中能用的命令在 Corta 中“找不到”，请检查启动 *GUI 应用* 的环境中
`SHELL` 是什么（`launchctl getenv SHELL`）：那里设置的值会作用于所有应用，并且在设置它的会话结束后依然存在。
运行 `launchctl unsetenv SHELL` 后重新启动。

**预设**（Shell ▸ 使用预设新建窗格）或配置文件中的 `preset.<name>.shell` 可以按窗格覆盖这一设置。

### Corta 恢复了昨天的窗口，而我并不想要

在 `~/.config/corta/config` 中设置 `restore-windows = false`，或在 设置 ▸ 通用 中取消勾选。
导致应用崩溃的恢复不会再次尝试：保存的布局会被丢弃，并打开一个新窗口。

### 设置提示无法读取配置文件

`~/.config/corta/config` 存在，但不是 UTF-8 文本——通常是编辑器以其他编码保存了某个字节——或者你没有读取权限。
Corta 会保留已有的设置，并拒绝写入这个文件，因为写入会替换其中的全部内容。请把文件重新保存为 UTF-8
（或删掉有问题的那一行）；Corta 下次读取时就会生效。Shell 集成对它无法读取的 rc 文件也是这样处理：报告问题，不去动它。

---

<a id="typing-and-rendering"></a>

## 输入和渲染

### 在 Claude Code 的斜杠命令菜单中按 Tab 没有反应

已在 1.0.0 中修复（B02）；v0.1.1 有这个 bug。如果在更新的版本上再次出现，请附上 Claude Code 的版本号报告：
修复的关键在于候选窗口发出的 `insertTab(_:)` 如何到达子进程，新的候选界面可能会走不同的路径。

### ⌥ 输入的是 `é`、`ø`、`–`，而不是充当 Meta

这是 macOS 的默认行为，Corta 保留了它。设置 `option-as-meta = true`，⌥ 就会像 PC 键盘的 Alt 一样发送 `ESC` + 按键。
特殊键（方向键、功能键）无论如何都会以 xterm 修饰符的形式带上 ⌥。

### 通过 ssh 时颜色或 `TERM` 看起来不对

Corta 有意声明 `TERM=xterm-256color`（`docs/DECISIONS.md` D08）。使用相同的 TERM 值并不意味着完全兼容 xterm。
用 `printf '%s\n' "$TERM"` 检查远程环境，并对比一个最小复现；[Conformance](CONFORMANCE.md#42-external-suites)（英文）
记录了支持的序列和尚存的失败项。

### 某个字形比旁边的字形小

所选字体缺少的字符来自苹方-简或 Apple Color Emoji。回退字形可能会被缩放以保持在其终端字符格内，
因此看起来的大小可能与相邻字形不同。在 **设置 ▸ 外观** 中调整字号并对比预览。如果某个字形被裁切或没有对齐，
请报告它的文字、字体、字号、显示器缩放比例并附上截图。

### 绘制的字体不是我设置的那个

`font-family` 指定的是字体家族，而不是某个字样（写 `JetBrains Mono`，不是 `JetBrainsMono-Regular`）。
只有当它已安装，且其常规、粗体和斜体字样在可打印 ASCII 范围内宽度一致时，Corta 才会使用它；
否则会绘制系统等宽字体，并在 **设置 ▸ 外观** 中显示“字体状态”一行，说明哪项检查没有通过。
Corta 运行期间安装的字体会立即出现在列表中；“重试”会重新检查配置的字体。

中文、日文或韩文的字体与 **中日韩字体**（`font-family-cjk`）中选择的不同，说明该字体没有安装或没有中日韩字符；
菜单下方的一行会说明这一点，并改用系统语言的字体绘制。所选字体缺少的字符也来自系统语言的字体。
关闭 **缺字时使用其他字体** 时，中日韩字体不会被使用。

### `kitten icat` 的图片不显示，或显示在错误的位置

Corta 实现了 Kitty 图形协议的直接（带内）传输，支持 RGB、RGBA 和 PNG。基于文件的传输（`t=f`、`t=t`、`t=s`）、
动画帧和 Unicode 占位符放置都没有实现，基于文件的传输也不会实现：远程数据流指定一个要读取的本地文件，
正是威胁模型所拒绝的（`SECURITY.md` §1）。试试 `kitten icat --transfer-mode=stream picture.png`，明确要求直接传输。
图片必须在每边 8192 像素、总计 1600 万像素的限制之内；无效或过大的图片会被拒绝。

### 空的 Return 画出了绿色或红色的命令标记

空的 Return 不是命令，当前的集成钩子不会记录它。旧版 Corta 安装的启动文件代码块仍可能报告它：
打开 **设置 ▸ 终端 ▸ Shell 集成**，选择 **更新**，然后打开一个新 shell。已经打开的 shell 在重启之前会保留旧函数，
已经画出的标记也会保留。只有启动文件中带标记的 Corta 代码块会被更新。使用自动钩子的标准本地 zsh 会话
在新 shell 启动时就会使用内置的版本。

---

<a id="behaviour-that-differs-from-other-terminals"></a>

## 与其他终端不同的行为

### 一选完就复制了

`copy-on-select` 默认开启，并会在窗格角落显示一个标签确认。设为 `false` 则只用 ⌘C 复制。

### 程序说已经复制到剪贴板，但什么也没复制

OSC 52 *写入* 默认关闭：否则任何程序输出都可以往剪贴板里放东西，等你之后粘贴。`allow-clipboard-write = true`
会开启它，`tmux` 和远程 `ssh` 会话需要的就是这个。*读取* 方向在任何设置下都不存在。

### 关闭窗口时问我是否确定

那个窗口里仍有前台任务。`confirm-close = false` 会在所有地方关闭这个询问。

### 快捷终端的热键没有反应

有三种可能，按顺序排查。`quick-terminal` 为 `false`（默认）：在你设为 `true` 之前不会占用任何按键。
另一个应用已经占用了这个按键：设置 ▸ 快捷终端 会提示，`quick-terminal-key` 可以换成任何其他至少带一个修饰键的组合。
或者这个按键是 Corta 无法映射到按键位置的（`é`、两个字符的写法）：配置文件中的那一行会原样保留，并使用默认值。
无论如何，显示 ▸ 快捷终端 和快捷指令中的 *切换快捷终端* 操作都能打开面板。

### 远程窗格的标记显示“远程：主机未知”，或者本地的 `tmux` 显示“远程？”

标记中的主机名来自远程 shell 自己的 `OSC 7` 报告，或者——对于从连接面板打开的连接——来自你在那里输入的目标。
它从不从提示符处输入的 `ssh` 命令行中读取主机（别名、`~/.ssh/config` 中的名称和跳板机链都会读错），
也不从提示符文字中读取。两者都没有时，`ssh` 窗格会显示 *主机未知*，这是实话。要显示主机，
请把 设置 ▸ 终端 中的 shell 集成代码块也放进远程机器的 `~/.zshrc`；它会发出标记读取的 `OSC 7`。
前台运行 `tmux` 或 `screen` 时显示 *远程？*，因为它所连接的会话本身可能在另一台机器上，而这里无从判断——
这是不确定，不是指控。

### 浏览远程文件… 提示认证失败，但窗格里的 `ssh` 能用

SFTP 连接会在它的窗口上弹出对话框询问密码或密钥口令；对话框被拒绝或取消，就会以这个错误结束。
检查表单中的用户和端口——别名自己的 `User` 和 `Port` 只在这些字段为空时才生效——以及你选择的密钥（如果有）：
选中的密钥是唯一提供的密钥。如果没有出现对话框，说明服务器拒绝了 ssh 能尝试的所有方式；
在终端中用相同的用户、端口和密钥运行 `ssh -v` 可以看出是哪种。

### 浏览远程文件… 提示无法验证主机密钥

第一次见到的主机会在一个显示指纹的对话框中请你信任它的密钥。这个错误说明密钥在你信任之后 *变了*——
服务器重装过，或者中间有人。在从 `~/.ssh/known_hosts` 中删除旧的那一行（`ssh-keygen -R <host>`）之前，ssh 会拒绝连接；
请先询问服务器的管理员。

### 命令历史显示“（命令文本已不在回滚历史中）”

命令的文字是从网格中恢复的，不单独保存：一旦它的提示符行滚出了 `scrollback-lines`，记录会保留时间、状态和目录，
但文字已经没了，也不再提供“填充”和“运行”。如果经常这样，请调大 `scrollback-lines`。

### 无法滚回长时间运行的开头

`scrollback-lines`（默认 10,000）是每个会话的上限，它统计的是 *物理* 行——一个 200 列的行在 100 列处换行就算两行。
超过上限的旧输出会在新输出到来时被丢弃；顶部的提示条会显示视图回滚了多远。可以调高上限（最多 1,000,000；
压缩后的冷历史占用多少内存取决于文字和负载）。一个存储的字符格在压缩前是 16 字节，这不是常驻内存的估算。
测得 100,000 行 120 列的负载增加了大约 11 MiB 常驻内存；见
[Performance](PERFORMANCE.md#56-numbers-by-release)（英文）。需要保留超过上限的输出，请导出。

### 安全键盘输入已开启，但我的宏工具仍然有效

标题栏中的锁表示它 *已生效*，而这只在 Corta 的终端窗口是当前窗口、且 Corta 是活动应用时才成立。
在其他应用中，以及设置窗口是当前窗口时，按键会正常传递——这正是它的用意，也是指示器跟随生效状态而不是设置的原因。

### 网络挂载上缺少目录代理图标

Corta 在后台检查报告的本地目录。如果挂载很慢，或已有两个检查在等待，它就不显示代理图标，
以便输出和键盘交互能继续进行。请单独检查挂载；挂载恢复后切换目录会发起新的检查。

### 窗格在个人文件夹而不是网络目录中打开

新窗格或启动时恢复的窗口，只有在所请求的目录能在很短的时限内响应时才会在那里启动。
停止响应的网络卷会被视为不存在，所以窗格会在个人文件夹中打开，而不是让 Corta 卡住。
在那里 ⌘ 点按或悬停 `path:line` 引用也适用同样的时限：它不会作为链接提供。重新连接该卷，然后 `cd` 过去，
或在那里打开新窗格。

### 远程编辑在上传提示后再次询问

本地文件在最初的提示所显示的版本之后又改过了。请明确批准新的编辑。没有远程内容摘要的旧托管条目也需要做一次冲突决定。
即使文件大小和时间戳没变，内容比较也能识别出远程的改动。

---

<a id="appearance-and-the-status-bar"></a>

## 外观和状态栏

### 光标不闪烁

闪烁默认关闭：在 设置 ▸ 外观 ▸ 光标 中打开 **光标闪烁**。窗格处于非活动、隐藏或回滚状态时会暂停闪烁。
终端程序可以用 DECSCUSR 为自己更改形状或闪烁；重置终端会恢复配置的样式。

### 状态栏没有显示网络速率，或显示的不对

速率需要两次采样，所以开启状态栏后请等几秒钟。`auto` 测量一个主接口；当 VPN 或多个网卡导致选错接口时，
请在 设置 ▸ 终端 中输入接口名。明确指定但不存在的接口不会显示速率。状态栏始终报告本机 Mac，在 SSH 窗格中也是如此；
热状态等级是 macOS 的分类，不是温度。较窄的窗口可能会截断状态栏；点按它即可看到所有已选的数值。

### 主题编辑器无法保存

无效的十六进制颜色会让“保存”不可用。如果在编辑器打开期间，配置文件中的这个自定义主题被修改了，
请先关闭再重新打开编辑器，然后保存，以免覆盖那次修改。

### 界面语言不对

Corta 跟随 macOS 为它选择的语言（系统设置 ▸ 通用 ▸ 语言与地区 ▸ 应用程序）。修改后请重新启动 Corta。
数字格式跟随地区，可能与语言不同。

---

<a id="updating"></a>

## 更新

### 检查更新… 什么也没找到

Corta 比较的是 **构建号**，而不是版本字符串，比较对象是 `main` 分支上的 `appcast.xml`。
已打标签、已起草但尚未发布的版本不在更新源中；发布后，发布流水线会签名并验证更新源、打开拉取请求、等待 CI，
然后 squash 合并或启用自动合并。更新源检查失败或受阻可能会延迟送达，所以在版本出现在 GitHub 之后请稍等一会儿。
`update-auto-check = false` 只会停用每天的后台检查；菜单项始终可用。

---

<a id="going-back-to-your-old-terminal"></a>

## 回到原来的终端

删除 Corta 的文件前请先退出 Corta。删除应用数据前，请检查托管的远程编辑副本中有没有未保存的工作：

1. **Shell 集成**，如果你是从 设置 ▸ 终端 安装的：在那里移除它，或删除 shell 启动文件中
   `# >>> Corta shell integration >>>` 和 `# <<< Corta shell integration <<<` 之间的代码块——
   `~/.zshrc`；bash 为 `~/.bashrc` 和 `~/.bash_profile`（或 `~/.bash_login` / `~/.profile`）；
   或 `~/.config/fish/config.fish`。该文件中的其他内容都不属于 Corta。
2. **安全键盘输入** 会在 Corta 退出时自行释放。如果 Corta 在某个窗口为当前窗口时被强制退出，
   之后在其他地方似乎无法输入，请启动并退出 Corta 一次；退出时计数会恢复平衡。
3. **设置和状态**：`~/.config/corta/`（配置文件）和 `~/Library/Application Support/Corta/`
   （窗口布局、目录历史和托管的远程编辑副本）。请先保留你仍需要的本地编辑，再删除它们。
   渲染器还会在 `~/Library/Caches/dev.noahqin.Corta/` 下保存可丢弃的缓存文件；这些可以删除。
4. 把 `Corta.app` 移到废纸篓。

然后，如果你愿意，请用 [**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
表单提交一个 issue，说说是什么让你换回去的。它不需要复现步骤。缺少的功能、渲染 bug、“就是感觉更慢”，
都是项目可以据此行动的回答。

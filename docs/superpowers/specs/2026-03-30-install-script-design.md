# QuickTUI 安装脚本设计文档

## 概述

为 QuickTUI 服务端提供一键安装脚本 `install.sh`，放在仓库根目录。用户通过以下命令安装：

```bash
curl -fsSL https://quicktui.ai/install.sh | sh
```

脚本以交互式方式引导用户完成：环境检测、二进制下载与校验、安装路径选择、token 配置、可选服务注册。

## 技术约束

- Shell 兼容性：POSIX `sh`，兼容 macOS (zsh) 和 Linux (bash/dash)
- 不依赖 Python、Node.js 等额外运行时
- 下载工具：优先 `curl`，fallback 到 `wget`

## 支持平台

| 平台  | 架构                  | 二进制文件名            |
| ----- | --------------------- | ----------------------- |
| macOS | Apple Silicon (arm64) | `quicktui-darwin-arm64` |
| macOS | Intel (amd64)         | `quicktui-darwin-amd64` |
| Linux | x86_64 (amd64)        | `quicktui-linux-amd64`  |

不支持的平台（Windows 原生、FreeBSD 等）：打印错误信息并退出。

## 执行流程

### Step 1：检测平台和架构

- 通过 `uname -s` 检测 OS（Darwin / Linux）
- 通过 `uname -m` 检测架构（arm64 / x86_64）
- 不支持的组合打印明确错误后退出

### Step 2：检测 tmux

- 检查 `tmux` 是否在 PATH 中
- **未安装**：询问用户是否自动安装
  - macOS：通过 `brew install tmux`
  - Linux：检测包管理器（apt / yum / dnf），通过 `run_privileged` 执行对应安装命令（兼容 root 环境）
  - 用户拒绝：打印手动安装提示后退出
- **已安装但版本 < 3.2**：打印警告，询问用户是否继续
  - 版本解析：`tmux -V` 输出格式为 `tmux 3.x`

### Step 3：下载并校验二进制

- 从 GitHub Releases 下载二进制：
  `https://github.com/dualface/quicktui/releases/latest/download/<filename>`
- 同时下载对应 sha256 校验文件：
  `https://github.com/dualface/quicktui/releases/latest/download/<filename>.sha256`
- 本地校验：
  - macOS：`shasum -a 256 -c <filename>.sha256`
  - Linux：`sha256sum -c <filename>.sha256`
- 校验失败：打印错误并删除下载文件后退出

**发布要求**：每次发布时，需同时上传 `<filename>.sha256` 文件，内容格式为：

```
<sha256hex>  <filename>
```

### Step 4：选择安装路径

提示用户选择：

```
Where would you like to install QuickTUI?
  [1] ~/.local/bin/quicktui  (no sudo required)  [default]
  [2] /usr/local/bin/quicktui  (requires sudo)
```

- 选择 1：如目录不存在则创建 `~/.local/bin`，并提示用户将其加入 PATH（若不在 PATH 中）
- 选择 2：使用 `run_privileged mv` 安装，设置权限 `755`（`run_privileged` 在 root 下直接执行，否则调用 `sudo`）

### Step 5：配置 token

```
How would you like to set up your access token?
  [1] Generate a random token automatically  [default]
  [2] Enter my own token
```

- 选择 1：用 `openssl rand -hex 32` 生成，fallback 到 `head -c 32 /dev/urandom | xxd -p`
- 选择 2：提示用户输入，不回显（`stty -echo`）

保存到 `~/.config/quicktui/config`：

```
QUICKTUI_TOKEN=<token>
```

文件权限设为 `600`。目录权限设为 `700`。

### Step 6：配置后台服务（可选）

```
Would you like to register QuickTUI as a background service? [y/N]
```

用户选择 yes 则继续询问：

```
Listen address [default: 0.0.0.0]:
Port [default: 3000]:
```

**地址校验**：`LISTEN_ADDR` 输入不得包含 shell 特殊字符（空格、`;`、`` ` ``、`$`、`()`、`'"`、`#`、`&`、`|`、`<>`、`\`），否则提示重新输入。

**macOS（launchd user agent）：**

生成 `~/Library/LaunchAgents/ai.quicktui.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.quicktui</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/quicktui</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>QUICKTUI_TOKEN</key>
    <string><token></string>
    <key>QUICKTUI_ADDR</key>
    <string><addr>:<port></string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

执行 `launchctl load ~/Library/LaunchAgents/ai.quicktui.plist` 启动服务。启动成功则记录状态，失败时输出手动启动命令。

**Linux（systemd user service）：**

生成 `~/.config/systemd/user/quicktui.service`：

```ini
[Unit]
Description=QuickTUI Remote Terminal Server
After=network.target

[Service]
EnvironmentFile=%h/.config/quicktui/config
ExecStart=/path/to/quicktui
Environment=QUICKTUI_ADDR=<addr>:<port>
Restart=on-failure

[Install]
WantedBy=default.target
```

执行：

```bash
systemctl --user daemon-reload
systemctl --user enable quicktui
systemctl --user start quicktui
```

启动成功则记录状态，失败时输出 `systemctl --user start quicktui` 手动启动提示。

> **注意**：服务通过 `EnvironmentFile` 读取 `QUICKTUI_TOKEN`，服务配置文件本身不包含 token 明文。

### Step 7：打印完成信息

完成信息包含 Binary 路径、Config 路径和版本号（若可获取）。

根据服务启动状态分三种情况输出：

**情况 A：服务已成功启动**

```
✓ QuickTUI installed successfully!

  Binary:  /path/to/quicktui
  Config:  ~/.config/quicktui/config
  Version: v1.x.x

Getting started:
  Open in browser:  http://<local-ip>:<port>
  Token:            <token>
  (Enter the token when prompted on first login)

iOS App:
  App Store & TestFlight:  https://quicktui.ai/#download
```

本机 IP 通过 `hostname -I`（Linux）或 `ipconfig getifaddr en0`（macOS）获取，获取失败则显示 `localhost`。

**情况 B：配置了服务但启动失败**

```
Service registration failed. Start manually:
  launchctl load ~/Library/LaunchAgents/ai.quicktui.plist   # macOS
  systemctl --user start quicktui                           # Linux
  Token: <token>
```

**情况 C：未注册后台服务**

```
To start QuickTUI, run:
  QUICKTUI_TOKEN=<token> /path/to/quicktui
```

## 文件存储结构

```
~/.config/quicktui/
└── config              # QUICKTUI_TOKEN=xxx（权限 600）

~/Library/LaunchAgents/
└── ai.quicktui.plist   # macOS 服务配置

~/.config/systemd/user/
└── quicktui.service    # Linux 服务配置
```

## 错误处理原则

- 任何步骤失败立即退出（`set -e`）
- 所有错误信息以 `Error:` 前缀打印到 stderr
- 下载失败、校验失败、权限不足均打印明确原因
- 不静默失败

## 不在范围内

- 升级/卸载功能（单独处理）
- 非交互式/静默安装模式
- Docker/容器化安装
- Windows 原生支持

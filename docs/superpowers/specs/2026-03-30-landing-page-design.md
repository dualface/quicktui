# QuickTUI Landing Page 设计文档

## 概述

为 QuickTUI (remote-tmux) 创建单页静态 landing page，托管在 GitHub Pages，域名 `quicktui.ai`。纯 HTML/CSS/JS，无构建工具。暗色终端风格设计。页面内容使用英文。目标：产品展示 + 下载引导。

## 技术方案

- 单个 `index.html` 文件，CSS/JS 单独文件
- 无框架，无构建步骤
- GitHub Pages 从 `main` 分支部署
- CNAME: `quicktui.ai`

## 页面结构

### 1. Hero 区域

- 产品名：**QuickTUI**
- Tagline："Drive AI Agents from anywhere — a tmux-based remote terminal manager with native iPhone & iPad support."
- 一个 CTA 按钮：**Download** — 锚点跳转到下载区域
- 视觉效果：深色背景 + 终端风格的微妙图案（CSS 网格点或扫描线效果）

### 2. Features 特性展示

3-4 个特性卡片，响应式网格布局。每个卡片包含内联 SVG 图标 + 标题 + 简短描述。

特性列表：

- **Full Terminal Experience** — Deeply integrated with tmux. Manage sessions, windows, panes, scroll history, and copy mode — all from your device.
- **Native iPhone & iPad App** — A smooth, responsive terminal and tmux experience built specifically for iOS.
- **Browser-Based Terminal** — The same great experience as the iOS app, right in your browser. Works on any platform.
- **Terminal-Optimized Toolbar** — A custom quick-access toolbar designed for terminal workflows, dramatically boosting your productivity.

卡片样式：深色背景 + 微妙边框，标题使用等宽或半等宽字体。

### 3. Screenshots 截图展示

iPhone 和 iPad 设备截图展示区：

- 2-3 个占位图片，灰色背景 + 文字标注（"iPhone Screenshot" / "iPad Screenshot"）
- 响应式布局：桌面端并排显示，移动端堆叠
- 占位图使用简单的 SVG 或 CSS 矩形 + 设备边框样式
- 用户后续替换为真实截图
- 图片文件存放在 `images/` 目录

### 4. Quick Start 快速开始

终端风格代码块，展示安装和基本使用命令：

```
# Download and run
curl -fsSL https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-darwin-arm64 -o quicktui
chmod +x quicktui
export QUICKTUI_TOKEN=your-secret-token
./quicktui
```

深色代码块 + CSS 语法高亮（绿色注释、白色命令）。等宽字体（系统等宽字体栈）。

### 5. Download 下载

按平台分列的下载按钮，链接到 GitHub Releases：

**服务端：**

- macOS (Apple Silicon) — `quicktui-darwin-arm64`
- macOS (Intel) — `quicktui-darwin-amd64`
- Linux (x86_64) — `quicktui-linux-amd64`
- Windows (x86_64) — `quicktui-windows-amd64.exe`
- Windows (ARM64) — `quicktui-windows-arm64.exe`

**iOS App：**

- App Store 链接（占位 URL，后续更新）
- TestFlight 链接（占位 URL，后续更新）

下载链接格式：`https://github.com/dualface/remote-tmux/releases/latest/download/{filename}`

按钮样式：终端风格带边框按钮 + 平台图标（Apple / Linux / Windows 内联 SVG）。

### 6. Footer 页脚

- License 信息
- 简洁单行

## 设计系统

### 配色

- 背景：`#0d1117`（GitHub dark）或 `#1a1b26`（Tokyo Night 风格）
- 卡片/交替区域背景：`#161b22`
- 主强调色：`#58a6ff`（蓝色，链接和 CTA）
- 辅助强调色：`#3fb950`（绿色，终端风格高亮）
- 主文字：`#e6edf3`
- 辅助文字：`#8b949e`
- 边框：`#30363d`

### 字体

- 标题：系统无衬线字体栈（`-apple-system, BlinkMacSystemFont, "Segoe UI", ...`）
- 代码/终端块：系统等宽字体栈（`"SF Mono", "Cascadia Code", "Fira Code", Consolas, monospace`）
- 正文：系统无衬线

### 响应式

- 桌面端：最大宽度容器（~1100px），多列网格
- 平板：2 列特性网格，截图并排
- 移动端：单列，堆叠布局

### 交互

- 锚点导航平滑滚动
- 按钮和卡片微妙 hover 效果（边框发光或透明度变化）
- 不需要 JS 框架，仅用原生 JS 实现平滑滚动

## 文件结构

```
quicktui/
├── index.html          # 主页面
├── css/
│   └── style.css       # 样式文件
├── images/
│   ├── iphone-placeholder.svg    # iPhone 截图占位符
│   └── ipad-placeholder.svg      # iPad 截图占位符
├── CNAME               # quicktui.ai
└── README.md
```

## 不在范围内

- 无分析或追踪
- 无联系表单或邮件订阅
- 无博客或多页内容
- 无 JavaScript 框架
- 无服务端渲染
- 截图仅占位，真实素材后续添加

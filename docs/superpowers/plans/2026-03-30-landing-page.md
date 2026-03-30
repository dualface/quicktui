# QuickTUI Landing Page 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 QuickTUI 创建一个暗色终端风格的单页静态 landing page，托管在 GitHub Pages。

**Architecture:** 纯静态单页应用，单个 `index.html` + 独立 CSS 文件 + 占位图片 SVG。无构建步骤，无 JS 框架。CSS 实现所有视觉效果（终端风格背景、卡片、代码块）。

**Tech Stack:** HTML5, CSS3, 原生 JavaScript（仅用于平滑滚动）

---

## 文件结构

| 文件 | 职责 |
|------|------|
| `CNAME` | GitHub Pages 自定义域名 `quicktui.ai` |
| `index.html` | 页面结构：Hero / Features / Screenshots / Quick Start / Download / Footer |
| `css/style.css` | 所有样式：配色、布局、响应式、交互效果 |
| `images/iphone-placeholder.svg` | iPhone 截图占位符（设备边框 + 灰色填充 + 文字标注） |
| `images/ipad-placeholder.svg` | iPad 截图占位符（设备边框 + 灰色填充 + 文字标注） |

---

### Task 1: CNAME 和项目基础

**Files:**
- Modify: `CNAME`
- Modify: `README.md`

- [ ] **Step 1: 更新 CNAME 文件**

```
quicktui.ai
```

- [ ] **Step 2: 更新 README.md**

```markdown
# QuickTUI

Landing page for [QuickTUI](https://quicktui.ai) — a tmux-based remote terminal manager with native iPhone & iPad support.
```

- [ ] **Step 3: 提交**

```bash
git add CNAME README.md
git commit -m "chore: update CNAME to quicktui.ai and update README"
```

---

### Task 2: CSS 样式文件

**Files:**
- Create: `css/style.css`

- [ ] **Step 1: 创建 css/style.css，包含完整样式**

```css
/* === Reset & Base === */
*, *::before, *::after {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

:root {
  --bg-primary: #0d1117;
  --bg-secondary: #161b22;
  --accent-blue: #58a6ff;
  --accent-green: #3fb950;
  --text-primary: #e6edf3;
  --text-secondary: #8b949e;
  --border-color: #30363d;
  --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  --font-mono: "SF Mono", "Cascadia Code", "Fira Code", Consolas, "Liberation Mono", monospace;
}

html {
  scroll-behavior: smooth;
}

body {
  font-family: var(--font-sans);
  background-color: var(--bg-primary);
  color: var(--text-primary);
  line-height: 1.6;
  -webkit-font-smoothing: antialiased;
}

/* === Layout === */
.container {
  max-width: 1100px;
  margin: 0 auto;
  padding: 0 24px;
}

section {
  padding: 80px 0;
}

/* === Hero === */
.hero {
  min-height: 70vh;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
  position: relative;
  overflow: hidden;
}

.hero::before {
  content: "";
  position: absolute;
  inset: 0;
  background-image: radial-gradient(circle, var(--border-color) 1px, transparent 1px);
  background-size: 24px 24px;
  opacity: 0.4;
  pointer-events: none;
}

.hero-content {
  position: relative;
  z-index: 1;
}

.hero h1 {
  font-family: var(--font-mono);
  font-size: clamp(2.5rem, 6vw, 4rem);
  font-weight: 700;
  margin-bottom: 16px;
  letter-spacing: -0.02em;
}

.hero .tagline {
  font-size: clamp(1rem, 2.5vw, 1.25rem);
  color: var(--text-secondary);
  max-width: 640px;
  margin: 0 auto 40px;
  line-height: 1.5;
}

/* === Buttons === */
.btn-primary {
  display: inline-block;
  padding: 14px 36px;
  background-color: var(--accent-blue);
  color: #ffffff;
  text-decoration: none;
  border-radius: 8px;
  font-size: 1.1rem;
  font-weight: 600;
  transition: opacity 0.2s, transform 0.2s;
}

.btn-primary:hover {
  opacity: 0.9;
  transform: translateY(-1px);
}

/* === Features === */
.features {
  background-color: var(--bg-secondary);
}

.features-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 24px;
}

.feature-card {
  background-color: var(--bg-primary);
  border: 1px solid var(--border-color);
  border-radius: 12px;
  padding: 32px;
  transition: border-color 0.2s;
}

.feature-card:hover {
  border-color: var(--accent-blue);
}

.feature-card .icon {
  width: 40px;
  height: 40px;
  margin-bottom: 16px;
  color: var(--accent-green);
}

.feature-card h3 {
  font-family: var(--font-mono);
  font-size: 1.1rem;
  margin-bottom: 8px;
}

.feature-card p {
  color: var(--text-secondary);
  font-size: 0.95rem;
  line-height: 1.5;
}

/* === Screenshots === */
.screenshots {
  text-align: center;
}

.screenshots h2 {
  font-family: var(--font-mono);
  font-size: clamp(1.5rem, 3vw, 2rem);
  margin-bottom: 48px;
}

.screenshots-grid {
  display: flex;
  justify-content: center;
  align-items: flex-end;
  gap: 40px;
  flex-wrap: wrap;
}

.screenshot-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
}

.screenshot-item img {
  max-width: 100%;
  height: auto;
  border-radius: 8px;
}

.screenshot-item .label {
  color: var(--text-secondary);
  font-size: 0.85rem;
}

/* === Quick Start === */
.quickstart {
  background-color: var(--bg-secondary);
}

.quickstart h2 {
  font-family: var(--font-mono);
  font-size: clamp(1.5rem, 3vw, 2rem);
  margin-bottom: 32px;
  text-align: center;
}

.code-block {
  background-color: var(--bg-primary);
  border: 1px solid var(--border-color);
  border-radius: 12px;
  padding: 24px;
  overflow-x: auto;
  max-width: 720px;
  margin: 0 auto;
}

.code-block pre {
  font-family: var(--font-mono);
  font-size: 0.9rem;
  line-height: 1.7;
  white-space: pre;
}

.code-block .comment {
  color: var(--accent-green);
}

.code-block .command {
  color: var(--text-primary);
}

/* === Download === */
.download h2 {
  font-family: var(--font-mono);
  font-size: clamp(1.5rem, 3vw, 2rem);
  margin-bottom: 12px;
  text-align: center;
}

.download .subtitle {
  color: var(--text-secondary);
  text-align: center;
  margin-bottom: 48px;
}

.download-group {
  margin-bottom: 40px;
}

.download-group h3 {
  font-family: var(--font-mono);
  font-size: 1rem;
  color: var(--text-secondary);
  margin-bottom: 16px;
  text-align: center;
}

.download-buttons {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 12px;
}

.btn-download {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 12px 20px;
  background-color: transparent;
  color: var(--text-primary);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  text-decoration: none;
  font-size: 0.9rem;
  transition: border-color 0.2s, background-color 0.2s;
}

.btn-download:hover {
  border-color: var(--accent-blue);
  background-color: rgba(88, 166, 255, 0.1);
}

.btn-download svg {
  width: 20px;
  height: 20px;
  flex-shrink: 0;
}

/* === Footer === */
.footer {
  border-top: 1px solid var(--border-color);
  padding: 24px 0;
  text-align: center;
  color: var(--text-secondary);
  font-size: 0.85rem;
}

/* === Section titles (shared) === */
.section-title {
  font-family: var(--font-mono);
  font-size: clamp(1.5rem, 3vw, 2rem);
  margin-bottom: 48px;
  text-align: center;
}

/* === Responsive === */
@media (max-width: 768px) {
  section {
    padding: 60px 0;
  }

  .features-grid {
    grid-template-columns: 1fr;
  }

  .screenshots-grid {
    flex-direction: column;
    align-items: center;
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add css/style.css
git commit -m "feat: add landing page stylesheet with dark terminal theme"
```

---

### Task 3: 截图占位符 SVG

**Files:**
- Create: `images/iphone-placeholder.svg`
- Create: `images/ipad-placeholder.svg`

- [ ] **Step 1: 创建 iPhone 占位符 SVG**

创建 `images/iphone-placeholder.svg`，尺寸比例模拟 iPhone（约 280x560），深灰色背景 + 圆角设备边框 + 居中文字 "iPhone Screenshot"。

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="280" height="560" viewBox="0 0 280 560">
  <rect x="0" y="0" width="280" height="560" rx="36" ry="36" fill="#1a1b26" stroke="#30363d" stroke-width="2"/>
  <rect x="12" y="12" width="256" height="536" rx="24" ry="24" fill="#0d1117"/>
  <text x="140" y="280" text-anchor="middle" dominant-baseline="middle" fill="#8b949e" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="16">iPhone Screenshot</text>
</svg>
```

- [ ] **Step 2: 创建 iPad 占位符 SVG**

创建 `images/ipad-placeholder.svg`，尺寸比例模拟 iPad（约 480x360），深灰色背景 + 圆角设备边框 + 居中文字 "iPad Screenshot"。

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="480" height="360" viewBox="0 0 480 360">
  <rect x="0" y="0" width="480" height="360" rx="24" ry="24" fill="#1a1b26" stroke="#30363d" stroke-width="2"/>
  <rect x="12" y="12" width="456" height="336" rx="12" ry="12" fill="#0d1117"/>
  <text x="240" y="180" text-anchor="middle" dominant-baseline="middle" fill="#8b949e" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="16">iPad Screenshot</text>
</svg>
```

- [ ] **Step 3: 提交**

```bash
git add images/iphone-placeholder.svg images/ipad-placeholder.svg
git commit -m "feat: add iPhone and iPad screenshot placeholder SVGs"
```

---

### Task 4: HTML 页面

**Files:**
- Create: `index.html`

- [ ] **Step 1: 创建 index.html，包含完整页面结构**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>QuickTUI — Remote Terminal Manager</title>
  <meta name="description" content="Drive AI Agents from anywhere — a tmux-based remote terminal manager with native iPhone &amp; iPad support.">
  <link rel="stylesheet" href="css/style.css">
</head>
<body>

  <!-- Hero -->
  <section class="hero">
    <div class="hero-content container">
      <h1>QuickTUI</h1>
      <p class="tagline">Drive AI Agents from anywhere — a tmux-based remote terminal manager with native iPhone &amp; iPad support.</p>
      <a href="#download" class="btn-primary">Download</a>
    </div>
  </section>

  <!-- Features -->
  <section class="features">
    <div class="container">
      <h2 class="section-title">Features</h2>
      <div class="features-grid">

        <div class="feature-card">
          <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="4 17 10 11 4 5"></polyline>
            <line x1="12" y1="19" x2="20" y2="19"></line>
          </svg>
          <h3>Full Terminal Experience</h3>
          <p>Deeply integrated with tmux. Manage sessions, windows, panes, scroll history, and copy mode — all from your device.</p>
        </div>

        <div class="feature-card">
          <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="5" y="2" width="14" height="20" rx="2" ry="2"></rect>
            <line x1="12" y1="18" x2="12.01" y2="18"></line>
          </svg>
          <h3>Native iPhone &amp; iPad App</h3>
          <p>A smooth, responsive terminal and tmux experience built specifically for iOS.</p>
        </div>

        <div class="feature-card">
          <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"></circle>
            <line x1="2" y1="12" x2="22" y2="12"></line>
            <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path>
          </svg>
          <h3>Browser-Based Terminal</h3>
          <p>The same great experience as the iOS app, right in your browser. Works on any platform.</p>
        </div>

        <div class="feature-card">
          <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"></rect>
            <path d="M16 3h-8l-2 4h12z"></path>
          </svg>
          <h3>Terminal-Optimized Toolbar</h3>
          <p>A custom quick-access toolbar designed for terminal workflows, dramatically boosting your productivity.</p>
        </div>

      </div>
    </div>
  </section>

  <!-- Screenshots -->
  <section class="screenshots">
    <div class="container">
      <h2 class="section-title">See It in Action</h2>
      <div class="screenshots-grid">
        <div class="screenshot-item">
          <img src="images/iphone-placeholder.svg" alt="QuickTUI on iPhone" width="280" height="560">
          <span class="label">iPhone</span>
        </div>
        <div class="screenshot-item">
          <img src="images/ipad-placeholder.svg" alt="QuickTUI on iPad" width="480" height="360">
          <span class="label">iPad</span>
        </div>
      </div>
    </div>
  </section>

  <!-- Quick Start -->
  <section class="quickstart">
    <div class="container">
      <h2 class="section-title">Quick Start</h2>
      <div class="code-block">
        <pre><span class="comment"># Download and run</span>
<span class="command">curl -fsSL https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-darwin-arm64 -o quicktui</span>
<span class="command">chmod +x quicktui</span>
<span class="command">export QUICKTUI_TOKEN=your-secret-token</span>
<span class="command">./quicktui</span></pre>
      </div>
    </div>
  </section>

  <!-- Download -->
  <section class="download" id="download">
    <div class="container">
      <h2 class="section-title">Download</h2>
      <p class="subtitle">Get QuickTUI for your platform</p>

      <div class="download-group">
        <h3>Server</h3>
        <div class="download-buttons">
          <a href="https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-darwin-arm64" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>
            macOS (Apple Silicon)
          </a>
          <a href="https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-darwin-amd64" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>
            macOS (Intel)
          </a>
          <a href="https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-linux-amd64" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12.504 0c-.155 0-.315.008-.48.021-4.226.333-3.105 4.807-3.17 6.298-.076 1.092-.3 1.953-1.05 3.02-.885 1.051-2.127 2.75-2.716 4.521-.278.832-.41 1.684-.287 2.489a.424.424 0 00-.11.135c-.26.268-.45.6-.663.839-.199.199-.485.267-.797.4-.313.136-.658.269-.864.68-.09.189-.136.394-.132.602 0 .199.027.4.055.536.058.399.116.728.04.97-.249.68-.28 1.145-.106 1.484.174.334.535.47.94.601.81.2 1.91.135 2.774.6.926.466 1.866.67 2.616.47.526-.116.97-.464 1.208-.946.587-.003 1.23-.269 2.26-.334.699-.058 1.574.267 2.577.2.025.134.063.198.114.333l.003.003c.391.778 1.113 1.345 1.884 1.345.358 0 .739-.134 1.107-.414 1.48-.93.39-2.786.348-3.063-.035-.235-.108-.39-.2-.553-.19-.319-.397-.607-.497-.978-.067-.248-.091-.529-.062-.79.258.065.515.117.692.146.352.048.649.061.898.061 1.077 0 1.37-.676 1.37-.87 0-.012-.002-.024-.005-.036l-.004-.02c-.193-.455-.682-.696-1.27-.696-.387 0-.838.072-1.29.196-.03-.165-.063-.365-.093-.46-.104-.315-.244-.455-.405-.601-.053-.048-.109-.099-.166-.15.076-.048.126-.098.166-.15.076-.098.13-.198.16-.319.046-.18.053-.381 0-.564-.046-.18-.152-.356-.317-.466-.165-.11-.38-.147-.57-.137l-.003.003c-.163-.005-.326.047-.46.166-.135.12-.222.295-.252.484-.03.174-.01.396.09.544l.005.006c.103.148.238.27.368.336-.015.044-.035.09-.064.13-.043.067-.11.126-.188.179-.037-.044-.078-.09-.108-.15-.066-.093-.123-.186-.198-.249-.123-.086-.243-.124-.363-.08-.113.04-.203.15-.236.302-.033.153-.006.36.068.477l.005.005c.01.013.013.023.017.035-.11.052-.23.094-.353.132a4.397 4.397 0 01-.257.065c-.143.028-.157.042-.157.063 0 .009.003.02.006.032-.082.042-.163.093-.241.147l-.06-.125c-.018-.04-.045-.082-.088-.128-.043-.047-.102-.089-.175-.127-.074-.038-.156-.067-.249-.068H9.22c-.155 0-.318.028-.455.079-.137.05-.25.126-.335.218l-.005.005c-.098.11-.151.252-.15.4 0 .148.059.295.163.403.103.108.248.168.396.18l.013.001c.106.006.202-.03.292-.078.042.013.088.024.13.032l.02.003c-.043.058-.093.112-.166.18l-.044.04-.016.016c-.12.12-.246.247-.343.396-.096.148-.16.325-.17.518-.01.185.042.394.172.53l.01.01c.13.15.31.24.504.24.19 0 .363-.084.512-.214.075-.065.143-.145.2-.223l.003-.005.06-.092.036.006c.091.014.193.022.299.022.303 0 .618-.063.818-.238l.005-.005c.088-.084.14-.187.177-.29.035-.105.054-.21.07-.307l.005-.034c.017-.1.026-.163.05-.216.022-.05.062-.102.152-.178l.006-.005c.26-.22.466-.455.612-.69.146-.237.235-.477.283-.715.023-.113.037-.226.04-.343.1.037.206.06.312.068.06.006.12.008.18.008.3 0 .57-.096.77-.315.2-.219.317-.537.317-.9z"/></svg>
            Linux (x86_64)
          </a>
          <a href="https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-windows-amd64.exe" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M0 3.449L9.75 2.1v9.451H0m10.949-9.602L24 0v11.4H10.949M0 12.6h9.75v9.451L0 20.699M10.949 12.6H24V24l-12.9-1.801"/></svg>
            Windows (x86_64)
          </a>
          <a href="https://github.com/dualface/remote-tmux/releases/latest/download/quicktui-windows-arm64.exe" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M0 3.449L9.75 2.1v9.451H0m10.949-9.602L24 0v11.4H10.949M0 12.6h9.75v9.451L0 20.699M10.949 12.6H24V24l-12.9-1.801"/></svg>
            Windows (ARM64)
          </a>
        </div>
      </div>

      <div class="download-group">
        <h3>iOS App</h3>
        <div class="download-buttons">
          <a href="#" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>
            App Store
          </a>
          <a href="#" class="btn-download">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>
            TestFlight
          </a>
        </div>
      </div>
    </div>
  </section>

  <!-- Footer -->
  <footer class="footer">
    <div class="container">
      <p>&copy; 2026 QuickTUI. All rights reserved.</p>
    </div>
  </footer>

</body>
</html>
```

- [ ] **Step 2: 提交**

```bash
git add index.html
git commit -m "feat: add landing page HTML with all sections"
```

---

### Task 5: 本地预览验证

**Files:** 无文件变更

- [ ] **Step 1: 启动本地 HTTP 服务器预览**

```bash
cd /Users/dualface/Desktop/Works/quicktui && python3 -m http.server 8080
```

在浏览器打开 `http://localhost:8080` 验证：

1. Hero 区域：产品名 + tagline + Download 按钮显示正常
2. Features：4 个特性卡片显示正常，2x2 网格
3. Screenshots：iPhone 和 iPad 占位符显示正常
4. Quick Start：终端代码块显示正常，注释为绿色
5. Download：所有平台按钮显示正常，链接正确
6. Footer：底部信息显示正常
7. 响应式：缩小浏览器窗口，移动端布局正常切换为单列
8. 平滑滚动：点击 Download 按钮能平滑滚动到下载区域

- [ ] **Step 2: 如有问题，修复后提交**

```bash
git add -A
git commit -m "fix: landing page adjustments after preview"
```

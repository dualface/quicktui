# Repository Guidelines

## 结构

这是静态官网加安装脚本仓库。`index.html` 是主落地页，当前样式直接内联在页面里；`privacy.html` 是隐私页；`images/` 放 logo、设备边框和截图资源；`docs/` 放站点素材；`q.sh` 是 POSIX `sh` 安装/卸载脚本；`tests/test_install.sh` 是安装器回归测试；`Dockerfile.test` 用于在干净容器里跑同一套测试。

## 常用命令

没有前端构建流程，主要是静态 HTML 和 shell。常用命令：`sh q.sh --help` 查看当前安装器参数，`sh tests/test_install.sh` 跑本地回归，`docker build -f Dockerfile.test -t quicktui-test . && docker run --rm quicktui-test` 在容器里复现测试环境，`python3 -m http.server` 本地预览页面，`git diff --check` 做补丁基本检查。

## 编码约定

HTML 保持现有 2 空格缩进；样式改动直接编辑 `index.html` 里的 `<style>`，不要再引入第二份样式源。`q.sh` 必须保持 POSIX `sh` 兼容，不能引入 bash 语法。截图和资源文件按设备分组命名，例如 `images/iPad/...`、`images/iPhone/...`。测试里优先补辅助函数或 `test_<behavior>()`，不要堆一段一次性断言脚本。

## 测试与提交

安装器行为变更必须同步覆盖 `tests/test_install.sh`；不要只改脚本不补回归。站点文案或布局变更至少跑 `git diff --check`，可见样式改动再补一次浏览器 spot check。提交信息保持 why-first，按安装器、测试、站点文案/布局分 scope；行为变化要在正文写清验证步骤。不要提交真实 token、服务器地址、本地状态文件或 `.omx/` 内容。

# Security Policy

## 报告漏洞

请**不要**公开提交 issue 描述可利用的漏洞。请通过 GitHub 仓库的
**Security → Report a vulnerability**（Security Advisory）私密报告。

我们会尽快确认并回应。

## 威胁模型 / Threat Model

MooKeeper 的 `config.json` 包含任意 shell 命令并以其所有者身份执行。请勿将
`config.json` 提交到公开仓库或从不可信来源导入他人配置。

具体边界：

- 配置文件权限为 0600，防的是**同机其他用户**读取。
- **防不了任何以当前用户身份运行的恶意软件**——它们能直接改写 `config.json`，
  下次点击菜单项即以你的身份执行任意命令。这与 shell alias / Dotfiles 的
  威胁模型等价：MooKeeper 本质是一个「以当前用户身份执行任意配置命令」的启动器。
- `pgrep -f` / `pkill -f` 使用 ERE 匹配完整命令行：`process` 字段的正则元字符
  （`.` 等）会被解释，stop 命令用 `pkill -f` 时请把匹配串收紧（完整命令行，或改用
  `kill $(lsof -ti tcp:端口)` 按端口取 PID），避免误杀其它进程。
- 配置里跑 `sudo` 是**每次**都要过系统密码框（SecurityAgent，Touch ID 同样要确认）的——
  这层授权框是有意保留的边界。**请勿在 sudoers 配 `NOPASSWD`**：`config.json` 可被恶意软件改写，
  免密 sudo 会把攻击后果从「以你的身份执行命令」升级为「改一行配置 = 免密 root 持久化提权」。

## 自行发布前自查

本项目不内置任何密钥；构建产物、签名材料、`.env` 等已被 `.gitignore` 排除。发布/推送前建议跑：

```bash
gitleaks detect --source . --report-format json --report-path leaks.json
```

（`brew install gitleaks`，或 `pipx run trufflehog filesystem . --only-verified`）

另注意：产物是 ad-hoc 签名、**未经公证**。经浏览器下载的 `.pkg`/`.dmg`/`.zip` 会被 Gatekeeper 拦一次
（这**不是**安全缺陷，是 Apple 对「网上下载的未公证二进制」的既有策略）；详见 README 的「分发说明」。
要给陌生人免打扰的安装体验，只能走 Developer ID 签名 + 公证，别用 `xattr` 教用户绕过当常规做法。

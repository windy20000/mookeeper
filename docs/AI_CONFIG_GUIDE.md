# MooKeeper 配置指导（供 AI 阅读 → 替用户写 config.json）

> **本文的读者是 AI。** 你的任务：读完本文后，根据用户「我想监控/管理 XXX」的需求，
> 直接产出**完整、合法、可直接使用**的 `config.json`，并告诉用户放哪、怎么生效、怎么验证。
> 不需要再看其他文档；本文与实现逐条对齐（代码在 Sources/Config.swift、App.swift、Sampling.swift）。

## 0. 给 AI 的工作流程

1. **听需求**：用户想管理什么服务/进程/App？要监控什么？如果模糊，一次问清（哪条命令启动、
   端口多少、是否互斥、要不要网页入口），不要挤牙膏式追问。
2. **选探测方式**（见 §5 决策树）→ **写条目**（见 §4/§6 命令规则）→ **过一遍 §11 反模式清单**。
3. **输出完整 JSON**（不是片段）。config.json 是严格 JSON：**不支持注释、不许尾逗号**、UTF-8。
4. **附三行使用说明**：放到哪（§2）、怎么生效（重启 App 或 ⌘, 打开看一眼）、怎么验证（§10）。
5. 若用户已有 config.json：先让他贴现状，给**合并后的完整文件**，并保留其中你看不懂的自定义
   字段（见 §2 覆盖语义）；不要只给 diff 让手工拼。

## 1. MooKeeper 是什么

原生 macOS 菜单栏 App（无 Dock 图标）：菜单栏显示内存数字，点开菜单是
内存/SWAP/芯片/CPU/GPU/负载/风扇/温度/功率/网络/存储 头图 + **内存大户 TOP N** +
**服务/进程分组**（一键启停、运行状态、负载分级、打开网页）+ **底部动作**。
所有数据 5 秒一拍刷新。配置是纯声明式 JSON——你写「是什么、怎么探、怎么启停」，节奏与 UI 不用管。

## 2. 配置文件在哪、怎么生效

- 路径：`~/.config/mookeeper/config.json`（环境变量 `MOOKEEPER_CONFIG` 可指向别处）。
- **首次运行**：没有 config.json 时，App 自动把内置示例落地成 config.json 并加载
  （中文系统中文版、其他语言英文版）。**删掉 config.json 再重启 = 示例回来**。
- 生效：改完 JSON 重启 App 即可；或 ⌘, 打开配置窗口可视化编辑/保存。
- ⌘, 的保存是**整体覆盖**：① 表单没管理的**顶层未知字段原样保留**（如 `customField`）；
  ② 但嵌套在已知对象（`highlight`/`load`/items 条目）内的未知字段**会被丢弃**——
  提醒用户别把私有数据藏在嵌套层；③ 覆盖前自动备份 `config.json.bak`，写后 chmod 0600。
- 你直接写 JSON 时放任意额外字段都不会报错（未知字段被忽略），只是要记住上面的 ⌘, 覆盖语义。
- 内置示例 = 「快速体验」五条（计算器=process、本地 HTTP 服务器=port+响哞+二次确认停止、释放内存
  `sudo purge`=none 特权按钮、禁休眠按钮=none、Safari 只读监控=check），
  见 `config.example.json`（英）/`config.example.zh.json`（中），可当格式参照。

## 3. 顶层结构速查

```json
{
  "highlight": { "cpuPercent": 85, "gpuPercent": 85, "fanRPM": 4500,
                 "diskWarnPercent": 70, "diskCritPercent": 90, "color": "orange" },
  "topN": 6,
  "groups": [ { "title": "…", "exclusive": false, "allowStartAll": true, "allowStopAll": true,
                "items": [ { … } ] } ],
  "footer": [ { "label": "…", "command": "…", "showWhenAnyRunning": false } ]
}
```

| 键 | 类型/默认 | 语义 |
|---|---|---|
| `highlight.cpuPercent` / `gpuPercent` | Double，默认 85 | 头图 CPU/GPU 数值 ≥ 阈值显高亮色 |
| `highlight.fanRPM` | Int，默认 4500 | 风扇转速高亮阈值 |
| `highlight.diskWarnPercent` / `diskCritPercent` | Int，默认 70 / 90 | 存储占用：≥warn「资源不足」橙、≥crit「资源告急」红 |
| `highlight.color` | 默认 orange | 高亮色：`orange/red/yellow/blue/purple/green`（其他值回落 orange） |
| `topN` | Int，默认 6 | 内存大户 TOP 条数（1~50） |
| `groups` | 数组 | 分组；**全空时菜单显示「尚未配置」提示** |
| `footer` | 数组 | 底部动作（常驻按钮） |

所有顶层键都可省略（省略 = 内置默认）。分组内至少要有非空 `title`；条目至少 `key` + `label`。

**已硬编、不要写进配置**（写了也会被忽略）：服务负载分级阈值（连接 1/10 条、CPU 15/70%、
GPU 10/50%、IO 1024/10240 KB/s，见 §7）、条目启停超时（start 660s / stop 330s）、
底部动作超时（960s）、二次确认窗口（20s）。旧配置里这些字段无害，下次 ⌘, 保存自然丢弃。

## 4. 条目（item）字段全解

```json
{
  "key": "litellm",              // 必填；全配置内唯一（跨分组也不能重复）
  "label": "LiteLLM 网关",        // 必填；运行中显示的名称
  "labelOff": "未运行",           // 可选；未运行时显示的文案（服务「未运行」/模型「已卸载」）
                                 // 缺省跟随系统语言：中文「未运行」/英文「Not running」
  "probe": "port",               // port | process | pidFile | check | none（缺省 port）
  "port": 4000,                  // probe=port：探测 127.0.0.1:port 的 TCP 连通
  "process": "litellm",          // probe=process：pgrep -f 正则（匹配完整命令行）——**值要能唯一锚定**，
                                 // 裸进程名常误伤常驻同名家族（见 §11/§12② 计算器例）
  "pidFile": "~/run/x.pid",      // probe=pidFile：文件首个空白前 token 视为 PID，kill -0 判活（~ 会展开）
  "check": "curl -s http://x/health | grep -q ok",   // probe=check：exit 0 = 运行中
  "start": "…",                  // 启动命令（可省＝纯监控不可启）
  "stop": "…",                   // 停止命令（可省）
  "precheck": "…",               // 启动前门禁：非 0 拒绝启动并发通知
  "requireFreeGB": 8,            // 内存门槛：剩余可用内存不足 N GB 拒绝启动
  "confirmStop": false,          // true = 停止需两次点击（窗口内，默认 20s）
  "loadable": true,              // false = 不提供启动（纯监控项）
  "gpuEngine": false,            // true = 该条负载里的 GPU 看整机 GPU 利用率（llama-server 等按进程统计不到的场景）
  "url": "http://localhost:4000",// 可选；运行中在条目下多一行「↗ 打开网页」（完整 URL）
  "soundOnStart": false,         // true = 启动命令成功跑完后通知带哞声（慢启动服务/模型用）
}
```

要点：
- **`key` 全局唯一**：⌘, 保存会拦重复；重复的后果是条目互相覆盖、动作串台。
- `probe` 若省略，按字段推断（有 `process` → process，有 `pidFile` → pidFile，有 `check` → check，
  否则 port）。**建议显式写**，可读性好。
- 各探测方式能拿到的数据不同：`port`/`process`/`pidFile` 都返回进程 PID，因此都有逐进程
  CPU%/内存/IO 负载数据（port 额外有**在途连接数**）；**`check` 和 `none` 没有任何负载数据**
  （连进程都拿不到）。
- `check` 命令有 **30 秒结果缓存**（防止每 5 秒执行一次用户脚本拖慢主循环）——写 check 时
  命令要快、要幂等。
- `soundOnStart`：给**启动慢**的条目（模型装载分钟级、重脚本）开「启动完成响哞」——用户点完启动
  可以走开，听见哞 = 起好了。只在启动**成功**时响（失败/超时本来就响）；「全部启动」里勾选的条目
  完成当下也逐条响。启动快的条目别开（横幅本身够了，响了反而吵）。

## 5. 探测方式决策树

```
服务/模型监听本地端口吗？
├─ 是 → "probe":"port"（最即时；在途连接数直接可用）
│        ⚠ 只探 127.0.0.1：服务必须本地监听（绑 127.0.0.1 或 0.0.0.0 都行）
└─ 否
   ├─ 是普通进程/App？ → "probe":"process"（pgrep -f 正则）
   ├─ 守护进程只写 PID 文件？ → "probe":"pidFile"
   ├─ 需要自定义健康检查逻辑？ → "probe":"check"
   └─ 纯动作、无需跟踪状态？ → "probe":"none"（点一下就执行，永远显示未运行）
```

## 6. start/stop 命令书写规则（最容易踩坑的地方）

- **两种形态**：字符串（推荐）→ `/bin/sh -c` 执行，可用管道/引号/`&&`/重定向；
  数组 → 直接 argv 执行（不走 shell，每个元素会做 `~` 展开）。
- **start 命令必须自己退出**。超时基准是「进程退出」：常驻服务要**后台化**——
  末尾加 ` &`（如 `"ruby -run -e httpd ~/Public -b 127.0.0.1 -p 8028 &"`）。
  不加 `&` 的常驻命令会一直挂到 `startTimeoutSec`（默认 660s）超时，App 会发
  「超时未返回——以菜单状态为准」通知并 SIGTERM。
- **执行环境**：继承 App 环境，`PATH` 前置了 `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  （homebrew 工具可直接写名字），`LC_ALL=C`、`PYTHONIOENCODING=utf-8`。没有 TTY、不加载 shell rc。
- **避 TCC 授权弹窗**：别用 `osascript`（quit app / 控制其他 App 会触发「想控制…」弹窗）。
  GUI App 的开关用 `open -a X` + `pkill -x X`（精确进程名，零授权）。
- **stop 首选「按端口取 PID」，`pkill -f` 只留给无端口进程**：有监听端口的服务用
  `kill $(lsof -ti tcp:8028 -s TCP:LISTEN) 2>/dev/null || true`——端口即锚，天然不误伤（实测 2026-10-04）。
  `pkill -f` 匹配完整命令行正则，强但危险：锚点必须唯一命中（如 `worker.*queue`），写前先 `pgrep -f` 空跑；
  `pkill -x` 精确匹配进程名（安全，适合 GUI App）。
- `stop` 命令同样必须会退出；`probe:none` 的条目通常不写 stop（命令自己会结束，如 `caffeinate -t 3600 &`）。

## 7. 分组行为与负载分级

- `exclusive: true`（互斥组）：启动新条目前**自动停掉组内其他在跑的**（自动停旧不发通知）；
  组内不显示「全部启动」按钮。适合大模型分组（一次只驻留一个）。
- `allowStartAll` / `allowStopAll`（默认 true）：控制「▶ 全部启动」「■ 全部停止」按钮显隐；
  「全部启动」只对空闲条目生效，逐条按序执行。
- ⚠️ **`exclusive` 与 `allowStartAll` 在配置界面里互斥、只能勾一个**（勾「互斥」会自动取消
  「允许全部启动」）。所以互斥组只写 `exclusive: true` 就行，**别再写 `allowStartAll`**——写了
  虽无害（运行时本来就压掉按钮），但用户在 ⌘, 里保存一次就会被归零成 false。
  两个都不勾＝不互斥、也不显示「▶ 全部启动」（纯逐条手动，合法但少见）。
- **负载分级**（每条目实时算，取最重一档：空转/中度/重度；**阈值内置不可调**）：

| 维度 | 中度 | 重度 | 口径 |
|---|---|---|---|
| 在途连接 | 1 条 | 10 条 | 本地端口上的 ESTABLISHED 连接数（= 进行中的请求） |
| CPU | 15% | 70% | 条目全部进程 CPU% 之和（可超 100，多核） |
| GPU | 10% | 50% | `gpuEngine` 条目看整机 GPU 利用率（0~100），否则恒 0 |
| IO | 1024 KB/s | 10240 KB/s | 条目全部进程磁盘读写 KB/s 之和 |

- ⌘, 表单**允许**「中度 > 重度」（= 跳过中档直接重度），不是错误；按用户真实意图设。

## 8. footer 底部动作

```json
{ "label": "恢复默认栈", "command": "devup --all", "showWhenAnyRunning": false }
```

- `label` + `command` 都非空才生效（⌘, 保存会拦缺项；直接写 JSON 缺一会整条被忽略）。
- `showWhenAnyRunning: true` = 仅当任意分组条目在跑时才显示这个按钮。
- `command` 是 shell 字符串，规则同 §6；超时内置 960s，长任务自己想办法分步。
- 完成会发「批量完成/动作完成」通知。

## 9. 保存校验与通知行为（AI 提醒用户时用）

⌘, 保存会**拦截**：空分组标题 / 空 key / 空名称 / **跨分组重复 key** / 端口探测条目端口不是 1~65535 /
底部动作缺名称或命令 / 磁盘「预警 > 告急」（相等合法 = 只看告急）。手工写的 JSON 不走表单，但加载时
会兜一项：**端口探测条目端口非法/缺失 → 菜单头部显示 ⚠ 橙字警告**（条目仍加载，不至于永远 ○ 却无线索）；
其余问题不拦，你生成的配置要自己保证。`topN` 超出 1~50 会被静默收顶。

通知与声音铁律（用户定的）：**响** = 内存预警/告急、启动被阻（内存不足、前置检查未过、批量被跳过）、
停止失败、单项/批量失败、超时仍在进行、批量完成；**不响** = 启动中、启动完成、停止中、停止完成、
自动停旧、批量里单项的进行中与完成、停止前的「再确认一次」提示。

## 10. 用户怎么验证（把这些步骤写给用户）

1. 重启 App（菜单栏重新出现内存数字），打开菜单看分组是否出现、○/● 是否正确。
2. ⌘, 打开配置窗口：能加载、能编辑、保存不报错即结构合法；「载入示例」「清空配置」可随时试。
3. 想无风险试配置：`MOOKEEPER_CONFIG=/tmp/test.json ~/Applications/MooKeeper.app/Contents/MacOS/mookeeper --dump`
   会按 /tmp/test.json 打印整份菜单（○/●、分组、端口），不动真实配置。
4. 通知链路验证：`pkill -x mookeeper` 后
   `open ~/Applications/MooKeeper.app --args --test-notify`（裸二进制测不了通知授权那条路）。

## 11. 反模式清单（生成前逐条自查）

- [ ] start 写了常驻命令却没加 `&`
- [ ] 用了 `osascript`（TCC 弹窗），尤其 quit App
- [ ] 有监听端口的服务，stop 却用 `pkill -f` 手写正则（首选 `kill $(lsof -ti tcp:PORT -s TCP:LISTEN) 2>/dev/null || true`，
      端口即锚不误伤）；确需 `-f` 时正则没带端口/路径锚点会误伤；同理 `probe:"process"` 值太泛会命中系统常驻进程——
      `Safari` 中 SafeBrowsing/PlatformSupport 全家、`Calculator` 中常驻小组件 `CalculatorWidget`（没开也亮 ●、
      `-x` 系 stop 杀不到＝停止"无效"）——精确判断改 `probe:"check": "pgrep -x 名字"`，或锚尾段路径
      `Contents/MacOS/名字$`（先在本机 `pgrep` 空跑一遍，确认没开时 rc≠0）
- [ ] port 条目写 0 或负数（port 探测要求 ≥1；`port:0` 永远探不活）
- [ ] 服务监听在非 localhost（127.0.0.1 探不到）
- [ ] key 重复 / 空标题 / 空 label
- [ ] 磁盘 warn > crit
- [ ] 把用户看不懂的自定义数据塞进 `highlight`/`load`/条目内部（⌘, 保存会丢）
- [ ] check 命令又慢又无缓存意识（30s 缓存挡不住 >30s 的慢命令）
- [ ] 互斥组里塞了需要并存的两个服务

## 12. 配方（可直接改名的现成模板）

**① 本地 Web 服务（port 探测 + 网页入口 + 启动响哞 + 停止二次确认）**
```json
{ "key": "web", "label": "本地 HTTP 服务器", "port": 8028, "soundOnStart": true, "confirmStop": true,
  "start": "ruby -run -e httpd ~/Public -b 127.0.0.1 -p 8028 &",
  "stop": "kill $(lsof -ti tcp:8028 -s TCP:LISTEN) 2>/dev/null || true", "url": "http://localhost:8028" }
```
> `confirmStop` 只作用于「运行中」的停止动作：点一下变橙色「⚠ 再点一次确认停止（剩 20s）」，窗口内再点才真停。
> 没有 stop 的条目（如 `probe:"none"` 一次性按钮、纯监控项）配它不会渲染——别往这类条目塞。

**② GUI App 开关（零 TCC；start 用 `open -a` 按名字走 LaunchServices，中英文系统都命中；别写 `xxx.app/Contents/MacOS/yyy` 相对路径，会挂）**
```json
{ "key": "calculator", "label": "计算器", "probe": "process", "process": "Contents/MacOS/Calculator$",
  "start": "open -a Calculator", "stop": "pkill -f 'Contents/MacOS/Calculator$'" }
```
> `process` **千万别裸写 `Calculator`**——`pgrep -f` 是子串匹配，会命中常驻的
> `CalculatorWidget.appex/Contents/MacOS/CalculatorWidget`（桌面小组件进程，App 没开也被点亮），
> 且 `pkill -x Calculator` 杀不到它 →「常亮 + 停止无效」（2026-10-04 实测）。写**尾锚路径判据**
> `Contents/MacOS/Calculator$`：只命中 App 本体（`$` 把 `CalculatorWidget` 挡在门外），stop 同锚。
> GUI App 本体路径可能在 Cryptex/Preboot 卷（macOS 26 的 Safari 就如此），所以别锚绝对路径、锚尾段。

**③ 一次性动作按钮（不跟踪状态）**
```json
{ "key": "no-sleep", "label": "1 小时内禁止休眠", "probe": "none", "start": "caffeinate -t 3600 &" }
```

**④ 大模型互斥组（整机 GPU + 内存门槛 + 前置检查 + 二次确认停止）**
```json
{ "title": "大模型", "exclusive": true, "allowStopAll": true,
  "items": [
    { "key": "qwen9b", "label": "Qwen3.5-9B", "labelOff": "已卸载", "port": 8090,
      "gpuEngine": true, "requireFreeGB": 8, "confirmStop": true,
      "start": "/opt/homebrew/bin/llama-server --port 8090 -m ~/models/qwen9b.gguf &",
      "stop": "kill $(lsof -ti tcp:8090 -s TCP:LISTEN) 2>/dev/null || true", "url": "http://localhost:8090" },
    { "key": "ocr", "label": "HunyuanOCR", "labelOff": "已卸载", "port": 8091,
      "gpuEngine": true, "start": "/opt/homebrew/bin/llama-server --port 8091 -m ~/models/ocr.gguf &",
      "stop": "kill $(lsof -ti tcp:8091 -s TCP:LISTEN) 2>/dev/null || true" }
  ] }
```

**⑤ 纯监控项（不给启动按钮）**
```json
{ "key": "docker", "label": "Docker 守护", "probe": "process", "process": "com.docker.backend", "loadable": false }
```

**⑥ PID 文件型守护**
```json
{ "key": "mydaemon", "label": "My Daemon", "probe": "pidFile", "pidFile": "~/.mydaemon.pid",
  "start": "~/bin/mydaemon -d && sleep 0.2", "stop": "kill $(head -1 ~/.mydaemon.pid)" }
```

**⑦ 自定义健康检查（无端口/无进程名可匹配时）**
```json
{ "key": "worker", "label": "任务 Worker", "probe": "check",
  "check": "pgrep -f 'worker.*queue' >/dev/null", "start": "~/bin/worker &", "stop": "pkill -f 'worker.*queue'" }
```

**⑧ footer 常驻动作**
```json
{ "label": "清理端口 8028", "command": "kill $(lsof -ti tcp:8028 -s TCP:LISTEN) 2>/dev/null || true", "showWhenAnyRunning": false }
```

**⑨ 特权动作按钮（sudo 在 App 里同样能用）**
```json
{ "key": "purge", "label": "释放内存（purge）", "probe": "none", "start": "sudo purge" }
```
> 实测（2026-10-04，macOS 26）：无终端的子进程跑 `sudo` 不会挂死在 tty 提示上，而是拉起 **SecurityAgent 弹系统
> 密码框（可 Touch ID）**，用户确认后才继续执行——所以 `sudo ...` 可以放心写进配置。每次都要过一道授权框。
> ⛔ **但别图省事去 sudoers 配 `NOPASSWD`**：`config.json` 本身可被任何以当前用户身份运行的恶意软件改写
> （SECURITY.md 的威胁模型），免密 sudo 会把这条链的后果从「以你的身份执行命令」直接升级为
> **「改一行配置 = root 持久化提权」**。每次点击弹出的密码框，正是本项目有意保留的安全边界——
> 输密码前请看清按钮对应的命令是不是自己配的，别条件反射。`probe:"none"` 按钮执行完不跟踪状态，用户长时间不理授权框会撞条目超时
> （start 660s，见 §6）。

**⑩ 只读监控某个 GUI 软件在不在开（不给启停按钮）**
```json
{ "key": "safari", "label": "Safari 浏览器", "probe": "check",
  "check": "pgrep -x Safari", "loadable": false }
```
> 不写 `start`/`stop`、`loadable:false` 关掉启动入口：未打开＝灰字「○ 未运行」，打开＝「● 运行中（·检测命令）」。
> **别图省事写 `probe:"process","process":"Safari"`**——那是 `-f` 子串匹配，macOS 常驻的 Safari SafeBrowsing /
> PlatformSupport 等一堆 agent 全带「Safari」字样，App 没开也常亮 ●（2026-10-04 实锤）。判 GUI 本体在不在，
> 要的是 `-x` 整词精确匹配，走 `check`。代价：check 有 30s 缓存＋不带逐进程负载尾注（只给 ●/○ 结论，够用）。

## 13. 一份带注释的完整骨架（复制改名字段即可，注释仅此处示意，真文件里删掉）

```json
{
  "highlight": { "cpuPercent": 75, "gpuPercent": 75, "fanRPM": 4500,
                 "diskWarnPercent": 70, "diskCritPercent": 90, "color": "orange" },
  "topN": 6,
  "groups": [
    { "title": "服务", "exclusive": false, "allowStartAll": true, "allowStopAll": true,
      "items": [ /* §12 ① ② ③ ⑤ ⑥ ⑦ ⑨ ⑩ 按需混排 */ ] },
    { "title": "大模型", "exclusive": true,
      "items": [ /* §12 ④ */ ] }
  ],
  "footer": [ /* §12 ⑧ */ ]
}
```

——写完记得跑一遍 §11 清单，再给用户 §10 的验证步骤。

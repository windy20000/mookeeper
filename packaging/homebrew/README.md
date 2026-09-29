# Homebrew（tap）分发 MooKeeper

给开发者多一条 `brew install` 的路。**这里是源码编译的 formula，不是 cask** ——
原因见下面「为什么不是 cask」。

> **前提：源码必须先推到 GitHub 并打好 tag。** 这份 formula 是**源码编译**式的——它从远端 tag 的
> tarball 现场 `./build.sh`，所以远端还没有可编译源码时，`brew install` 必然失败。
> 发版顺序固定：push 源码 → 打 tag → `./scripts/make_formula.sh <tag>` → 把产出的
> `build/mookeeper.rb` 放进 tap 的 `Formula/`。

## 一次性：建 tap 仓库

Homebrew 的 tap 就是一个名字以 `homebrew-` 开头的 GitHub 仓库，路径固定在 `Formula/`：

```bash
# 1) 在 GitHub 建一个空仓库：windy20000/homebrew-tap
git clone https://github.com/windy20000/homebrew-tap.git
cd homebrew-tap
mkdir -p Formula

# 2) 生成 formula（在 MooKeeper 源码目录里跑）
#    tag 已推 → 用 tag（sha256 稳定，推荐）；没推 → 自动回落 main
cd /path/to/mooKeeper/mooKeeper
git tag v0.1 && git push origin v0.1    # 只有第一次需要；定向推 tag，勿用 --tags（会连本地杂名 tag 一起上）
./scripts/make_formula.sh v0.1         # 产出 build/mookeeper.rb

# 3) 放进 tap
cp build/mookeeper.rb <你 clone 的 homebrew-tap>/Formula/mookeeper.rb
cd <你 clone 的 homebrew-tap> && git add Formula/mookeeper.rb && git commit -m "mookeeper 0.1" && git push
```

## 用户怎么装

```bash
brew tap windy20000/tap
brew install windy20000/tap/mookeeper          # 稳定版
brew install --HEAD windy20000/tap/mookeeper   # 跟 main 最新
brew uninstall mookeeper
```

前提和他们自己 clone 一样：Xcode Command Line Tools + macOS 14+。`brew install` 会在用户机器上
现编译（约 1–2 分钟），所以**产物没有 `com.apple.quarantine`，不会被 Gatekeeper 拦** ——
这正是选 formula 的原因。App 落在 Cellar 里，`brew info mookeeper` 的 caveats 会打印启动方式：

```bash
open $(brew --prefix)/opt/mookeeper/MooKeeper.app
```

## 为什么不是 cask

Cask 下载的是**预编译产物**，而下载来的东西带隔离属性；Homebrew 现在**有意保留**它
（`Library/Homebrew/cask/quarantine.rb` 里写着保留隔离来源，好让 Gatekeeper 继续把关），
所以 `brew install --cask` 装完照样弹「Apple 无法验证 MooKeeper …」——除非作者签名 + 公证。
源码 formula 绕开了整条链路。

## 每次发版要更新什么

| 改动 | 做什么 |
|---|---|
| 打了新 tag（如 `v0.2`） | `git push origin v0.2` → 改 `Info.plist` 版本号 → 源码目录 `./scripts/make_formula.sh v0.2` → 覆盖 tap 里的 `Formula/mookeeper.rb` → commit + push |
| 只推到 main、没打 tag | `./scripts/make_formula.sh`（回落 main）→ 覆盖 → commit。**注意**：main 的 tarball sha256 每次 push 都会变，tap 里会失配，尽量别这么发 |
| 只想让用户拿最新 | 什么都不用做，`brew install --HEAD` 每次拉 main |

## 发布前自查

```bash
brew style   Formula/mookeeper.rb     # Ruby 风格
brew audit --formula --strict Formula/mookeeper.rb
brew install --build-from-source Formula/mookeeper.rb   # 真跑一遍（会装进 Cellar）
brew test mookeeper
```

> formula 里 `depends_on macos: :sonoma` 对应 macOS 14（`Info.plist` 的 `LSMinimumSystemVersion`）；
> 项目是 arm64/x86_64 自适应，`build.sh` 按 `uname -m` 选 target，不需要在 formula 里区分架构。
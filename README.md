# 自建软件包仓库

脱离 AUR 后自行维护的 11 个包。配方快照自 2026-07-31 AUR 冻结前的状态，
当时已逐个核对提交者均为各包长期维护者，无接管痕迹。

## 日常流程

```bash
./build.sh --check          # 查有没有上游新版
./build.sh --outdated       # 有就全部构建入库
sudo pacman -Syu            # 照常升级，[nekolsd] 仓库的包会一起走
```

单独构建某个包：

```bash
./build.sh google-chrome 151.0.7922.108   # 指定版本：bump + 重算校验和 + 构建
./build.sh google-chrome                  # 不指定：按当前 PKGBUILD 构建
```

构建在 devtools 干净 chroot 里进行，产物落到 `/var/cache/pkgrepo/`（目录归当前用户
所有，构建入库不需要 root）并自动 `repo-add`。要换地方设环境变量 `REPO_DIR`。

选这个位置的两个理由：一是放在 git 检出之外，否则一次 `git clean -xdf` 会把
已构建的包连同仓库数据库删光；二是路径纯 ASCII——pacman.conf 里 `Server` 是
URL，非 ASCII 路径是否需要百分号编码存在歧义（实测两种写法 pacman 都能解析出
URL，但无法在非 root 下验证真实取包），干脆规避。

版本号变更会自动提交进 git。

## 包如何从「AUR 装的」过渡到 [nekolsd]

不需要为了迁移而重建。`pacman -Qm` 里那些包只是「pacman 不知道来源」，
一旦某个包的新版本被构建进 `[nekolsd]`，`pacman -Syu` 就会把它当作可升级项接管，
升级后它便归属 `[nekolsd]`、不再是外部包。

也就是说：**已经是最新版的包不用管，等它下次更新时自然完成迁移。**

## 配方冻结，以及 AUR 上游变更怎么处理

**日常更新完全不碰 AUR。** nvchecker 直接问厂商官网（Google 版本 API、GitHub
release、npm）拿新版本号，`build.sh` 改 pkgver、重算校验和、构建 —— 配方本身
一行不动。初始快照之后没有任何第三方代码再进入，投毒这条路是关闭的。

代价是厂商若改了导致配方失效的东西，构建会炸。但那是**响亮的失败**，
邮件立刻就到，不会悄无声息。

**上游偶尔会改配方本身**（新增依赖、改 source、加 install 脚本、打补丁）。
其中最危险的是「新增依赖」：包照样能构建、能安装，但**运行时才缺库**，
构建全程无任何报错。所以这类改动需要被发现。

`.github/workflows/aur-sync.yml` 每天检查一次，发现改动就**自动开 PR**：

```
上游配方变了 → 开 PR（分支 aur-sync/<包名>）→ 你在 GitHub 上看 diff → 合不合并你定
```

PR 里不是上游 PKGBUILD 的原样拷贝，而是「**上游的配方 + 我们的版本号**」：

- AUR 冻结在更旧的版本，整份覆盖会把版本号回退
- `pkgrel` 自动 +1 —— 配方变了而版本没变时必须递增，否则 pacman 不认为是更新的包
- 校验和重新生成（上游若改了 source 数组，旧的就对不上了）
- PR 正文附带 AUR 最近 10 条提交，便于判断改动来路

**绝不自动合并。** PKGBUILD 是会在构建机上执行的代码，合并等于同意它运行。
没有改动时不会开 PR，所以平时零打扰。

手动查看随时可用：

```bash
./build.sh --aur-diff              # 对比全部，打印到终端
./build.sh --aur-check             # 只列出有改动的包名
./build.sh --aur-apply <包名>      # 本地合并上游改动（CI 用的就是它）
```

## 为什么这样是安全的

这些包的 PKGBUILD 只是「配方」——二进制始终从厂商自己的服务器下载
（dl.google.com、downloads.1password.com、update.code.visualstudio.com、
GitHub releases 等）。AUR 从来不托管二进制。所以 AUR 冻结不妨碍构建新版本，
而配方被钉在 git 里，每次改动都看得见 diff。

`1password` 和 `helium-browser-bin` 还带上游 GPG 签名校验（`validpgpkeys`），
构建时会验证厂商签名，`build.sh` 会自动导入所需公钥。

## 版本检测

`nvchecker.toml` 定义各包的上游版本源：

| 类型 | 包 |
|---|---|
| GitHub release | 64gram-desktop-bin, helium-browser-bin, pac-pacman-aliases, protonplus, speedtest-go, vicinae-bin, visual-studio-code-bin |
| 厂商版本 API | google-chrome（Google versionhistory API）、claude-code（`downloads.claude.ai/.../stable`） |
| apt 仓库元数据 | 1password（官方没有版本 API，从其 Debian 仓库的 `Packages` 里取） |
| **手动** | **wemeet-bin** |

GitHub 源未配 token，匿名限速 60 次/小时。这里一次只查 7 个，够用；
如果撞限速，按 nvchecker 文档配 `keyfile` 加个 PAT 即可。

### claude-code 跟的是 latest

`downloads.claude.ai/claude-code-releases/` 下有 `latest` 和 `stable` 两个通道。
这里跟 `latest`，与 npm 上的 `@anthropic-ai/claude-code` 一致。

`stable` 明显更慢：2026-07-26 停在 2.1.220 之后就没再动，而同期 latest 已到 2.1.226。
嫌 latest 更新太频繁（每次约 300MB）可以把 `nvchecker.toml` 里那个 URL 改回 `stable`。

顺带一提，`pac aur upgrade` 之类工具会一直把 claude-code 报成过时——那读的是
**AUR 上的「过期」标记**（2026-08-04 有人打的），不代表 AUR 上有更新的版本可装；
AUR 已冻结在 2.1.220。以本仓库的 `./build.sh --check` 为准。

### wemeet-bin 为什么只能手动

下载 URL 形如：

```
https://updatecdn.meeting.qq.com/cos/<32位md5>/TencentMeeting_0300000000_<版本>_x86_64_default.publish.deb
```

那个 md5 无法从版本号推导，只有腾讯下载中心页面提供，而该页是 JS 动态渲染的
（抓到的 chunk 只有 720 字节的壳）。上游 AUR 维护者同样是手动更新版本号 + md5。

更新办法：打开 <https://source.meeting.qq.com/download-center.html>，
在浏览器开发者工具的网络面板里点下载、抓到真实 deb 链接，
把 URL 里的 md5 填进 `PKGBUILD` 的 `_x86_md5`，版本填 `pkgver`，然后
`updpkgsums && ./build.sh wemeet-bin`。

## 已知的上游脆弱点

`64gram-desktop-bin` 的图标取自 `github.com/TDesktop-x64/tdesktop/raw/dev/...`，
指向 **dev 分支 HEAD** 而非 tag——是个移动靶。checksum 能兜住（内容变了构建会失败），
但每次 `updpkgsums` 都会把当时的 dev 内容重新固化进来。

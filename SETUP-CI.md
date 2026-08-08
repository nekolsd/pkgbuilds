# CI 构建 + R2 分发 部署步骤

目标：GitHub Actions 定时构建 → 签名 → 推到 Cloudflare R2 → 桌面端只需 `pacman -Syu`。

以下 `repo.lsd.moe` 换成你自己的域名，`nekolsd` 是仓库名（与 workflow 里的 `REPO_NAME` 一致）。

## 1. GPG 密钥（已完成，2026-08-08）

```
主钥指纹  CEFA64B7B1308F2ECB404D423D02D08ED532F9C7   ed25519 [C] 不过期
CI 子钥   B72D9AFDD20D3A9C                           ed25519 [S] 至 2027-08-08
```

生成方式（fish 语法）：

```fish
gpg --quick-generate-key "nekolsd <nekolsd@proton.me>" ed25519 cert never
set KEYFP (gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
gpg --quick-add-key $KEYFP ed25519 sign 1y

gpg --export-secret-subkeys --armor 'B72D9AFDD20D3A9C!' > /tmp/ci-subkey.asc   # ! 不可省
gpg --export --armor $KEYFP > /tmp/pubkey.asc
```

主钥只有认证能力（`cert`），不能签名 —— 它唯一的职责是签发和吊销子钥。
签包的是子钥，而子钥可撤销：万一 GitHub 侧泄露，用主钥吊销、换新子钥重签即可，身份本身不受影响。

### 验证只导出了子钥

**不要用 `gpg --show-keys` 判断** —— 它读文件时不显示 `#` 标记，看不出主钥在不在。
用包结构：

```fish
gpg --list-packets /tmp/ci-subkey.asc | grep -iE 'gnu-dummy|secret|keyid'
```

正确的结果长这样：

```
:secret key packet:
	gnu-dummy, algo: 0            ← 主钥只是存根，私钥材料不在文件里
	keyid: 3D02D08ED532F9C7
:secret sub key packet:
	iter+salt S2K, SHA1 protection ← 子钥私钥在，且被密码短语加密
	keyid: B72D9AFDD20D3A9C
```

看到主钥那行是 `gnu-dummy` 就对了。如果它显示的是真实的 S2K/protect 参数，
说明主钥被导出了，删掉文件重来。

## 2. Cloudflare R2

1. R2 → 建 bucket（如 `arch-repo`）
2. bucket → Settings → **Custom Domain** → 绑 `repo.lsd.moe`
   （别用默认的 `*.r2.dev`，它有速率限制且 Cloudflare 声明不适合生产）
3. R2 → **Manage API Tokens** → 建 token，权限选 **Object Read & Write**
   记下 Access Key ID、Secret Access Key
4. 账号 ID 在 R2 概览页右侧

## 3. GitHub 仓库与 Secrets

```bash
git remote add origin git@github.com:<你>/pkgbuilds.git
git push -u origin main
```

Settings → Secrets and variables → Actions，添加：

| Secret | 值 |
|---|---|
| `GPG_SIGNING_KEY` | `/tmp/ci-subkey.asc` 的**全部内容** |
| `GPG_PASSPHRASE` | 你设的密码短语 |
| `GPG_KEY_ID` | `B72D9AFDD20D3A9C` |
| `R2_ACCOUNT_ID` | Cloudflare 账号 ID |
| `R2_ACCESS_KEY_ID` | R2 token 的 Access Key ID |
| `R2_SECRET_ACCESS_KEY` | R2 token 的 Secret |
| `R2_BUCKET` | bucket 名，如 `arch-repo` |

传完后删掉本地临时文件：`shred -u /tmp/ci-subkey.asc`

## 4. 首次填充 R2

**不要指望首跑 CI 能产出东西。** `nvchecker-old.json` 的基线已是最新版，
`--outdated` 会报「全部已是最新」，而 R2 是空的 —— 结果是个空仓库。

正确做法是**先在本地准备好完整的已签名仓库，一次性传上去**，之后 CI 只做增量。
本地仓库已经建好了（`/var/cache/pkgrepo`，11 个包全部签名），直接上传：

```fish
rclone sync /var/cache/pkgrepo r2:<bucket>/archlinux/x86_64 --progress
```

本机 rclone 的配置（`~/.config/rclone/rclone.conf`）：

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <R2 Access Key ID>
secret_access_key = <R2 Secret>
endpoint = https://<账号ID>.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
```

传完之后 CI 的「拉取 R2 上已有的仓库」那一步就能拿到完整仓库，后续增量构建正常工作。

## 5. 桌面端切换

```bash
# 导入并本地签信你的公钥
sudo pacman-key --add /tmp/pubkey.asc
sudo pacman-key --lsign-key CEFA64B7B1308F2ECB404D423D02D08ED532F9C7
```

`/etc/pacman.conf` 里把 `[nekolsd]` 段改成：

```ini
[nekolsd]
SigLevel = Required DatabaseRequired
Server = https://repo.lsd.moe/archlinux/$arch
```

`archlinux/` 这层前缀对应 R2 里的对象路径 `<bucket>/archlinux/x86_64/`。
域名是通用的 `repo.`，留这层前缀方便将来在同一个 bucket 下放别的东西。

`Required DatabaseRequired` 要求包和数据库都必须有可信签名。这是走网络后的必要配置——
本地 `file://` 时代那套 `Optional TrustAll` 在网络上等于门户大开：任何能劫持连接的人
都能塞给你任意包，而 pacman 会以 root 装上它。

改完 `sudo pacman -Syu` 验证。若报签名错误，先确认 `pacman-key --lsign-key` 做过。

## 6. 本地仓库何去何从

切到 R2 之后 `/var/cache/pkgrepo` 就是冗余的，可以删。但建议保留本地构建能力
（`build.sh` 不带 `BUILD_BACKEND` 就是 chroot 模式）——CI 挂了或者你要临时打个补丁版本时用得上。

## 注意事项

- **子钥 2027-08-08 到期**：到期前用 `gpg --quick-add-key` 换新子钥并更新 `GPG_SIGNING_KEY`/`GPG_KEY_ID`，否则 CI 签名失败
- **`--aur-diff` 更重要了**：PKGBUILD 里的代码现在会在 GitHub 的机器上执行。
  从 AUR 合并任何改动前务必人工审阅
- **并发保护**：workflow 里设了 `concurrency`，避免两个 job 同时改 R2 上的数据库
- **上传顺序**：先传包体、后传数据库，中途失败时索引仍指向旧版本（文件都还在），
  不会出现「索引说有、文件却没上传」的窗口

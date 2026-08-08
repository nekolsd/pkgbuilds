#!/usr/bin/env bash
# 本地打包流水线：bump 版本 → 干净 chroot 构建 → 收进本地仓库
#
#   ./build.sh <包名> [新版本]    构建单个包；给了新版本则先 bump 再构建
#   ./build.sh --outdated         按 nvchecker 结果，构建所有落后的包
#   ./build.sh --check            只跑 nvchecker，列出落后的包
#   ./build.sh --aur-diff [包名]  对比本地配方与 AUR 上游（只读）
#   ./build.sh --clean-src [包名] 清掉下载的上游源与构建残留
#   ./build.sh --aur-check        列出上游配方有实质变化的包名
#   ./build.sh --aur-apply <包名> 合并上游配方改动到工作区，PR 正文打到 stdout
set -euo pipefail

# 构建产物仓库。放在 git 检出之外（免得 git clean -xdf 连包带库删光），
# 且路径纯 ASCII——pacman.conf 的 Server 是 URL，非 ASCII 路径要不要百分号编码
# 存在歧义，直接规避。目录归当前用户所有，故构建入库全程不需要 root。
REPO_DIR="${REPO_DIR:-/var/cache/pkgrepo}"

# 构建后端：
#   chroot  本机默认。devtools 干净 chroot，隔离最强。
#   makepkg CI 用。GitHub Actions 的 runner 本身就是一次性容器，
#           每个 job 都是全新环境，再套一层 chroot 需要 privileged，
#           收益为零、复杂度不小。
BUILD_BACKEND="${BUILD_BACKEND:-chroot}"

# 设了就对包和仓库数据库做 GPG 签名。本地 file:// 仓库可以不签
# （没有中间人），但走网络分发必须签——否则任何能劫持连接的人
# 都能塞给你任意包，而 pacman 会以 root 装上它。
SIGN_KEY="${SIGN_KEY:-}"
REPO_NAME="${REPO_NAME:-nekolsd}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# 打印开头的注释块直到第一行非注释——加了新子命令不用回来改行号
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 1; }

# 把 PKGBUILD 里的版本号改成 $2，并把 pkgrel 归 1
bump_version() {
  local d=$1 v=$2 var
  if grep -q '^pkgver=\$' "$d/PKGBUILD"; then
    # pkgver 由下划线变量派生（如 1password 的 _tarver），要改的是源头
    var=$(grep -oP '^pkgver=\$\{?\K_[a-zA-Z_]+' "$d/PKGBUILD") \
      || die "$(basename "$d"): pkgver 是派生的但找不到源变量，请手动编辑 PKGBUILD"
    sed -i -E "s|^${var}=.*|${var}=${v}|" "$d/PKGBUILD"
    info "已改 \$${var} = ${v}"
  else
    # 兼容 pkgver=1.2.3 / pkgver='1.2.3' / pkgver="1.2.3"
    sed -i -E "s|^pkgver=.*|pkgver=${v}|" "$d/PKGBUILD"
  fi
  sed -i -E "s|^pkgrel=.*|pkgrel=1|" "$d/PKGBUILD"
}

# 确保 PKGBUILD 声明的上游签名密钥在本地钥匙串里，否则 chroot 内校验会失败
ensure_pgp_keys() {
  local d=$1 keys=() k
  mapfile -t keys < <(cd "$d" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1
                      printf '%s\n' "${validpgpkeys[@]:-}")
  for k in "${keys[@]}"; do
    [ -z "$k" ] && continue
    if ! gpg --list-keys "$k" &>/dev/null; then
      info "导入上游签名密钥 $k"
      gpg --recv-keys "$k" || warn "密钥 $k 导入失败，构建时签名校验可能不过"
    fi
  done
}

# ── 关于下面两个函数的共同前提 ────────────────────────────────────
# 二者都只读、都绝不自动合并。从 AUR 拉来的任何改动都是要被执行的代码
# （PKGBUILD 会以构建用户身份运行），这正是 2026 年那几轮投毒的传播方式。
# 是否采纳必须由人看过 diff 之后决定。
#
# 判断某个包的上游配方是否有「非版本号/校验和」的实质变化。
# 有返回 0，无返回 1。$2 是已 clone 好的上游目录。
has_drift() {
  local p=$1 up=$2 out
  out=$(diff -u "$ROOT/$p/PKGBUILD" "$up/PKGBUILD" 2>/dev/null \
    | grep -vE "^[+-](pkgver|pkgrel|_tarver|_pkgver[a-zA-Z_]*|_x86_md5|_arm_md5)=" \
    | grep -vE "^[+-](sha256sums|sha512sums|sha1sums|md5sums|b2sums)" \
    | grep -vE "^[+-][[:space:]]*'[0-9a-fA-F]{32,128}'\)?$" \
    | grep -vE '^(---|\+\+\+|@@)' | grep -E '^[+-]' || true)
  [ -n "$out" ]
}

# 列出上游配方有实质变化的包名，一行一个——供 CI 决定给哪些包开 PR。
aur_check() {
  local tmp p
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  for p in $(cd "$ROOT" && for x in */; do [ -f "${x}PKGBUILD" ] && echo "${x%/}"; done); do
    git clone -q --depth 1 "https://aur.archlinux.org/$p.git" "$tmp/$p" 2>/dev/null || continue
    has_drift "$p" "$tmp/$p" && echo "$p"
  done
  return 0
}

# 把上游的配方逻辑合并进来，供 CI 建分支开 PR。
#
# 不能直接用上游的 PKGBUILD：AUR 冻在旧版本，整份覆盖会把版本号回退。
# 规则是「上游的配方 + 我们的 pkgver + pkgrel 加一」——配方变了而版本没变时
# 必须递增 pkgrel，否则 pacman 不认为这是更新的包，装不上去。
# 校验和最后用 updpkgsums 重新生成：上游若改了 source 数组，旧校验和就对不上了。
#
# 改动写进工作区，PR 正文打到 stdout。合并与否由人决定——这是唯一的审查关口。
aur_apply() {
  local p=$1 tmp cur rel
  [ -f "$ROOT/$p/PKGBUILD" ] || die "本地没有这个包: $p"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  git clone -q --depth 20 "https://aur.archlinux.org/$p.git" "$tmp/up" 2>/dev/null \
    || die "$p: 拉取 AUR 失败"

  cur=$(cd "$ROOT/$p" && CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1; echo "$pkgver")
  rel=$(grep -m1 '^pkgrel=' "$ROOT/$p/PKGBUILD" | cut -d= -f2 | tr -d "'\"")

  cp "$tmp/up/PKGBUILD" "$ROOT/$p/PKGBUILD"
  bump_version "$ROOT/$p" "$cur"                       # 版本号改回我们的（顺带把 pkgrel 置 1）
  sed -i -E "s|^pkgrel=.*|pkgrel=$((rel + 1))|" "$ROOT/$p/PKGBUILD"

  ( cd "$ROOT/$p" && updpkgsums ) >/dev/null 2>&1 \
    || warn "$p: 校验和重算失败，合并前需人工处理"

  # PR 正文
  cat <<EOF
上游 AUR 的配方有非版本号的改动，已合并进本分支供审阅。

- 版本号保持 \`$cur\` 不变（AUR 冻结在更旧的版本，整份覆盖会导致回退）
- \`pkgrel\` 由 $rel 递增为 $((rel + 1))：配方变了而版本未变，需要递增才能被 pacman 视为更新
- 校验和已重新生成

## AUR 最近提交

\`\`\`
$(git -C "$tmp/up" log -10 --date=short --format='%ad  %an <%ae>  %s')
\`\`\`

---

⚠️ **PKGBUILD 是会被执行的代码**，合并等于同意它在构建机上以构建用户身份运行。
请逐行审阅 diff，重点看 \`source\`、\`prepare/build/package\` 函数、\`install\` 脚本。
EOF
}

# aur_diff: 直接打到终端，供人随手查看。有漂移时返回 1。
aur_diff() {
  local pkgs=("$@") p tmp d_out drift=0
  if [ ${#pkgs[@]} -eq 0 ]; then
    mapfile -t pkgs < <(cd "$ROOT" && for x in */; do [ -f "${x}PKGBUILD" ] && echo "${x%/}"; done)
  fi
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

  for p in "${pkgs[@]}"; do
    [ -f "$ROOT/$p/PKGBUILD" ] || { warn "$p: 本地没有这个包"; continue; }
    if ! git clone -q --depth 1 "https://aur.archlinux.org/$p.git" "$tmp/$p" 2>/dev/null; then
      printf '  %-26s \033[33mAUR 上没有或拉取失败\033[0m\n' "$p"; continue
    fi

    # 滤掉版本号与校验和的差异：我们主动升级过，本地领先于冻结的 AUR 属正常，
    # 真正要看的是配方逻辑（依赖、构建步骤、安装脚本、源地址）有没有变。
    d_out=$(diff -u "$ROOT/$p/PKGBUILD" "$tmp/$p/PKGBUILD" 2>/dev/null \
      | grep -vE "^[+-](pkgver|pkgrel|_tarver|_pkgver[a-zA-Z_]*|_x86_md5|_arm_md5)=" \
      | grep -vE "^[+-](sha256sums|sha512sums|sha1sums|md5sums|b2sums)" \
      | grep -vE "^[+-][[:space:]]*'[0-9a-fA-F]{32,128}'\)?$" \
      | grep -vE '^(---|\+\+\+|@@)' | grep -E '^[+-]' || true)

    if [ -z "$d_out" ]; then
      printf '  %-26s \033[32m配方无实质变化\033[0m\n' "$p"
    else
      drift=1
      printf '  %-26s \033[1;33m上游有改动 ↓\033[0m\n' "$p"
      # 同上：diff 返回 1 表示有差异，pipefail 下必须兜住，否则函数直接被 set -e 终止
      # （曾导致 --aur-diff 打完 diff 就退出，后面的 AUR 提交记录从未输出过）
      diff -u --color=always "$ROOT/$p/PKGBUILD" "$tmp/$p/PKGBUILD" | tail -n +3 | sed 's/^/      /' || true
      echo "      ── AUR 最近提交 ──"
      git -C "$tmp/$p" log -3 --date=short --format='      %ad  %an  %s'
      echo
    fi
  done
  return $drift
}

# 清掉各包目录里下载来的上游源与构建残留。
# 刻意不用 git clean：那样只能靠 .gitignore 的模式匹配猜哪些是下载物
# （claude-code 的二进制叫 claude-2.1.226-x86_64，不带扩展名，任何模式都难覆盖）。
# 这里改为解析每个 PKGBUILD 的 source 数组，只删它自己声明过的下载项——
# 你手工放进包目录的任何东西都不会被碰。
clean_src() {
  local pkgs=("$@") p d f s arch freed=0 sz
  if [ ${#pkgs[@]} -eq 0 ]; then
    mapfile -t pkgs < <(cd "$ROOT" && for x in */; do [ -f "${x}PKGBUILD" ] && echo "${x%/}"; done)
  fi

  for p in "${pkgs[@]}"; do
    d="$ROOT/$p"; [ -f "$d/PKGBUILD" ] || continue
    local -a targets=()

    # 逐个架构解析，把所有 source_* 数组里的「下载项」换算成本地文件名
    for arch in x86_64 aarch64 armv7h i686; do
      mapfile -t -O "${#targets[@]}" targets < <(
        cd "$d" && CARCH=$arch
        source ./PKGBUILD >/dev/null 2>&1 || exit 0
        for s in "${source[@]:-}" "${source_x86_64[@]:-}" "${source_aarch64[@]:-}" \
                 "${source_armv7h[@]:-}" "${source_i686[@]:-}"; do
          [ -z "$s" ] && continue
          case "$s" in *://*) ;; *) continue ;; esac      # 本地文件不动
          if [[ $s == *::* ]]; then echo "${s%%::*}"; else echo "${s##*/}"; fi
        done)
    done

    sz=0
    for f in $(printf '%s\n' "${targets[@]:-}" | sort -u); do
      [ -n "$f" ] && [ -f "$d/$f" ] || continue
      sz=$(( sz + $(stat -c%s "$d/$f") ))
      rm -f "$d/$f" "$d/$f.part"
    done
    # makepkg 的工作目录与日志
    for extra in "$d"/src "$d"/pkg; do
      [ -d "$extra" ] && { sz=$(( sz + $(du -sb "$extra" | cut -f1) )); rm -rf "$extra"; }
    done
    rm -f "$d"/*.log

    if [ "$sz" -gt 0 ]; then
      # 用 awk 而非 bc 做浮点格式化：bc 不是基础系统的一部分，不能假定存在
      awk -v p="$p" -v n="$sz" 'BEGIN{printf "  %-26s 释放 %7.1f MB\n", p, n/1048576}'
      freed=$(( freed + sz ))
    fi
  done
  awk -v n="$freed" 'BEGIN{printf "\n\033[1;36m==>\033[0m 合计释放 %.2f GB\n", n/1073741824}'
}

build_one() {
  # 必须分行写：bash 会先展开 local 的全部参数再执行它，
  # 写成一行的话 "$ROOT/$pkg" 里的 $pkg 尚未赋值，set -u 会判其未绑定
  local pkg=$1
  local newver=${2:-}
  local d="$ROOT/$pkg"

  # 先于一切检查：往已签名的仓库做不签名的构建，会让数据库签名悄悄失效
  # ——repo-add 重写数据库而 .sig 停在旧内容上，直到某次带 -v 的操作才暴露。
  # 必须在构建之前拦，否则要白跑一整轮下载和编译才失败。
  if [ -z "$SIGN_KEY" ] && [ -f "$REPO_DIR/$REPO_NAME.db.tar.zst.sig" ]; then
    die "$pkg: 仓库 $REPO_DIR 已签名，但本次构建未设 SIGN_KEY。
     继续会使数据库签名失效。要么设置 SIGN_KEY=<密钥ID>，
     要么先删掉 $REPO_NAME.db.tar.zst.sig 明确放弃签名。"
  fi
  [ -d "$d" ] || die "仓库里没有这个包: $pkg"
  cd "$d"

  # 注意：下面每一步都显式写 `|| die`，不能依赖 set -e。
  # --outdated 里用 `if ( build_one ... )` 做失败隔离，而 bash 把复合命令放进
  # if 条件时会在整段内禁用 errexit —— 曾导致 updpkgsums 失败后仍继续构建，
  # 拿新版本号配旧校验和跑到完整性校验才炸。
  if [ -n "$newver" ]; then
    local cur
    cur=$(CARCH=x86_64; source ./PKGBUILD >/dev/null 2>&1; echo "$pkgver")
    info "$pkg: $cur → $newver"
    bump_version "$d" "$newver" || die "$pkg: 改版本号失败"
    info "重算校验和（从上游厂商源重新下载）..."
    if ! updpkgsums; then
      # 版本号已改但校验和没更新，PKGBUILD 处于危险的不一致状态，回滚掉
      git -C "$ROOT" checkout -- "$pkg/PKGBUILD"
      die "$pkg: 上游源下载失败，校验和没能更新；已回滚 PKGBUILD"
    fi
  fi

  ensure_pgp_keys "$d"

  local mkpkg_args=()
  [ -n "$SIGN_KEY" ] && mkpkg_args+=(--sign --key "$SIGN_KEY")

  if [ "$BUILD_BACKEND" = makepkg ]; then
    # CI 路径：容器即隔离环境。--nocheck 不加，checkdepends 该跑还是跑。
    info "$pkg: 用 makepkg 构建（后端=makepkg）..."
    makepkg --syncdeps --noconfirm --needed --clean "${mkpkg_args[@]}" \
      || die "$pkg: makepkg 构建失败"
  else
    # 关于 -c：archbuild 把 makechrootpkg_args=(-c -n -C) 写死了，所以无论这里传不传 -c，
    # 每个包的工作副本都会从底座重新同步——隔离性始终有保证，依赖也始终是干净重装的。
    # extra-x86_64-build 自己的 -c 只决定「底座 chroot 是否整个 pacstrap 重建」，
    # 那要重下近 1G 的 base+base-devel。默认不传，让底座走 pacman -Syu 增量更新即可。
    # CLEAN_CHROOT=1 用于底座本身被搞坏、需要推倒重来时。
    if [ -n "${CLEAN_CHROOT:-}" ]; then
      info "$pkg: 重建底座 chroot 后构建..."
      extra-x86_64-build -c || die "$pkg: chroot 构建失败"
    else
      info "$pkg: 在 chroot 中构建..."
      extra-x86_64-build || die "$pkg: chroot 构建失败"
    fi
    # chroot 构建产出的包不带签名，补签
    if [ -n "$SIGN_KEY" ]; then
      shopt -s nullglob
      for f in *.pkg.tar.zst; do
        gpg --detach-sign --use-agent --no-armor -u "$SIGN_KEY" --yes "$f" \
          || die "$pkg: 签名失败"
      done
      shopt -u nullglob
    fi
  fi

  shopt -s nullglob
  local built=(*.pkg.tar.zst)
  shopt -u nullglob
  [ ${#built[@]} -gt 0 ] || die "$pkg: 没有产出任何包"

  mkdir -p "$REPO_DIR"
  local moved=()
  for f in "${built[@]}"; do
    mv -f "$f" "$REPO_DIR/"
    [ -f "$f.sig" ] && mv -f "$f.sig" "$REPO_DIR/"
    moved+=("$REPO_DIR/$(basename "$f")")
  done

  local repoadd_args=(-R)
  # -s 顺带签名数据库本身；-v 校验既有签名（能发现数据库被改过却没重签）
  [ -n "$SIGN_KEY" ] && repoadd_args+=(-s -v -k "$SIGN_KEY")
  repo-add "${repoadd_args[@]}" "$REPO_DIR/$REPO_NAME.db.tar.zst" "${moved[@]}"
  info "$pkg: 已入库 → ${moved[*]##*/}"

  if [ -n "$newver" ]; then
    git -C "$ROOT" add "$pkg/PKGBUILD"
    git -C "$ROOT" commit -qm "$pkg: 升级到 $newver" && info "已提交配方变更"
  fi
}

case "${1:-}" in
  ''|-h|--help) usage ;;

  --check)
    cd "$ROOT" && nvchecker -c nvchecker.toml >/dev/null 2>&1
    nvcmp -c nvchecker.toml
    ;;

  --aur-diff)
    shift
    info "对比本地配方与 AUR 上游（只读，不会自动改动任何文件）"
    aur_diff "$@"
    ;;

  --aur-check)
    aur_check
    ;;

  --aur-apply)
    shift
    [ $# -eq 1 ] || die "用法: $0 --aur-apply <包名>"
    aur_apply "$1"
    ;;

  --clean-src)
    shift
    info "清理已下载的上游源与构建残留（可按 PKGBUILD 重新下载，删除无风险）"
    clean_src "$@"
    ;;

  --outdated)
    cd "$ROOT"
    nvchecker -c nvchecker.toml >/dev/null 2>&1
    mapfile -t rows < <(nvcmp -c nvchecker.toml)
    [ ${#rows[@]} -gt 0 ] || { info "全部已是最新"; exit 0; }
    info "待构建 ${#rows[@]} 个："; printf '    %s\n' "${rows[@]}"

    ok=(); failed=()
    for row in "${rows[@]}"; do
      # nvcmp 输出形如: 包名 旧版本 -> 新版本
      p=$(awk '{print $1}' <<<"$row"); v=$(awk '{print $NF}' <<<"$row")
      # 放进子 shell：某个包挂掉不会因 set -e 带走后面还没构建的包
      if ( build_one "$p" "$v" ); then ok+=("$p"); else failed+=("$p"); warn "$p 构建失败，跳过"; fi
    done

    # 只为构建成功的包推进版本基线，失败的下次 --check 仍会被列出来
    if [ ${#ok[@]} -gt 0 ]; then
      python3 - "${ok[@]}" <<'PY'
import json, sys
done = set(sys.argv[1:])
new = json.load(open('nvchecker-new.json'))['data']
old = json.load(open('nvchecker-old.json'))
for k in done:
    if k in new: old['data'][k] = new[k]
json.dump(old, open('nvchecker-old.json', 'w'), indent=2, ensure_ascii=False)
PY
      git add nvchecker-old.json && git commit -qm "推进版本基线: ${ok[*]}" || true
    fi

    echo
    info "成功 ${#ok[@]} 个: ${ok[*]:-无}"
    # 必须写成 if，不能用 `[ cond ] && warn`：那是本分支的最后一条语句，
    # 它的退出码就是整个脚本的退出码——没有失败时 [ 0 -gt 0 ] 返回 1，
    # 成功/失败信号会完全颠倒（CI 里表现为构建全成功却报 exit code 1）。
    if [ ${#failed[@]} -gt 0 ]; then
      warn "失败 ${#failed[@]} 个: ${failed[*]}"
      exit 1
    fi
    ;;

  *) build_one "$1" "${2:-}" ;;
esac

#!/bin/bash
# moonbit 工作区开发工具链的唯一源。
#
# 把 static/ 与 templates/ 生成到各项目仓库里,并留下校验戳记;各项目只维护自己的
# scripts/devkit.conf(业务声明)。任何生成物被手改,都会被 pre-commit 与 CI 拦下。
#
# 在 WSL 内执行:
#   bash /mnt/c/codes/moonbit/scripts/devkit.sh list
#   bash /mnt/c/codes/moonbit/scripts/devkit.sh init  <项目>
#   bash /mnt/c/codes/moonbit/scripts/devkit.sh sync  [项目...]
#   bash /mnt/c/codes/moonbit/scripts/devkit.sh check [项目...]
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE=$(cd "$SRC/.." && pwd)
CI_PATH=".github/workflows/verify.yml"

# shellcheck source=/dev/null
source "$SRC/devkit.conf"

usage() {
  echo "usage: devkit.sh {list|init <项目>|sync [项目...]|check [项目...]|audit [项目...]}" >&2
  exit 2
}

# 工作区里所有项目(git 仓库),排除唯一源自身。
projects() {
  local d
  for d in "$WORKSPACE"/*/; do
    [ -d "$d/.git" ] || continue
    [ "$(cd "$d" && pwd)" = "$SRC" ] && continue
    basename "$d"
  done
}

# 参数为空则全体,否则用给定列表。
resolve_projects() {
  if [ "$#" -eq 0 ]; then
    projects
  else
    printf '%s\n' "$@"
  fi
}

# 生成物清单(相对项目根),sync 与 manifest 共用。
generated_files() {
  (cd "$SRC/static" && find . -type f | sed 's#^\./##')
  printf '%s\n' "$CI_PATH"
}

# 源树内容哈希:各项目戳记里记它,check 用来判断谁落后于源。
source_revision() {
  (cd "$SRC" && find static templates -type f | sort |
    while IFS= read -r f; do sha256sum "$f"; done) | sha256sum | cut -d' ' -f1
}

# 模板渲染 CI:替换工具链版本,注入项目自己的 setup 片段(可选)。
render_ci() {
  local project="$1" out="$project/$CI_PATH" setup="" line
  mkdir -p "$(dirname "$out")"
  [ -f "$project/scripts/ci-setup.yml" ] && setup=$(cat "$project/scripts/ci-setup.yml")
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//\{\{MOONC_VERSION\}\}/$MOONC_VERSION}
    if [[ "$line" == *'{{PROJECT_SETUP}}'* ]]; then
      printf '%s\n' "$setup" >> "$out"
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$SRC/templates/verify.yml"
}

sync_project() {
  local name="$1" revision="$2"
  local project="$WORKSPACE/$name" rel
  if [ ! -d "$project/.git" ]; then
    echo "devkit: 跳过 '$name':不是 git 仓库" >&2
    return 1
  fi

  # 1) 逐字节复制 static/(保留可执行位)。
  while IFS= read -r rel; do
    mkdir -p "$(dirname "$project/$rel")"
    cp -f "$SRC/static/$rel" "$project/$rel"
    [ -x "$SRC/static/$rel" ] && chmod +x "$project/$rel"
  done < <(cd "$SRC/static" && find . -type f | sed 's#^\./##')

  # 2) 渲染 CI。
  render_ci "$project"

  # 3) 写戳记:.manifest 供 sha256sum -c,.manifest.rev 记源版本。
  mkdir -p "$project/scripts/devkit"
  : > "$project/scripts/devkit/.manifest"
  while IFS= read -r rel; do
    printf '%s  %s\n' "$(sha256sum "$project/$rel" | cut -d' ' -f1)" "$rel"
  done < <(generated_files | sort) >> "$project/scripts/devkit/.manifest"
  printf 'revision=%s\ngenerated=%s\n' "$revision" "$(date -Iseconds)" \
    > "$project/scripts/devkit/.manifest.rev"

  echo "devkit: synced $name (revision ${revision:0:12})"
}

init_project() {
  local name="$1"
  local project="$WORKSPACE/$name"
  local conf="$project/scripts/devkit.conf"
  if [ ! -d "$project/.git" ]; then
    echo "devkit: '$name' 不是 git 仓库" >&2
    return 1
  fi
  # 项目清单只在缺失时种一次,之后归项目所有,sync 不碰。
  if [ ! -f "$conf" ]; then
    mkdir -p "$project/scripts"
    sed "s/__PROJECT__/$name/g" "$SRC/templates/devkit.conf" > "$conf"
    echo "devkit: seeded $conf(请补全业务事实)"
  else
    echo "devkit: $conf 已存在,保留不动"
  fi
  sync_project "$name" "$(source_revision)"
  echo "devkit: 激活钩子(每仓库一次):git -C $project config core.hooksPath .githooks"
}

check_project() {
  local name="$1" want="$2"
  local project="$WORKSPACE/$name"
  local got bad=0 out
  if [ ! -d "$project/.git" ]; then
    echo "devkit: 跳过 '$name':不是 git 仓库" >&2
    return 0
  fi
  if [ ! -f "$project/scripts/devkit/.manifest" ]; then
    echo "devkit: $name 未接入(缺 scripts/devkit/.manifest)"
    return 1
  fi
  if ! out=$(cd "$project" && LC_ALL=C sha256sum -c --quiet scripts/devkit/.manifest 2>&1); then
    echo "devkit: $name 的生成物与源不一致(被手改?):"
    printf '%s\n' "$out"
    bad=1
  fi
  got=$(sed -nE 's/^revision=(.*)$/\1/p' "$project/scripts/devkit/.manifest.rev" 2>/dev/null || true)
  if [ "$got" != "$want" ]; then
    echo "devkit: $name 落后于源(revision ${got:0:12} != ${want:0:12});请跑 sync"
    bad=1
  fi
  [ "$bad" = 0 ] && echo "devkit: $name ok"
  return "$bad"
}

# 就绪审计:「检查 xxx 项目」的机检部分。只核仓库侧(离线、不碰 CF/GitHub);
# 云端四项(线上仓库、Pages 配置、DNS、实站 200)由手工清单核,见第八节。
# 缺失者逐条列出,全部通过返回 0,否则返回 1。
audit_project() {
  local name="$1"
  local path="$WORKSPACE/$name" fail=0 got want key url branch hooks_path portal=0
  audit_ok() { echo "  ok    $1"; }
  audit_miss() { echo "  MISS  $1"; fail=$((fail + 1)); }

  echo "== $name =="

  # devkit 接入与生成物。
  if [ ! -f "$path/scripts/devkit/.manifest" ]; then
    audit_miss "devkit 接入(scripts/devkit/.manifest 不存在;先跑 devkit.sh init)"
    echo "== $name:以上为全部可机检项,云端手检见第八节 =="
    return 1
  fi
  if (cd "$path" && LC_ALL=C sha256sum -c --quiet scripts/devkit/.manifest) > /dev/null 2>&1; then
    audit_ok "devkit 生成物与源逐字节一致"
  else
    audit_miss "devkit 生成物与源一致(有人手改或过期;跑 devkit.sh sync)"
  fi
  got=$(sed -nE 's/^revision=(.*)$/\1/p' "$path/scripts/devkit/.manifest.rev" 2>/dev/null)
  want=$(source_revision)
  [ "$got" = "$want" ] && audit_ok "devkit 与唯一源同 revision"
  [ "$got" = "$want" ] || audit_miss "devkit 落后于唯一源(跑 devkit.sh sync)"

  # git 形态:钩子、远端、分支。门户例外:远端是域名仓库(chenbimo/moonbitlang.dev.git),
  # 由 origin 识别,不依赖目录名。
  hooks_path=$(git -C "$path" config --get core.hooksPath)
  if [ "$hooks_path" = ".githooks" ]; then
    audit_ok "core.hooksPath = .githooks"
  else
    audit_miss "core.hooksPath 应为 .githooks(现:${hooks_path:-未设})"
  fi
  url=$(git -C "$path" remote get-url origin 2>/dev/null)
  local expected_url="git@github.com:chenbimo/$name.git"
  if [ "$url" = "git@github.com:chenbimo/moonbitlang.dev.git" ]; then
    expected_url="$url"
    portal=1
  fi
  if [ "$url" = "$expected_url" ]; then
    audit_ok "origin 指向 ${expected_url#git@github.com:}(SSH)"
  else
    audit_miss "origin 应为 $expected_url(现:${url:-未设})"
  fi
  branch=$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null)
  if [ "$branch" = "main" ]; then
    audit_ok "分支 = main"
  else
    audit_miss "分支应为 main(现:${branch:-无})"
  fi

  # 项目身份:moon.mod 齐全且名称对齐(门户没有 moon.mod,跳过这一组)。
  if [ "$portal" = 0 ]; then
    if [ -f "$path/moon.mod" ]; then
      audit_ok "moon.mod 存在"
      for key in version license description repository readme; do
        grep -qE "^$key = " "$path/moon.mod" || audit_miss "moon.mod 缺字段:$key"
      done
      grep -qE "^name = \"chensuiyi/$name\"" "$path/moon.mod" &&
        audit_ok "模块名 = chensuiyi/$name" ||
        audit_miss "moon.mod 的 name 应为 chensuiyi/$name"
      grep -q "chenbimo/$name" "$path/moon.mod" &&
        audit_ok "repository 指向 chenbimo/$name" ||
        audit_miss "moon.mod 的 repository 未指向 chenbimo/$name"

      # 版本形态与发布对齐(第九节:大版本必须显式口令)。
      ver=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$path/moon.mod")
      if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        audit_ok "版本号形态语义化($ver)"
      else
        audit_miss "版本号应为 大版本.中版本.小版本 三段数字(现:${ver:-未设})"
      fi
      max_tag=$(git -C "$path" tag --list 'v*' | sort -V | tail -1)
      if [ -z "$max_tag" ]; then
        audit_ok "尚无发布 tag(有版本未发布时,发布按第九节打 tag)"
      else
        mt=${max_tag#v}
        if [ "$ver" = "$mt" ]; then
          audit_ok "版本与发布 tag 一致($max_tag)"
        elif [ "$(printf '%s\n' "$ver" "$mt" | sort -V | head -1)" = "$ver" ]; then
          audit_miss "moon.mod 版本($ver)低于最新发布 tag($max_tag):版本回退不应发生"
        else
          audit_ok "版本 $ver 已 bump,发布 tag 为 $max_tag(发布时打 tag)"
        fi
      fi
    else
      audit_miss "moon.mod 未建立(先按 NEW-PROJECT.md 第二节立骨架)"
    fi
    [ -f "$path/README.md" ] && audit_ok "README.md 存在" ||
      audit_miss "README.md 未建立"
    [ -f "$path/LICENSE" ] && audit_ok "LICENSE 存在" ||
      audit_miss "LICENSE 未建立"
  fi

  # 项目清单(声明)与事实对齐。
  if [ -f "$path/scripts/devkit.conf" ]; then
    # shellcheck source=/dev/null
    source "$path/scripts/devkit.conf"
    [ "${DEVKIT_NAME:-}" = "$([ "$portal" = 1 ] && echo site || echo "$name")" ] &&
      audit_ok "DEVKIT_NAME 与项目对齐" ||
      audit_miss "DEVKIT_NAME 应为 $([ "$portal" = 1 ] && echo site || echo "$name")"
    if [ -f "$path/moon.mod" ] && [ "${fail:-0}" -lt 20 ]; then
      mn=$(sed -nE 's/^name = "([^"]+)"/\1/p' "$path/moon.mod")
      [ "${DEVKIT_MODULE:-}" = "$mn" ] && audit_ok "DEVKIT_MODULE 与 moon.mod 对齐" ||
        audit_miss "DEVKIT_MODULE 应为 $mn(现:${DEVKIT_MODULE:-空})"
    fi
  else
    audit_miss "scripts/devkit.conf 缺失(先跑 devkit.sh init)"
  fi

  # 文档站组:门户自身免检(它就是那个站);其余模块除非已建 docs/,否则记缺失。
  if [ "$portal" = 1 ]; then
    audit_ok "门户形态:站点即仓库,免 docs/ 组"
    if [ -f "$path/index.html" ] && grep -aqE '(src|href)="/' "$path/index.html"; then
      audit_miss "index.html 存在以 / 开头的引用(资源与站内跳转应为相对路径)"
    else
      audit_ok "index.html 引用均为相对路径或外链"
    fi
  elif [ -f "$path/docs/package.json" ]; then
    audit_ok "docs/ 文档站存在"
    grep -q "base: '/'" "$path/docs/.vitepress/config.js" &&
      audit_ok "base 为根路径 '/'" ||
      audit_miss "docs/.vitepress/config.js 的 base 未设 '/'"
    if git -C "$path" ls-files --error-unmatch docs/bun.lock > /dev/null 2>&1; then
      audit_ok "docs/bun.lock 已跟踪"
    else
      audit_miss "docs/bun.lock 未提交(frozen-lockfile 在 CI 会失败)"
    fi
    if [ -f "$path/.gitignore" ] && grep -qE "docs/node_modules" "$path/.gitignore"; then
      audit_ok ".gitignore 含文档站产物三件"
    else
      audit_miss ".gitignore 缺 docs/node_modules、.vitepress/cache、dist 三项"
    fi
    if [ -f "$path/AGENTS.md" ] && grep -q "moonbit-$name" "$path/AGENTS.md"; then
      audit_ok "AGENTS.md 记录了 Pages 项目 moonbit-$name"
    else
      audit_miss "AGENTS.md 未记录 Pages 项目与部署形态(应含 moonbit-$name 并指向 NEW-PROJECT.md)"
    fi
    # 卡片数据(main.js)必须提及该模块:有 docs 站给 docs 链接,否则至少有 repo 链接。
    portal_main="$WORKSPACE/site/main.js"
    if [ -f "$portal_main" ] &&
      grep -qE "$name\\.moonbitlang\\.dev|github\\.com/chenbimo/$name" "$portal_main"; then
      audit_ok "门户卡片已列出该模块"
    else
      audit_miss "门户 main.js 尚未列出 $name(repo 或 docs 链接至少其一)"
    fi
  else
    audit_miss "docs/ 文档站未建(无方向的项目先定方向再上站,见第八节)"
  fi

  # 敏感与忽略:本地态目录、令牌与私钥不得入库(标准拒收块见 NEW-PROJECT.md 第八节)。
  gi_hits=$(grep -cE '^\.cloudflare/$|^\.env' "$path/.gitignore" 2> /dev/null) || gi_hits=0
  [ -n "$gi_hits" ] || gi_hits=0
  if [ -f "$path/.gitignore" ] && [ "$gi_hits" -ge 2 ]; then
    audit_ok ".gitignore 含敏感拒收块"
  else
    audit_miss ".gitignore 缺敏感拒收块(.cloudflare/.env/*.key/*.pem/.wrangler;按第八节补)"
  fi
  local suspicious
  suspicious=$(git -C "$path" ls-files 2>/dev/null |
    grep -aiE "(^|/)\.env([./]|$)|\.pem$|\.key$|(^|/)credentials($|[/.])|(^|/)secrets?\.(json|ya?ml|txt)$" |
    tr '\n' ' ')
  if [ -n "$suspicious" ]; then
    audit_miss "跟踪了疑似敏感文件:$suspicious"
  else
    audit_ok "未跟踪疑似敏感文件"
  fi
  local leak_scan
  leak_scan=$(git -C "$path" grep -aiE \
    "BEGIN [A-Z ]*PRIVATE KEY|CLOUDFLARE_API_TOKEN|CF_API_TOKEN|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}" \
    HEAD -- . 2>/dev/null | head -5 | tr '\n' ' ')
  if [ -n "$leak_scan" ]; then
    audit_miss "HEAD 提交内容命中敏感签名:$leak_scan"
  else
    audit_ok "HEAD 无令牌/私钥/云厂商密钥签名"
  fi

  if [ "$fail" = 0 ]; then
    echo "== $name:仓库侧全部就绪 =="
    return 0
  fi
  echo "== $name:$fail 项缺失(云端四项另按第八节手检) =="
  return 1
}

case "${1:-}" in
  list)
    projects
    ;;
  init)
    [ "$#" -eq 2 ] || usage
    init_project "$2"
    ;;
  sync)
    shift || true
    rev=$(source_revision)
    for p in $(resolve_projects "$@"); do sync_project "$p" "$rev"; done
    ;;
  check)
    shift || true
    rev=$(source_revision)
    rc=0
    for p in $(resolve_projects "$@"); do check_project "$p" "$rev" || rc=1; done
    exit "$rc"
    ;;
  audit)
    shift || true
    rc=0
    for p in $(resolve_projects "$@"); do audit_project "$p" || rc=1; done
    exit "$rc"
    ;;
  *)
    usage
    ;;
esac

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
  echo "usage: devkit.sh {list|init <项目>|sync [项目...]|check [项目...]}" >&2
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
  *)
    usage
    ;;
esac

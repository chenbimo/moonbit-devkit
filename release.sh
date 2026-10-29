#!/bin/bash
# 发版一条命令:算版本 → 改常量 → 提交 → 打 tag → 推送,之后由 CI 接手。
#
# 用法(Git Bash,不要用 WSL——推送需要 Windows 侧的 SSH 私钥):
#   bash scripts/release.sh bm2 patch    # 0.7.0 → 0.7.1
#   bash scripts/release.sh bm2 minor    # 0.7.0 → 0.8.0
#   bash scripts/release.sh bm2 major    # 0.7.0 → 1.0.0
#
# 对应的口令是「发布小版本 / 发布中版本 / 发布大版本」,版本位由口令决定,不由脚本猜。
# 推送 tag 之后 release workflow 依次跑:验证 → 构建(x64/arm64) → GitHub Release → moon publish。
#
# 拒绝执行的情况:工作区不干净、不在 main、tag 已存在、版本常量读不到。
# 这些都是发布事故的常见来源,宁可停下来说清楚,也不硬发。
set -euo pipefail

WORKSPACE=${RELEASE_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

die() {
  echo "release: $*" >&2
  exit 1
}

# 读项目 devkit.conf 里的单个声明。第二个参数是 conf 文件路径。
conf_value() {
  sed -nE "s/^$1=\"?([^\"#]*)\"?/\1/p" "$2" 2>/dev/null |
    head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

name=${1:-}
bump=${2:-}
case "$bump" in
  patch | minor | major) ;;
  *) die "用法: bash scripts/release.sh <项目> <patch|minor|major>" ;;
esac
[ -n "$name" ] || die "缺少项目名"

project="$WORKSPACE/$name"
[ -d "$project/.git" ] || die "$name 不是 git 仓库"
conf="$project/scripts/devkit.conf"
[ -f "$conf" ] || die "$name 缺少 scripts/devkit.conf"

# 工作区必须干净:发版时混进未提交的改动,产物与 tag 就对不上代码。
[ -z "$(git -C "$project" status --porcelain)" ] || die "$name 工作区不干净,先提交或还原"

branch=$(git -C "$project" rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || die "$name 当前在 $branch,发版只从 main"

current=$(sed -nE 's/^version = "([^"]+)"/\1/p' "$project/moon.mod" | head -1)
[ -n "$current" ] || die "$name 读不到 moon.mod 的 version"

IFS=. read -r major minor patch <<< "$current"
case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
tag="v$next"

if git -C "$project" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  die "$tag 已存在,不能重复发布"
fi
if git -C "$project" ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  die "$tag 已在远端存在"
fi

label=$(conf_value DEVKIT_NAME "$conf")
[ -n "$label" ] || label=$name
release=$(conf_value DEVKIT_RELEASE "$conf")
[ -n "$release" ] && [ "$release" != "none" ] || die "$name 未声明 DEVKIT_RELEASE,没有发布流水线"

echo "release: $label $current -> $next ($bump, $release)"

# 1) 版本常量:moon.mod 是要害,CLI 常量由 devkit 的 version_sync 校验同步。
sed -i "s/^version = \"$current\"/version = \"$next\"/" "$project/moon.mod"
version_file=$(conf_value DEVKIT_VERSION_FILE "$conf")
if [ -n "$version_file" ]; then
  [ -f "$project/$version_file" ] || die "版本文件不存在: $version_file"
  sed -i "s/$current/$next/g" "$project/$version_file"
fi
# 文档里的示例版本(形如 `bm2 0.7.0`)跟着走,免得手册停在老版本上。
while IFS= read -r doc; do
  sed -i "s/$label $current/$label $next/g" "$doc"
done < <(grep -rl "$label $current" "$project/docs" "$project/README.md" 2>/dev/null || true)

# 2) 提交。只提交这次改到的文件。
files=("moon.mod")
[ -n "$version_file" ] && files+=("$version_file")
while IFS= read -r doc; do
  files+=("${doc#"$project"/}")
done < <(grep -rl "$label $next" "$project/docs" "$project/README.md" 2>/dev/null || true)
git -C "$project" add -- "${files[@]}"
git -C "$project" commit -m "[$label](chore) 版本升到 $next" -- "${files[@]}"

# 3) 打 tag 并推送。推送才真正触发流水线,漏推等于没发布。
git -C "$project" tag -a "$tag" -m "$label $next"
git -C "$project" push origin main
git -C "$project" push origin "$tag"

echo "release: $tag 已推送,CI 接手:验证 → 构建 → GitHub Release → moon publish"

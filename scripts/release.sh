#!/usr/bin/env bash
# Maintainer release helper; compatible with macOS Bash 3.2 and Linux Bash.
set -euo pipefail
fail() { printf '错误: %s\n' "$*" >&2; exit 1; }
valid_version() { [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
version_gt() {
  local a b c x y z
  IFS=. read -r a b c <<< "$1"
  IFS=. read -r x y z <<< "$2"
  (( a > x || (a == x && b > y) || (a == x && b == y && c > z) ))
}
main() {
  if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo '用法: bash scripts/release.sh'
    echo '交互选择版本，检查测试，创建版本提交和标签，然后推送 origin/main 触发 GitHub Release。'
    echo '请先提交所有修改；支持当前版本、补丁、次版本、主版本和自定义稳定版本。'
    return
  fi
  (($# == 0)) || fail '不支持的参数，请使用 --help'
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  local branch current major minor patch choice next answer tag existing tmp
  branch=$(git symbolic-ref --quiet --short HEAD) || fail '不能在 detached HEAD 状态发布'
  [[ $branch == main ]] || fail '请切换到 main 分支发布'
  [[ -z $(git status --porcelain) ]] || fail '工作区有未提交的修改，请先提交后再发布'
  git remote get-url origin >/dev/null || fail '缺少 origin 远程仓库'
  current=$(sed -n 's/^SB_VERSION="\([^"]*\)"$/\1/p' sb.sh)
  valid_version "$current" || fail 'sb.sh 中的 SB_VERSION 必须是 X.Y.Z'
  # Fetch before selecting a version so remote tags and branch state are current.
  git fetch origin --prune --tags
  git show-ref --verify --quiet refs/remotes/origin/main || fail 'origin/main 不存在'
  git merge-base --is-ancestor origin/main HEAD || fail '本地 main 落后或与 origin/main 分叉，请先同步'
  IFS=. read -r major minor patch <<< "$current"
  printf '\n当前版本: %s\n' "$current"
  printf '  1) 补丁版本 %s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
  printf '  2) 次版本   %s.%s.0\n' "$major" "$((minor + 1))"
  printf '  3) 主版本   %s.0.0\n' "$((major + 1))"
  printf '  4) 自定义版本\n  5) 发布当前版本 %s（尚未打标签时）\n  0) 取消\n' "$current"
  read -r -p '请选择 [1]: ' choice || return 0
  case ${choice:-1} in
    1) next="$major.$minor.$((patch + 1))" ;;
    2) next="$major.$((minor + 1)).0" ;;
    3) next="$((major + 1)).0.0" ;;
    4) read -r -p '输入版本号（例如 1.2.0）: ' next || return 0; next=${next#v} ;;
    5) next=$current ;;
    0) return 0 ;;
    *) fail '无效选项' ;;
  esac
  valid_version "$next" || fail '仅支持 X.Y.Z 稳定版本，不允许前导零'
  [[ $next == "$current" ]] || version_gt "$next" "$current" || fail '新版本不能低于当前版本'
  tag="v$next"
  git show-ref --verify --quiet "refs/tags/$tag" && fail "标签 $tag 已存在"
  while IFS= read -r existing; do
    existing=${existing#v}
    if valid_version "$existing" && ! version_gt "$next" "$existing"; then
      fail "发布版本必须高于已有版本 $existing"
    fi
  done < <(git tag --list 'v*')
  echo '运行发布前检查...'
  bash scripts/check.sh
  printf '\n将发布 %s → %s\n远程: %s\n' "$current" "$next" "$(git remote get-url --push origin)"
  echo '将推送以下未推送的提交，以及版本提交（如有）和标签:'
  git log --oneline origin/main..HEAD
  printf '标签: %s\n' "$tag"
  read -r -p '确认创建提交、标签并推送，触发公开发布? [y/N]: ' answer || return 0
  [[ $answer == y || $answer == Y ]] || return 0
  # Recheck after the prompt, so concurrent edits are never silently staged.
  [[ -z $(git status --porcelain) ]] || fail '工作区已变化，请重新运行'
  if [[ $next != "$current" ]]; then
    tmp=$(mktemp)
    sed "s/^SB_VERSION=\"$current\"$/SB_VERSION=\"$next\"/" sb.sh > "$tmp"
    cat "$tmp" > sb.sh
    rm -f "$tmp"
    git add -- sb.sh
    git commit -m "chore: release $tag"
  fi
  git tag -a "$tag" -m "Release $tag"
  # Atomic push prevents a published tag from pointing at an unpushed branch update.
  if ! git push --atomic origin HEAD:refs/heads/main "refs/tags/$tag"; then
    printf '推送失败，本地版本提交和标签已保留。排除问题后重试:\n  git push --atomic origin HEAD:refs/heads/main refs/tags/%s\n' "$tag" >&2
    return 1
  fi
  echo "已推送 ${tag}；GitHub Actions 将执行检查并创建 Release，请在仓库 Actions 页面查看结果。"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

#!/usr/bin/env bash
# Development entry point. Deploy the standalone artifact from scripts/build.sh.
SB_VERSION="1.2.2"
SB_ENTRY=${BASH_SOURCE[0]}
SB_SOURCE_DIR=$(cd -- "$(dirname -- "$SB_ENTRY")" && pwd) || { return 1 2>/dev/null || exit 1; }
SB_ENTRY="$SB_SOURCE_DIR/$(basename -- "$SB_ENTRY")"
if [[ ! -r $SB_SOURCE_DIR/lib/modules.list ]]; then
  printf '%s\n' '缺少 lib 模块。请克隆完整仓库，或下载 Release 中的独立 sb.sh。' >&2
  return 1 2>/dev/null || exit 1
fi
while IFS= read -r sb_module; do
  source "$SB_SOURCE_DIR/lib/$sb_module.sh" || { return 1 2>/dev/null || exit 1; }
done < "$SB_SOURCE_DIR/lib/modules.list"
unset sb_module
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi

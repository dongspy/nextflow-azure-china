#!/usr/bin/env bash
# 将 core.windows.net 递归替换为 core.chinacloudapi.cn
# - 安全处理多层目录/含空格文件名（NUL 分隔）
# - 不把 NUL 数据放进变量，避免 “ignored null byte” 警告
# - dry-run 预览、时间戳备份、跳过二进制与常见产物目录

set -euo pipefail
IFS=$'\n\t'

ROOT="${1:-.}"
OLD="${OLD:-core.windows.net}"
NEW="${NEW:-core.chinacloudapi.cn}"
DRY="${DRY:-1}"              # 1=仅预览，0=执行替换
BACKUP="${BACKUP:-1}"        # 1=生成 .bak_时间戳 备份
SHOW_DIFF="${SHOW_DIFF:-1}"  # 1=展示每个文件的差异片段

EXCLUDES=(
  ".git" ".gradle" ".idea" "node_modules" "venv" ".venv"
  "build" "dist" "out" "target"
)

timestamp="$(date +%Y%m%d%H%M%S)"
bak_sfx=".bak_${timestamp}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

abort() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "$ROOT" ]] || abort "目录不存在: $ROOT"

echo ">>> ROOT     : $ROOT"
echo ">>> REPLACE  : $OLD  =>  $NEW"
echo ">>> DRY-RUN  : $DRY   (DRY=0 才会真正修改)"
echo ">>> BACKUP   : $BACKUP (备份后缀: ${bak_sfx})"
echo

# 临时文件：存放 NUL 分隔的匹配列表（不要存进变量）
LIST="$(mktemp)"
cleanup() { rm -f "$LIST"; }
trap cleanup EXIT

collect_files_git() {
  (cd "$ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1) || return 1
  (cd "$ROOT" && git ls-files -z | xargs -0 grep -IlZ -- "$OLD" || true)
}

collect_files_find() {
  # 构造 find 命令，排除常见目录
  local find_cmd=(find "$ROOT")
  for ex in "${EXCLUDES[@]}"; do
    find_cmd+=(-path "*/$ex/*" -prune -o)
  done
  find_cmd+=(-type f -print0)
  "${find_cmd[@]}" | xargs -0 grep -IlZ -- "$OLD" || true
}

echo ">>> 扫描包含 '$OLD' 的文本文件 ..."
if collect_files_git >"$LIST"; then
  SRC="git"
  # ok
else
  SRC="find"
  collect_files_find >"$LIST"
fi

FILES_COUNT="$(awk -v RS='\0' 'END{print NR}' "$LIST")"
echo ">>> 命中文件数: $FILES_COUNT（来源: $SRC）"
if [[ "$FILES_COUNT" -eq 0 ]]; then
  echo "没有任何文件包含 '$OLD'。"
  exit 0
fi

echo
echo ">>> 命中预览（每个文件最多 3 行）："
while IFS= read -r -d '' f; do
  echo "----- $f"
  grep -n -m 3 --color=always "$OLD" "$f" || true
done <"$LIST"

if [[ "$DRY" -eq 1 ]]; then
  echo
  echo "DRY=1 仅预览，未做任何修改。设置 DRY=0 执行替换。"
  exit 0
fi

echo
echo ">>> 开始替换 ..."
MOD=0
USE_PERL=0
have_cmd perl && USE_PERL=1

while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue

  if [[ "$BACKUP" -eq 1 ]]; then
    cp -p -- "$f" "$f${bak_sfx}"
  fi

  tmp="$f.__tmp__"
  if [[ "$USE_PERL" -eq 1 ]]; then
    # perl 读全文件，原样替换（包含二进制安全）
    perl -0777 -pe "s/\Q$OLD\E/$NEW/g" -- "$f" > "$tmp"
  else
    # sed 方案（不使用 -i，兼容 GNU/BSD）
    sed "s/${OLD//\//\\/}/${NEW//\//\\/}/g" "$f" > "$tmp"
  fi

  if ! cmp -s -- "$f" "$tmp"; then
    mv -f -- "$tmp" "$f"
    echo "Updated: $f"
    MOD=$((MOD+1))
    if [[ "$SHOW_DIFF" -eq 1 ]] && have_cmd diff && [[ "$BACKUP" -eq 1 ]]; then
      echo "  diff 示例 (最多 ~120 行)："
      diff -u -- "$f${bak_sfx}" "$f" | sed -n '1,120p' || true
    fi
  else
    rm -f -- "$tmp"
  fi
done <"$LIST"

echo ">>> 替换完成。修改文件数: $MOD"
if [[ "$BACKUP" -eq 1 ]]; then
  echo ">>> 备份后缀: ${bak_sfx}"
  echo ">>> 回滚命令（谨慎执行）："
  echo "find '$ROOT' -type f -name '*${bak_sfx}' -exec bash -c 'orig=\${1%${bak_sfx}}; mv -f -- \"\$1\" \"\$orig\"' _ {} \\;"
fi

echo "全部完成。"


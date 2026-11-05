#!/usr/bin/env bash
# FAIL checker: 「無い/切れている/見つからない」系の否定断定と同一行に
# 実在するパスがある場合、矛盾疑いを出す（実在物を「無い」と断定する失敗型）。
# 対応 incident: 2026-07-14 project-a READ_FIRST.html「11本リンク切れ」誤断定（全11件実在）。
# NEG 語彙は精度優先で絞る（丁寧語の「〜ありません」単独では発火させない）。
# 「はありません」は弱い否定として、直前がパス様トークンのときだけ対象にする
# （誤爆実績: 2026-07-16「実害はありません」＋同一行の無関係な実在パスで false block）。
# 誤爆が出たら checkers/README.md の手順で語彙・token 規則を調整する。
set -u
NEG_STRONG='は存在しません|存在しない|見つかりません|見つからない|リンク切れ|切れてい|not found|does not exist|no such file|broken link'
PATH_RE='(~/|/)?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+/?|[A-Za-z0-9_.-]+/'

emit_if_exists() { # $1=token
  local p=$1
  case $p in
    "~/"*) p="$HOME/${p#\~/}" ;;
    /*) : ;;
    *) p="${AGT_CWD:-.}/$p" ;;
  esac
  if [ -e "$p" ]; then
    printf 'FAIL\tnegation_vs_exists\t否定断定と同一行のパスが実在する: %s\n' "$1"
  fi
}

sed -E 's#https?://[^ )>"]+##g' \
| while IFS= read -r line || [ -n "$line" ]; do
    if grep -qE "$NEG_STRONG" <<<"$line"; then
      # 強い否定: 同一行の全パス様トークンを突合
      grep -oE "$PATH_RE" <<<"$line" \
      | grep -vE '^[0-9/.:-]+/?$' \
      | sort -u | head -20 \
      | while IFS= read -r tok; do emit_if_exists "$tok"; done
    else
      # 弱い否定「はありません」: 直前がパス様トークンの場合のみ、そのパスだけ突合
      grep -oE "($PATH_RE) ?はありません" <<<"$line" \
      | sed -E 's/ ?はありません$//' \
      | grep -E '/' \
      | grep -vE '^[0-9/.:-]+/?$' \
      | sort -u | head -20 \
      | while IFS= read -r tok; do emit_if_exists "$tok"; done
    fi
  done
exit 0

#!/usr/bin/env bash
# INFO checker: 最終応答の code block 内にある「command 前置なしの検索コマンド」の観測。
#
# 目的: グローバル CLAUDE.md「応答・報告様式」節は、報告に件数・ファイル列挙を載せるとき
# `grep`・`find` を `command` 前置で実行し、コマンド全文を併記することを求める。CC のシェルでは
# これらがラッパー関数へ置き換わっており、実バイナリと走査範囲が異なるためである。
# 条文だけでは人手順守に依存する（条項を書いた当人が2巡続けて落ちた——E-20990101000049-070e §6）。
# ここはその機械検出層で、**判定ではなく観測**である。**FAIL / WARN は絶対に出さない**
# （裁定封筒 E-20990101000050-d954 §2-2。FAIL 化は .ai の事前確認事項）。
#
# 2層の位置づけ（同封筒 §2-3）: `bin/envelope-lint` が提出物（封筒）の門で、こちらは全応答の観測。
# lint 単独だと封筒以外の応答の裸 grep が見えず、checker 単独だと提出前の強制力がない。
#
# ground truth: 「command 前置があるか」は機械抽出可能な字面の性質であり、自然言語の解釈を要しない。
#
# 出力: INFO<TAB>bare-search-cmd<TAB>件数=<n> 行=<L<no>:<cmd>,...>
# 検出が無ければ無音。
# 観測ログ: state repo notes/bare_search_observations.log へ TSV を1行追記する
# （97 と同形式・時刻・cwd・件数・検出コマンド）。追記に失敗しても無音で継続する（fail-open）。
# fail-open: 入力が空・観測ログが書けない場合は静かに縮退する。
set -u
MSG=$(cat)
[ -n "$MSG" ] || exit 0

DIR="$(cd "$(dirname "$0")" && pwd)"

# fenced code block の中だけを見る。散文で「grep で確認した」と書くことは条文の対象外であり、
# 実行行だけを対象にする（96/97 と同じ行トグルで fence を判定する）。
BLOCK=$(awk 'BEGIN{f=0} /^[[:space:]]*```/{f=1-f; next} f==1{printf "%d\t%s\n", NR, $0}' <<<"$MSG")
[ -n "$BLOCK" ] || exit 0

HITS=""
COUNT=0
while IFS=$'\t' read -r lineno text; do
  [ -n "${text:-}" ] || continue
  # 行頭・`;`・`&&`・`||`・`|`・`$(`・バッククォートの直後をコマンドの開始位置とみなし、
  # 先頭の環境変数代入を読み飛ばしてから最初の語を見る。`command` 前置は適合とする。
  found=$(awk -v line="$text" '
    BEGIN {
      n = split(line, seg, /[;|&]|\$\(|`/)
      for (i = 1; i <= n; i++) {
        s = seg[i]
        sub(/^[ \t]+/, "", s)
        while (match(s, /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/)) {
          s = substr(s, RLENGTH + 1)
          sub(/^[ \t]+/, "", s)
        }
        if (match(s, /^[A-Za-z_][A-Za-z0-9_.-]*/)) {
          w = substr(s, 1, RLENGTH)
          if (w == "command") continue
          if (w == "grep" || w == "egrep" || w == "fgrep" || w == "rgrep" || w == "find")
            print w
        }
      }
    }' | sort -u | tr '\n' '/' | sed 's|/$||')
  if [ -n "$found" ]; then
    HITS="${HITS:+$HITS,}L${lineno}:${found}"
    COUNT=$((COUNT + 1))
  fi
done <<< "$BLOCK"

[ "$COUNT" -gt 0 ] || exit 0

ROOT="$(cd "$DIR/../../.." && pwd)"
OBS_LOG="${AGT_BARE_SEARCH_LOG:-$ROOT/notes/bare_search_observations.log}"
# 2>/dev/null をリダイレクトより前に置く。リダイレクト解決の失敗はシェル自身が fd2 へ
# 報告するため、後置だと書けない場所を指定されたときにエラー文が漏れる（97 と同じ扱い）。
printf '%s\t%s\t%s\t%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S')" "${AGT_CWD:-}" "$COUNT" "$HITS" \
  2>/dev/null >> "$OBS_LOG" || true

printf 'INFO\tbare-search-cmd\t件数=%d 行=%s\n' "$COUNT" "$HITS"
exit 0

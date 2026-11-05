#!/usr/bin/env bash
# python 実装（baseline_count.py）と実 checker（97_stop_phrase.sh）の判定一致を検算する。
set -u
SAMPLE_DIR="${STOP_PHRASE_SAMPLE_DIR:-/tmp/stop_phrase_sample}"
C="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checkers/97_stop_phrase.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok=0; ng=0
# expect.tsv の第4列は「実 checker が拾うか」（質問形＋宣言形）。第2列は baseline の
# 4象限が使う質問形のみの判定で、2層化以降は checker と一致しない。第4列が無い旧 tsv では
# 第2列へ縮退する（2026/08/22・tier 2層化に伴う検算の是正）。
while IFS=$'\t' read -r f exp_stop exp_anchor exp_stop_all; do
  exp_stop_all="${exp_stop_all:-$exp_stop}"
  # 検算の対象は stop / anchor の2値であり、発火（FAIL）は python 実装が持たない判定である。
  # 明示 OFF で走らせて INFO 行だけを見る（2026/08/22・conf 既定が enabled=yes になったため）。
  out=$(AGT_STOP_PHRASE_ENFORCE=no AGT_STOP_PHRASE_LOG="$T/o.log" AGT_CWD=/tmp bash "$C" < "$f")
  info=$(grep '^INFO' <<<"$out" | head -1)
  if [ -n "$info" ]; then
    got_stop=stop
    # 詳細欄は 検出句=… approval_anchor=… tier=… の順に並ぶ。値だけを取り出す
    # （2026/08/22 に tier を足したため、行末までを値と見なす旧実装は壊れていた）。
    got_anchor=$(sed -n 's/.*approval_anchor=\([A-Za-z]*\).*/\1/p' <<<"$info")
  else
    got_stop=nostop
    got_anchor="$exp_anchor"
  fi
  if [ "$got_stop" = "$exp_stop_all" ] && [ "$got_anchor" = "$exp_anchor" ]; then
    ok=$((ok+1))
  else
    ng=$((ng+1))
    echo "不一致: $f 期待=$exp_stop_all/$exp_anchor 実際=$got_stop/$got_anchor"
  fi
done < "$SAMPLE_DIR/expect.tsv"
echo "検算: 一致 $ok / 不一致 $ng"
[ "$ng" -eq 0 ]

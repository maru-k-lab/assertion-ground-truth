#!/usr/bin/env bash
# FAIL checker: コピー用実体（コマンド・トリガー）への「上記」参照と「提示済」主張の
# 実体確認（自己完結型）。
# 対応 incident: 2026-08-09——ex-send の HUMAN_WRITE_COMMAND（rclone コマンド）を agmsg
# 送信ツール実行と同一ターンの本文に書いたため画面未表示のまま、後続応答で
# 「上記 rclone コマンドの実行」と参照し、「表示されていない」との指摘へ「提示済み」と
# 過去の自分の出力を根拠に反論した（tasks/lessons.md 2026/08/09・owner 指示で checker 化）。
#
# ground truth: 過去ターンの表示成否は機械検証不能（テキストを書いてもツール実行を続けた
# ターンは画面に出ないことがある）。そのため「参照・既提示主張をする応答自身が、コピー
# 可能な実体（fenced code block）を伴うか」を突合する。『書いた』でなく『届いた』を、
# 同一応答内の再掲で担保する。
#
# - Rule A: 文が「上記」＋対象語（rclone|コマンド|トリガー）＋行為語（実行|コピ|貼）を
#   含むのに、応答に fence（```）が1つも無い = FAIL
# - Rule B: 文が既提示主張（提示済|表示済|掲載済|再掲済）＋対象語（rclone|コマンド|
#   トリガー|コードブロック）を含むのに、応答に fence が1つも無い = FAIL
# - 負ガード: 文に（誤|訂正|指摘|反論）を含む場合は判定しない（振り返り記述の誤爆回避）
# - 前処理: fenced block と inline code を除去した散文を「。」区切りで文単位判定
#   （メタ議論はトークンを backtick で囲めば素通し＝80 と同方針・意図的）
# - fence があれば内容の同一性までは検証しない（取りこぼし側へ倒す）
# - fail-open: メッセージ空は無音
set -u
MSG=$(cat)
[ -n "$MSG" ] || exit 0

# fence の有無は「行トグル」（行頭空白＋``` で始まる行）で判定する。散文中の三連
# バッククォート言及は fence ではない（2026/08/09 検証レビュー BLOCKING 1 対応）。
# 開始と終了の対が要るため2行以上を実体とみなす（未クローズ fence は実体と数えない
# ＝ FAIL 側へ倒す）。
FENCE_LINES=$(grep -cE '^[[:space:]]*```' <<<"$MSG")
[ "$FENCE_LINES" -ge 2 ] && exit 0

# 散文抽出: fenced block を行トグルで除去し、inline code を除去
PROSE=$(awk 'BEGIN{f=0} /^[[:space:]]*```/{f=1-f; next} f==0{print}' <<<"$MSG" \
  | sed 's/`[^`]*`//g')

FAIL_A=0
FAIL_B=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  # 負ガード: 振り返り・訂正の文は判定しない
  if grep -qE '誤|訂正|指摘|反論' <<<"$s"; then
    continue
  fi
  if grep -q '上記' <<<"$s" \
     && grep -qE 'rclone|コマンド|トリガー' <<<"$s" \
     && grep -qE '実行|コピ|貼' <<<"$s"; then
    FAIL_A=1
  fi
  if grep -qE '提示済|表示済|掲載済|再掲済' <<<"$s" \
     && grep -qE 'rclone|コマンド|トリガー|コードブロック' <<<"$s"; then
    FAIL_B=1
  fi
done < <(tr '\n' '。' <<<"$PROSE" | sed 's/。/。\n/g')

if [ "$FAIL_A" -eq 1 ]; then
  printf 'FAIL\tpresented_reference\t「上記」でコマンド類を参照しているが、この応答にコードブロックが無い（ツール実行を続けたターンの本文は画面に出ないことがある。参照先の実体をこの応答にコードブロックで再掲すること）\n'
fi
if [ "$FAIL_B" -eq 1 ]; then
  printf 'FAIL\tpresented_reference\tコマンド類を「提示済」と主張しているが、この応答にコードブロックが無い（過去の提示は表示された保証がない。実体をこの応答にコードブロックで再掲すること）\n'
fi
exit 0

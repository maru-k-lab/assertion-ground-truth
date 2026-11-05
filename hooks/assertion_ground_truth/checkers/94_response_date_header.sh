#!/usr/bin/env bash
# FAIL checker: 応答冒頭の日時ヘッダ（ユーザー対応方針「回答冒頭にbash dateで取得した
# 現在日時を表示」）の値を、transcript の直近ユーザー発話以降のツール実行記録と突合する
# （process-evidence 型・値一致）。
# 対応 incident: 2026-08-06 00:47 頃——CC が応答冒頭に「0:47:03」を bash date 未実行のまま
# 記載（直前の実測は 00:39:37・次の実測は 00:46:18＝どの tool_result にも 0:47:03 は不在）。
# 自己申告で発覚・PROJECT_STATE meta-harness 項番21 の関連 incident。
#
# - FAIL: 応答冒頭3行に日時ヘッダ様トークン（yyyy/MM/dd H:mm[:ss]）があるのに、
#   transcript の「最後の生ユーザー発話」以降の行にその値（時を2桁正規化・秒なしは
#   分精度で前方一致）が存在しない ＝ 未実行の捏造、または過去ターン値の使い回しの疑い
# - 無音: ヘッダなし（ヘッダ不在の検出は対象外＝UNCOVERED 記帳）／値が実行記録に在る
# - fail-open: transcript 不在・ヘッダ抽出不能は無音
# - 生ユーザー発話の判定: '"type":"user"' を含み '"tool_result"' を含まない行
#   （tool_result は user ロールで注入されるため除外）
set -u
MSG=$(cat)
TP="${AGT_TRANSCRIPT:-}"
[ -n "$TP" ] && [ -f "$TP" ] || exit 0

TS=$(head -3 <<<"$MSG" | grep -oE '20[0-9]{2}/[0-9]{2}/[0-9]{2} [0-9]{1,2}:[0-9]{2}(:[0-9]{2})?' | head -1)
[ -n "$TS" ] || exit 0

DATEPART="${TS%% *}"
TIMEPART="${TS#* }"
HH="${TIMEPART%%:*}"
REST="${TIMEPART#*:}"
# 時は 10 進として読む。`printf '%02d' 08` は bash では八進数の不正値としてエラーになり 00 を
# 返すため、08・09 時台のヘッダが別の時刻に化ける（2026/09/11 実測・Codex 検証レビュー r4
# BLOCKING 1）。この不具合は本封筒の変更より前から在った。
NEEDLE="$DATEPART $(printf '%02d' "$((10#$HH))"):$REST"

# ---- 同ターン内の date 実行結果との突合（E-20990101000076-761a Task 2）-------------
# 既存の検査は「冒頭の日時が transcript のどこかに文字列として在るか」しか見ておらず、
# その値が date の実行に由来するかを突合していない。ここで、同ターン内で実際に実行された
# date の出力とだけ突き合わせる。既定は観測のみで、FAIL は conf で切り替える。
DH_CONF="${AGT_DATE_HEADER_CONF:-$(dirname "$0")/date_header_verify.conf}"
DH_VERIFY=no
if [ -r "$DH_CONF" ]; then
  DH_RAW=$(sed -n 's/^[[:space:]]*date_header_verify[[:space:]]*=//p' "$DH_CONF" | tail -1)
  DH_VAL=$(printf '%s' "${DH_RAW%%#*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ "$DH_VAL" = yes ] && DH_VERIFY=yes
fi
case "${AGT_DATE_HEADER_VERIFY:-}" in yes) DH_VERIFY=yes ;; no) DH_VERIFY=no ;; esac

# 比較は秒まで厳密に行う（2-a は変更不可）。冒頭が分までしか書かれていない応答は、秒一致を
# 確認できないので合格にしない。既存の抽出正規表現が秒なしも拾うことは、規則が秒なしでの
# 合格を許す根拠にはならない（2026/09/11 Codex 検証レビュー BLOCKING 2）。
dh_norm() { # yyyy/MM/dd H:mm[:ss] → 比較用キー YYYY-MM-DD HH:MM[:SS]
  local d="${1%% *}" t="${1#* }" h r
  h="${t%%:*}"; r="${t#*:}"
  # 時は 10 進として読む（上の NEEDLE と同じ理由。08・09 が八進数エラーで 00 に化ける）。
  printf '%s %02d:%s' "${d//\//-}" "$((10#$h))" "$r"
}
DH_HEAD_KEY=$(dh_norm "$TS")
case "$TS" in *:*:*) DH_HEAD_HAS_SEC=yes ;; *) DH_HEAD_HAS_SEC=no ;; esac
DH_EVID="$(dirname "$0")/date_header_evidence.py"
DH_CANDS=""
if [ -r "$DH_EVID" ]; then
  DH_CANDS=$(timeout 8 python3 "$DH_EVID" "$TP" 2>/dev/null || true)
fi

DH_VERDICT=no_date
DH_MATCHED=""
DH_DIFF=""
# 候補は date_header_evidence.py が既に正規形（YYYY-MM-DD HH:MM[:SS]）で返す。ここで再度
# 正規化しない。
if head -3 <<<"$MSG" | grep -q '取得不能'; then
  DH_VERDICT=exempt
elif [ "$DH_HEAD_HAS_SEC" = no ]; then
  # 秒を持たない冒頭は、秒まで一致したことを確認できない。2-a の合格条件を満たさないため
  # 合格にしない。観測で見分けられるよう専用の判定値を置く。
  DH_VERDICT=no_seconds
  DH_MATCHED=$(printf '%s' "$DH_CANDS" | head -1)
elif [ -n "$DH_CANDS" ]; then
  DH_VERDICT=mismatch
  DH_BEST=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    DH_MATCHED="$cand"
    if [ "$cand" = "$DH_HEAD_KEY" ]; then
      DH_VERDICT=ok
      DH_BEST="$cand"
      break
    fi
  done <<<"$DH_CANDS"
  [ -n "$DH_BEST" ] && DH_MATCHED="$DH_BEST"
  if [ "$DH_VERDICT" = mismatch ] && [ -n "$DH_MATCHED" ]; then
    # 比較キーは精度によって秒を持たないことがある。持たないときだけ :00 を補う。
    # 無条件に付けると "…09:51:32:00" という不正な文字列になり、date が黙って失敗して
    # ずれ秒数が空欄のまま残る（2026/09/11 実測・本封筒 Task 4 の陽性テストで検出）。
    dh_epoch() {
      local k="$1"
      case "$k" in *:*:*) : ;; *) k="$k:00" ;; esac
      date -d "$k" +%s 2>/dev/null
    }
    DH_A=$(dh_epoch "$DH_HEAD_KEY")
    DH_B=$(dh_epoch "$DH_MATCHED")
    if [ -n "$DH_A" ] && [ -n "$DH_B" ]; then
      DH_DIFF=$(( DH_A > DH_B ? DH_A - DH_B : DH_B - DH_A ))
    fi
  fi
fi

# 観測ログ。書けない場合は無音で継続する（97 と同じ fail-open）。
DH_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DH_LOG="${AGT_DATE_HEADER_LOG:-$DH_ROOT/notes/date_header_observations.log}"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S')" "${AGT_CWD:-}" "$DH_VERDICT" "$TS" "$DH_MATCHED" "$DH_DIFF" \
  2>/dev/null >> "$DH_LOG" || true

# 差し戻し後の再走では新設の FAIL を出さない。dispatch.py は stop_hook_active のとき
# 97 だけを走らせるため本 checker はそもそも呼ばれないが、将来 dispatcher が渡す場合に
# 備えて checker 側でも倒しておく（97 と同じ二重の担保）。
DH_REWALK=no
case "${AGT_STOP_HOOK_ACTIVE:-}" in 1|true|True|yes) DH_REWALK=yes ;; esac

if [ "$DH_VERIFY" = yes ] && [ "$DH_REWALK" = no ]; then
  case "$DH_VERDICT" in
    mismatch|no_date|no_seconds)
      printf 'FAIL\tresponse_date_header\t冒頭時刻が同ターン内の date 実行結果と一致しない、または date を実行していない。bash で date を実行し、その出力を冒頭に転記して応答し直す。取得不能なら「日時取得不能」と書く。\n'
      exit 0
      ;;
    ok|exempt)
      # 合格したら従来検査へ進まない。従来検査は冒頭の値を **スラッシュ形の文字列のまま**
      # transcript から探すため、`date -Is` のように別形式で出力したターンでは、同ターンの
      # date 出力と秒まで一致していても「セッションのどこにも無い＝捏造の疑い」で FAIL を
      # 出してしまう（2026/09/11 実測・Codex 検証レビュー r3 BLOCKING 1）。
      # 新判定は「同ターンで実行した date の出力に由来するか」を直接見ており、従来の文字列
      # 検索より強い証拠である。強い検査が通ったものを弱い検査で落とさない。
      # verify=no のときはここへ来ないため、既定の挙動は従来のまま変わらない。
      exit 0
      ;;
  esac
fi
# ------------------------------------------------------------------------------------

# 最後の生ユーザー発話行の行番号（無ければ 0 ＝ 全体を探索）
LASTUSER=$(awk '/"type":"user"/ && !/"tool_result"/ {n=NR} END{print n+0}' "$TP")

if tail -n +"$((LASTUSER + 1))" "$TP" | grep -qF "$NEEDLE"; then
  exit 0
fi
# ゼロ詰めなし原文でも再探索（表示形そのままの引用に対する保険）
if [ "$NEEDLE" != "$DATEPART $TIMEPART" ] && tail -n +"$((LASTUSER + 1))" "$TP" | grep -qF "$DATEPART $TIMEPART"; then
  exit 0
fi

if grep -qF "$NEEDLE" "$TP" || grep -qF "$DATEPART $TIMEPART" "$TP"; then
  printf 'FAIL\tresponse_date_header\t冒頭の日時 %s は直近ユーザー発話以降の実行記録に無い（過去ターン実行値の使い回しの疑い。bash date を今ターンで実行し直すこと）\n' "$TS"
else
  printf 'FAIL\tresponse_date_header\t冒頭の日時 %s がセッションのツール実行記録のどこにも無い（bash date 未実行の捏造の疑い。実行し実出力の値を表示すること）\n' "$TS"
fi
exit 0

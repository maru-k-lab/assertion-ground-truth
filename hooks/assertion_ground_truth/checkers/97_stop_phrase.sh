#!/usr/bin/env bash
# INFO checker: 応答末尾の「停止句」（人間へ判断を返して待つ／やると宣言してターンを終える
# 言い回し）の計数。
#
# 目的: CC が承認済み作業の途中で止まる頻度を観測する。判定ではなく計数である。
# **既定では FAIL / WARN を出さない**（裁定封筒 E-20990101000041-4e9e §3 Task 1）。
# 発火モード（FAIL 出力）は stop_phrase_enforce.conf の enabled=yes でのみ働き、既定は no
# である（裁定封筒 E-20990101000044-fe34 §4。有効化は第2段封筒まで行わない）。
#
# ground truth: 停止句そのものは自然言語であり真偽の機械突合ができない。ここで突合するのは
# 「停止句を含む応答か否か」と「同一応答内に承認元アンカー（ISSUE 番号）があるか否か」の
# 2値のみで、いずれも機械抽出可能である。アンカーの有無で窓を分けないと、承認済み作業での
# 停止（減らしたいもの）と未承認作業での確認（正しいもの）が混ざり効果判定ができない
# （同封筒 §3 Task 1・GPT 指摘）。
#
# 3層構成（declare の38語化と future 層の追加は E-20990101000065-d9e4 Task 1・3）:
#   tier=ask     stop_phrases.txt（質問形）。散文全体を対象にする。
#   tier=declare stop_phrases_declare.txt（宣言形38語）。**最終散文段落のみ**を対象にする。
#                宣言形は文中の正当な叙述に頻出し、末尾でターンが切れることが失敗の型である。
#   tier=future  stop_phrases_future.txt（未来時刻・順序標識）。**観測専用で FAIL に使わない。**
#                最終散文段落を文単位に割り、疑問・依頼で終わる文を除いて照合する。
#   tier=negative stop_phrases_negative.txt（除外リスト45語）。**観測専用で FAIL に使わない。**
#                他の層と使い方が逆で、当たったら記録しない。末尾文が丁寧形で終わり、疑問・
#                依頼でなく、除外語のどれにも当たらないときに記録する。動作動詞は開放集合だが
#                除外側は閉じている見込みがあり、その仮説を観測で検証する（E-20990101000068-f695
#                Task 1・設計は E-20990101000066-ee82 §2 案α）。
#
# 出力: INFO<TAB>stop-phrase<TAB>検出句=<句,...> approval_anchor=<yes|no> tier=<ask|declare|ask,declare>
# 停止句が無ければ無音。
# 観測ログ: 検出時に state repo notes/stop_phrase_observations.log へ TSV を1行追記する
# （E-20990101000043-34c8 §7-1 の改定条文・E-20990101000044-fe34 §2 で承認）。dispatch.py は
# FAIL が無ければ即 return するため、INFO は Stop hook の出力経路には現れない。観測はこの
# ログで取る。追記に失敗しても無音で継続する（fail-open）。
# fail-open: 入力が空・句リストが読めない場合は無音で終了する。
set -u
MSG=$(cat)
[ -n "$MSG" ] || exit 0

DIR="$(cd "$(dirname "$0")" && pwd)"
LIST="$DIR/stop_phrases.txt"
LIST_DECLARE="$DIR/stop_phrases_declare.txt"
LIST_FUTURE="$DIR/stop_phrases_future.txt"
LIST_NEG="$DIR/stop_phrases_negative.txt"
[ -r "$LIST" ] || exit 0

# 停止句の照合は fenced code block と inline code を除いた散文に対して行う。
# 手順書やテンプレートの引用、この checker 自身の説明を数えないため（96 と同方針）。
PROSE=$(awk 'BEGIN{f=0} /^[[:space:]]*```/{f=1-f; next} f==0{print}' <<<"$MSG" \
  | sed 's/`[^`]*`//g')
[ -n "$PROSE" ] || exit 0

# 最終散文段落＝空行区切りで見た最後の非空ブロック。宣言形の判定対象。
TAIL=$(awk '
  { lines[NR]=$0 }
  END {
    end=0
    for (i=NR; i>=1; i--) { if (lines[i] ~ /[^[:space:]]/) { end=i; break } }
    if (end==0) exit
    start=1
    for (i=end; i>=1; i--) { if (lines[i] !~ /[^[:space:]]/) { start=i+1; break } }
    for (i=start; i<=end; i++) print lines[i]
  }' <<<"$PROSE")

HITS=""        # ask / declare。FAIL の判定に使う
HITS_OBS=""    # future。観測専用で FAIL の判定に使わない
TIERS=""
while IFS= read -r phrase; do
  case "$phrase" in ''|'#'*) continue ;; esac
  if grep -qF -- "$phrase" <<<"$PROSE"; then
    HITS="${HITS:+$HITS,}$phrase"
    case ",$TIERS," in *,ask,*) ;; *) TIERS="${TIERS:+$TIERS,}ask" ;; esac
  fi
done < "$LIST"

if [ -r "$LIST_DECLARE" ] && [ -n "$TAIL" ]; then
  while IFS= read -r phrase; do
    case "$phrase" in ''|'#'*) continue ;; esac
    if grep -qF -- "$phrase" <<<"$TAIL"; then
      HITS="${HITS:+$HITS,}$phrase"
      case ",$TIERS," in *,declare,*) ;; *) TIERS="${TIERS:+$TIERS,}declare" ;; esac
    fi
  done < "$LIST_DECLARE"
fi

# future 層（観測専用）。最終段落を文単位に割り、疑問・依頼で終わる文を除いて照合する。
# 疑問・依頼は ask 層の守備範囲であり、二重に数えないため除く。
if [ -r "$LIST_FUTURE" ] && [ -n "$TAIL" ]; then
  FUT_SENTS=$(sed 's/。/\n/g' <<<"$TAIL" \
    | grep -vE 'ますか|でしょうか|ください|下さい|いかがで|どちらに|教えて|[?？][[:space:]]*$' \
    || true)
  if [ -n "$FUT_SENTS" ]; then
    while IFS= read -r phrase; do
      case "$phrase" in ''|'#'*) continue ;; esac
      if grep -qF -- "$phrase" <<<"$FUT_SENTS"; then
        HITS_OBS="${HITS_OBS:+$HITS_OBS,}$phrase"
        case ",$TIERS," in *,future,*) ;; *) TIERS="${TIERS:+$TIERS,}future" ;; esac
      fi
    done < "$LIST_FUTURE"
  fi
fi

# negative 層（観測専用）。最終段落の末尾文が丁寧形で終わり、疑問・依頼でなく、除外リストの
# どれにも当たらないときに記録する。記録する句は末尾の述語そのものであり、否定リストを育てる
# ときの材料になる（裁定 E-20990101000068-f695 Task 1 手順2）。
# 疑問・依頼を除くのは future 層と同じ理由（ask 層と二重に数えない）で、設計封筒 cadb §2 の
# 実測もこの前処理で行っている。数値を比較できるよう同じにしてある。
if [ -r "$LIST_NEG" ] && [ -n "$TAIL" ]; then
  NEG_LAST=$(sed 's/。/\n/g' <<<"$TAIL" | grep -v '^[[:space:]]*$' | tail -1)
  if [ -n "$NEG_LAST" ] \
     && grep -qE '(ます|ません)[。．！!.]?[[:space:]]*$' <<<"$NEG_LAST" \
     && ! grep -qE 'ますか|でしょうか|ください|下さい|いかがで|どちらに|教えて|[?？][[:space:]]*$' <<<"$NEG_LAST"; then
    NEG_EXCLUDED=no
    while IFS= read -r phrase; do
      case "$phrase" in ''|'#'*) continue ;; esac
      if grep -qE -- "$(printf '%s' "$phrase")[。．！!.]?[[:space:]]*\$" <<<"$NEG_LAST"; then
        NEG_EXCLUDED=yes
        break
      fi
    done < "$LIST_NEG"
    if [ "$NEG_EXCLUDED" = no ]; then
      # 末尾の述語を助詞境界で切り出す。切り出せない場合は句を空にせず末尾文の末尾20字を使う。
      NEG_PRED=$(grep -oE '[^をにへがはでともの、。「」（）　 ]+(ます|ません)[。．！!.]?[[:space:]]*$' <<<"$NEG_LAST" \
        | sed 's/[。．！!.[:space:]]*$//' | tail -1)
      [ -n "$NEG_PRED" ] || NEG_PRED=$(printf '%s' "$NEG_LAST" | tail -c 60)
      HITS_OBS="${HITS_OBS:+$HITS_OBS,}$NEG_PRED"
      case ",$TIERS," in *,negative,*) ;; *) TIERS="${TIERS:+$TIERS,}negative" ;; esac
    fi
  fi
fi

# 観測ログは future 層だけが立った場合も残す（発火はしない）。
ALL_HITS="$HITS"
[ -n "$HITS_OBS" ] && ALL_HITS="${ALL_HITS:+$ALL_HITS,}$HITS_OBS"
[ -n "$ALL_HITS" ] || exit 0

# 承認元アンカー: 封筒 ISSUE の形式 E-yyyyMMddHHmmss-<4桁hex>。
# 応答全体（コードブロックを含む）を対象にする。アンカーの転記は引用の形を取ることが
# あるため、散文に限ると取りこぼす。
# 前後にトークン境界を要求する。部分一致のままだと XE-20990101000041-4e9e や
# E-20990101000041-4e9ea のような ISSUE でない文字列まで yes に分類し、アンカー有無別の
# 集計を誤らせる（2026/08/19 Codex 検証レビュー BLOCKING 2 対応）。
if grep -qE '(^|[^0-9A-Za-z])E-[0-9]{14}-[0-9a-fA-F]{4}([^0-9A-Za-z]|$)' <<<"$MSG"; then
  ANCHOR=yes
else
  ANCHOR=no
fi

# 観測ログへ1行追記する。dispatch.py の出力経路では INFO を観測できないため、計数は
# ここで取る。書けない場合（sandbox 下のレーン等）は無音で継続し、欠落は集計時に
# 「観測できなかった」として扱う（成功件数を偽らない）。
ROOT="$(cd "$DIR/../../.." && pwd)"
OBS_LOG="${AGT_STOP_PHRASE_LOG:-$ROOT/notes/stop_phrase_observations.log}"
# 2>/dev/null を先に置く。リダイレクト解決の失敗はシェル自身が fd2 へ報告するため、
# 後置だと書けない場所を指定されたときにエラー文が漏れる。
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S')" "${AGT_CWD:-}" "$ANCHOR" "$ALL_HITS" "$TIERS" \
  2>/dev/null >> "$OBS_LOG" || true

printf 'INFO\tstop-phrase\t検出句=%s approval_anchor=%s tier=%s\n' "$ALL_HITS" "$ANCHOR" "$TIERS"

# ---- 発火モード（既定 OFF）--------------------------------------------------
# 次の条件をすべて満たすときだけ FAIL を出す。
#   1. 停止句を検出（上で確定済み）
#   2. approval_anchor=yes（承認済み作業窓に限定）。ただし conf の require_anchor=no のときは
#      この関門を課さず、アンカーの有無を問わず発火する（E-20990101000075-5d39 Task 1-a）。
#   3. 正当停止マーカー 停止条件=<1-6> が応答内に無い
#   4. ループガード: 差し戻し後の再停止を再度差し戻さない
#   5. このターンで起動した非同期実行が走っていない（E-20990101000065-d9e4 Task 2）
# 判定できないときは発火しない側へ倒す（fail-closed）。
# future 層と negative 層は観測専用であり、これらだけでは発火しない。
ENFORCE=no
# conf のパスはテスト用に上書きできる。キー欠落・不正値の挙動は一時 conf を指して実挙動で
# 試験する必要があり、本番 conf を書き換えずに済ませるためである
# （E-20990101000075-5d39 の禁止事項「Task 4 完了前の本番 conf 変更」）。
CONF="${AGT_STOP_PHRASE_CONF:-$DIR/stop_phrase_enforce.conf}"
if [ -r "$CONF" ] && grep -qE '^[[:space:]]*enabled=yes[[:space:]]*$' "$CONF"; then
  ENFORCE=yes
fi
# テスト用の明示上書き。既定は conf の値。yes 以外はすべて no（fail-closed）。
case "${AGT_STOP_PHRASE_ENFORCE:-}" in
  yes) ENFORCE=yes ;;
  no)  ENFORCE=no ;;
esac
[ "$ENFORCE" = yes ] || exit 0

# future 層と negative 層は観測専用である。ask / declare のヒットが無ければ発火しない。
[ -n "$HITS" ] || exit 0

# 関門2: 承認済み作業窓（approval_anchor=yes）へ限るか否かを conf の require_anchor で切る。
# 値が no のときだけ窓を広げる。キーが無い・読めない・yes/no 以外はすべて yes として扱い、
# 窓を広げない側へ倒す（fail-closed の向きは「発火を広げない」側である）。
# 判定に使うのは最後に現れた require_anchor 行の値で、行末コメントは値に含めない。
# 値は行末コメントを落として前後の空白を取り、**残り全体**が no のときだけ窓を広げる。
# 先頭だけを見ると `require_anchor=no garbage` のような行を no と読み、契約に反して窓を
# 広げてしまう（2026/09/10 Codex 検証レビュー BLOCKING 2）。
REQUIRE_ANCHOR=yes
if [ -r "$CONF" ]; then
  RA_RAW=$(sed -n 's/^[[:space:]]*require_anchor[[:space:]]*=//p' "$CONF" | tail -1)
  RA_VAL=$(printf '%s' "${RA_RAW%%#*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$RA_VAL" in
    no) REQUIRE_ANCHOR=no ;;
    *)  REQUIRE_ANCHOR=yes ;;
  esac
fi
if [ "$REQUIRE_ANCHOR" = yes ]; then
  [ "$ANCHOR" = yes ] || exit 0
fi

# 正当停止マーカーは応答全体を対象にする。コードブロック内の記載も有効と数えるのは、
# 見逃し（FAIL を出さない）側へ倒すためである。マーカーは cc/CLAUDE.md〈停止の判断〉節の
# 6条件に対応する。6 は「owner の承認・指示待ち」（同 CLAUDE.md〈仕様先行〉2-b）であり、
# require_anchor=no で未承認作業の窓が入るために要る値である（E-20990101000075-5d39 Task 1-c）。
if grep -qE '停止条件[[:space:]]*=[[:space:]]*[1-6]' <<<"$MSG"; then
  exit 0
fi

# dispatch.py は入力 JSON の stop_hook_active が真のとき checker を実行する前に return する
# （現物 dispatch.py の main 冒頭で確認済み・2026/08/22）。したがってループガードは
# dispatcher 側で既に成立している。ここでは、将来 dispatcher が checker へ受け渡す場合に
# 備えて環境変数も見る。値が真なら発火しない。
case "${AGT_STOP_HOOK_ACTIVE:-}" in
  1|true|True|yes) exit 0 ;;
esac

# 非同期実行の走行中は差し戻さない（E-20990101000065-d9e4 Task 2）。宣言して背景処理を
# 起動し、その完了を待ってターンを閉じるのは正しい振る舞いであり、差し戻すと待つべき場面で
# 動けと促すことになる。harness は完了時にモデルを呼び戻すため待機で不利益は生じない。
# 判定は checkers/async_inflight.py が行い、RUNNING / IDLE / UNKNOWN のいずれかを返す。
# IDLE 以外（走行中・判定不能）はすべて発火しない側へ倒す（fail-closed）。
# 既知の限界: 起動が tool_use として記録されない待機——agmsg の受信待ち、tmux 別レーンの
# 待機、外部プロセスの完了待ち——は IDLE と判定される。承知のうえで採る（220a §6-(2) 案a・
# 封筒 Task 2）。除外条件は発火を減らす向きにしか働かないため、穴があっても見逃しは増えない。
# 判定スクリプトが無い場合も「判定できない」として発火しない側へ倒す。ここを素通りに
# すると、部分配置（checker だけ置いて .py を置き忘れた等）で除外が静かに効かなくなり、
# 待機中の応答を差し戻す。2026/09/01 のテスト T123 がこの穴を検出した。
INFLIGHT_PY="$DIR/async_inflight.py"
if [ -r "$INFLIGHT_PY" ]; then
  INFLIGHT=$(timeout 8 python3 "$INFLIGHT_PY" "${AGT_TRANSCRIPT:-}" 2>/dev/null || echo UNKNOWN)
else
  INFLIGHT=UNKNOWN
fi
[ "$INFLIGHT" = IDLE ] || exit 0

# 発火理由の tier に観測専用の層（future・negative）を混ぜない。
TIERS_FIRE=$(tr ',' '\n' <<<"$TIERS" | grep -vxE 'future|negative' | paste -sd, -)

# 差し戻し文の冒頭は、検出した ANCHOR の値に合わせる。require_anchor=no ではアンカーの無い
# 応答も対象になるため、固定文のままだと承認待ちを差し戻す場面で「承認済み作業」だと
# 通知することになり、同じ文の末尾「承認なしで進まない」と矛盾する
# （2026/09/10 Codex 検証レビュー BLOCKING 1）。
if [ "$ANCHOR" = yes ]; then
  HEAD_TXT='承認済み作業（アンカーあり）で停止句を検出'
else
  HEAD_TXT='アンカーの無い応答で停止句を検出'
fi

# 差し戻し文は1行で出す。dispatch.py は checker の stdout を行単位に割り、行頭が FAIL の行
# だけを差し戻し理由へ積むため、改行を挟むと後半の行が黙って捨てられる。1-d の追加文を
# 同一行の末尾へ置くのはこの制約による（E-20990101000075-5d39 Task 1-d）。
printf 'FAIL\tstop-phrase\t%s（検出句=%s tier=%s）。〈停止の判断〉1〜6のどれに当たるか明記して止まるか（停止条件=N）、当たらなければ作業を続けて完了させること。承認・指示待ちで止まる場合は、本文に 停止条件=6 を書いて止まる。差し戻しを理由に承認なしで進まない。\n' \
  "$HEAD_TXT" "$HITS" "$TIERS_FIRE"
exit 0

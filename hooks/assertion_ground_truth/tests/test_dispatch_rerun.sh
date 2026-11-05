#!/usr/bin/env bash
# dispatch.py（案C: 差し戻しの連鎖上限・2026/09/17 稼働）の実挙動テスト。
#
# 裁定封筒 E-20990101000099-3ba4 Task 2 の T1〜T7 と、.ai 条件の補足分を実測する。
# 本番 conf を書き換えず、AGT_STOP_PHRASE_CONF と TMPDIR を一時ディレクトリへ向け、
# dispatch.py に標準入力（Stop hook の入力 JSON）を与えて直接叩く。
#
# 隔離: 実装版を一時ディレクトリへ写し、その直下に checkers/ を作って 97 とその
# データだけを置く。本番 checkers/ を走らせると 97 以外の FAIL が混ざり、
# 連鎖の判定を測ったことにならない。観測ログも AGT_STOP_PHRASE_LOG で一時先へ逃がす
# （本番 notes/stop_phrase_observations.log を汚さない）。
#
# 使い方: bash hooks/assertion_ground_truth/tests/test_dispatch_rerun.sh
set -u

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$SRC_DIR/dispatch.py"
[ -r "$IMPL" ] || { echo "実装版が見つかりません: $IMPL" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); printf 'NG   %s\n     %s\n' "$1" "$2"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ---- 隔離した実行環境 -------------------------------------------------------
HOOKDIR="$WORK/hooks"; mkdir -p "$HOOKDIR/checkers"
cp "$IMPL" "$HOOKDIR/dispatch.py"
cp "$SRC_DIR/checkers/97_stop_phrase.sh" "$HOOKDIR/checkers/"
cp "$SRC_DIR/checkers/async_inflight.py" "$HOOKDIR/checkers/"
# 句リストは最小化した写しを置く。本番の4リスト（合計約120語）は1語ごとに grep を
# 起動するため、この機体では 97 の実行が 7.6〜15.4 秒に振れ、dispatch の checker
# タイムアウト（10秒）を跨いでテストが非決定になる（2026/09/17 実測）。測りたいのは
# dispatcher の連鎖判定であり、句リストの網羅性は 97 自身のテストの担当である。
printf '# test fixture\n指示をください\n'  > "$HOOKDIR/checkers/stop_phrases.txt"
printf '# test fixture\n続けます\n'        > "$HOOKDIR/checkers/stop_phrases_declare.txt"
printf '# test fixture\n'                  > "$HOOKDIR/checkers/stop_phrases_future.txt"
printf '# test fixture\n'                  > "$HOOKDIR/checkers/stop_phrases_negative.txt"
DISPATCH="$HOOKDIR/dispatch.py"

export AGT_STOP_PHRASE_LOG="$WORK/obs.log"

# conf: 発火 ON・アンカーを要求しない。max_chain だけを振る。
CONF_DIR="$WORK/conf"; mkdir -p "$CONF_DIR"
printf 'enabled=yes\nrequire_anchor=no\n'               > "$CONF_DIR/default.conf"
printf 'enabled=yes\nrequire_anchor=no\nmax_chain=2\n'  > "$CONF_DIR/max2.conf"
printf 'enabled=yes\nrequire_anchor=no\nmax_chain=1\n'  > "$CONF_DIR/max1.conf"
printf 'enabled=yes\nrequire_anchor=no\nmax_chain=x\n'  > "$CONF_DIR/bad.conf"
printf 'enabled=yes\nrequire_anchor=no\nmax_chain=2 garbage\n' > "$CONF_DIR/garbage.conf"
printf 'enabled=yes\nrequire_anchor=no\nmax_chain=2 # 既定\n'  > "$CONF_DIR/comment.conf"

# 非同期実行なしの transcript（97 の発火条件5を通すために要る）。
TR="$WORK/tr_idle.jsonl"
python3 - "$TR" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": "作業して"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "報告です"}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
PY

STOP_MSG=$'実装しました。\n\n続けます。'
QUIET_MSG=$'実装しました。\n\n結果は以上です。'

# 連鎖 state の置き場所。TMPDIR を振り替えて本番 /tmp と分ける。
CHAIN_TMP="$WORK/tmp"; mkdir -p "$CHAIN_TMP"
CHAIN_FILE="$CHAIN_TMP/agt_stop_phrase_chain/tr_idle.txt"

# AGT_RERUN_TEST_VERBOSE=1 で、各呼び出しの入力 JSON と実出力を stderr へ出す。
# 報告へ「入力・期待・実出力」を転記するための経路であり、判定には使わない。
run() { # $1=conf $2=stop_hook_active(true|false) $3=msg  [$4=TMPDIR上書き]
  local conf="$1" active="$2" msg="$3" tmpd="${4:-$CHAIN_TMP}" inp out
  inp=$(python3 - "$msg" "$active" "$TR" <<'PY'
import json, sys
print(json.dumps({
    "last_assistant_message": sys.argv[1],
    "stop_hook_active": sys.argv[2] == "true",
    "transcript_path": sys.argv[3],
    "cwd": "/home/user/state",
}, ensure_ascii=False))
PY
)
  local rc
  out=$(env TMPDIR="$tmpd" AGT_STOP_PHRASE_CONF="$conf" python3 "$DISPATCH" <<<"$inp" 2>"$WORK/last_stderr")
  rc=$?
  if [ "${AGT_RERUN_TEST_VERBOSE:-}" = 1 ]; then
    printf '  入力 conf=%s TMPDIR=%s\n  入力 JSON: %s\n  実出力: %s\n' \
      "$(basename "$conf")" "$tmpd" "$inp" "${out:-（無音）}" >&2
  fi
  printf '%s' "$out"
  # dispatcher の終了コードをそのまま呼び出し側へ返す。printf の rc を返していた
  # あいだ、T6 の rc=0 検査は dispatcher の異常終了を検出できなかった
  # （2026/09/17 Codex 検証レビュー BLOCKING 2）。陽性対照は補足8 で測る。
  return "$rc"
}

chain_now() { [ -r "$CHAIN_FILE" ] && cat "$CHAIN_FILE" || echo "(なし)"; }
reset_chain() { rm -rf "$CHAIN_TMP/agt_stop_phrase_chain"; }

# ---- T1: stop_hook_active=false・停止句あり → 差し戻し・連鎖=1 --------------
reset_chain
out=$(run "$CONF_DIR/max2.conf" false "$STOP_MSG")
if grep -q '"decision": *"block"' <<<"$out" \
   && grep -q '停止条件=N' <<<"$out" \
   && [ "$(chain_now)" = 1 ]; then
  ok "T1 通常ターン・停止句あり → 差し戻し・連鎖=1"
else ng "T1" "chain=$(chain_now) out=$out"; fi

# ---- T2: 真・停止句あり・連鎖=1 → 差し戻し（新文面）・連鎖=2 ---------------
out=$(run "$CONF_DIR/max2.conf" true "$STOP_MSG")
if grep -q '"decision": *"block"' <<<"$out" \
   && grep -q '差し戻し後の応答が再び停止句で終わっている' <<<"$out" \
   && grep -q '連鎖2回目' <<<"$out" \
   && ! grep -q '次は差し戻さない' <<<"$out" \
   && grep -q '\- stop-phrase ' <<<"$out" \
   && [ "$(chain_now)" = 2 ]; then
  ok "T2 再走・連鎖=1 → 差し戻し（新文面・stop-phrase 印あり）・連鎖=2"
else ng "T2" "chain=$(chain_now) out=$out"; fi

# ---- T3: 真・停止句あり・連鎖=2 → 差し戻さない・観測ログには残る -----------
: > "$AGT_STOP_PHRASE_LOG"
out=$(run "$CONF_DIR/max2.conf" true "$STOP_MSG")
if [ -z "$out" ] && [ "$(chain_now)" = 2 ] \
   && grep -q 'declare' "$AGT_STOP_PHRASE_LOG"; then
  ok "T3 再走・連鎖=2（上限） → 差し戻さない・観測ログには残る"
else ng "T3" "chain=$(chain_now) out=$out log=$(cat "$AGT_STOP_PHRASE_LOG")"; fi

# ---- T4: 真・停止句なし → 無音・連鎖は増えない -----------------------------
reset_chain
run "$CONF_DIR/max2.conf" false "$STOP_MSG" >/dev/null   # 連鎖=1 を作る
out=$(run "$CONF_DIR/max2.conf" true "$QUIET_MSG")
if [ -z "$out" ] && [ "$(chain_now)" = 1 ]; then
  ok "T4 再走・停止句なし → 無音・連鎖は増えない"
else ng "T4" "chain=$(chain_now) out=$out"; fi

# ---- T5: 偽・停止句なし → 無音・連鎖=0 -------------------------------------
out=$(run "$CONF_DIR/max2.conf" false "$QUIET_MSG")
if [ -z "$out" ] && [ "$(chain_now)" = 0 ]; then
  ok "T5 通常ターン・停止句なし → 無音・連鎖=0"
else ng "T5" "chain=$(chain_now) out=$out"; fi

# ---- T6: state ファイルが書けない → 無音で継続（fail-open）-----------------
# TMPDIR を書込不可のディレクトリへ向ける。state は作れないが落ちてはいけない。
RO="$WORK/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
out=$(run "$CONF_DIR/max2.conf" true "$STOP_MSG" "$RO"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$RO/agt_stop_phrase_chain" ]; then
  ok "T6 state が書けない → 無音で継続・rc=0（fail-open／発火は fail-closed）"
else ng "T6" "rc=$rc out=$out"; fi
chmod 700 "$RO"

# ---- T7: 上限=1・T2 と同入力 → 差し戻さない（現行挙動と同値）--------------
reset_chain
run "$CONF_DIR/max1.conf" false "$STOP_MSG" >/dev/null   # 連鎖=1
out=$(run "$CONF_DIR/max1.conf" true "$STOP_MSG")
if [ -z "$out" ] && [ "$(chain_now)" = 1 ]; then
  ok "T7 上限=1 → 再走では差し戻さない（現行挙動と同値）"
else ng "T7" "chain=$(chain_now) out=$out"; fi

# ---- 補足1: max_chain キーが無ければ既定 2（T2 と同じ挙動）----------------
reset_chain
run "$CONF_DIR/default.conf" false "$STOP_MSG" >/dev/null
out=$(run "$CONF_DIR/default.conf" true "$STOP_MSG")
if grep -q '連鎖2回目' <<<"$out" && [ "$(chain_now)" = 2 ]; then
  ok "補足1 max_chain 欠落 → 既定 2"
else ng "補足1" "chain=$(chain_now) out=$out"; fi

# ---- 補足2: max_chain が整数でない → 1 扱い（発火を広げない側）------------
reset_chain
run "$CONF_DIR/bad.conf" false "$STOP_MSG" >/dev/null
out=$(run "$CONF_DIR/bad.conf" true "$STOP_MSG")
if [ -z "$out" ] && [ "$(chain_now)" = 1 ]; then
  ok "補足2 max_chain 不正値 → 1 扱い（再走で差し戻さない）"
else ng "補足2" "chain=$(chain_now) out=$out"; fi

# ---- 補足3: 値の残余は不正値として扱う（97 の require_anchor と同じ読み方）-
reset_chain
run "$CONF_DIR/garbage.conf" false "$STOP_MSG" >/dev/null
out=$(run "$CONF_DIR/garbage.conf" true "$STOP_MSG")
if [ -z "$out" ] && [ "$(chain_now)" = 1 ]; then
  ok "補足3 max_chain=2+残余 → 不正値として 1 扱い"
else ng "補足3" "chain=$(chain_now) out=$out"; fi

# ---- 補足4: 行末コメントは値に含めない ------------------------------------
reset_chain
run "$CONF_DIR/comment.conf" false "$STOP_MSG" >/dev/null
out=$(run "$CONF_DIR/comment.conf" true "$STOP_MSG")
if grep -q '連鎖2回目' <<<"$out" && [ "$(chain_now)" = 2 ]; then
  ok "補足4 max_chain=2+行末コメント → 2 扱い"
else ng "補足4" "chain=$(chain_now) out=$out"; fi

# ---- 補足5: 通常ターンでは 97 以外の checker も走る ------------------------
# 再走時に広げるのは停止句だけ、という不変条件の対になる確認である。
cat > "$HOOKDIR/checkers/10_fake.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'FAIL\tfake\t偽の検出\n'
SH
reset_chain
out=$(run "$CONF_DIR/max2.conf" false "$QUIET_MSG")
if grep -q '偽の検出' <<<"$out"; then
  ok "補足5 通常ターンでは 97 以外の checker も走る"
else ng "補足5" "$out"; fi
# ---- 補足6: 再走時は 97 以外を走らせない ----------------------------------
reset_chain
run "$CONF_DIR/max2.conf" false "$STOP_MSG" >/dev/null
out=$(run "$CONF_DIR/max2.conf" true "$STOP_MSG")
if ! grep -q '偽の検出' <<<"$out" && grep -q '連鎖2回目' <<<"$out"; then
  ok "補足6 再走時は 97 以外を走らせない"
else ng "補足6" "$out"; fi
rm -f "$HOOKDIR/checkers/10_fake.sh"

# ---- 補足7: 24時間より古い state は掃除される -----------------------------
reset_chain
run "$CONF_DIR/max2.conf" false "$STOP_MSG" >/dev/null
STALE="$CHAIN_TMP/agt_stop_phrase_chain/old_session.txt"
echo 1 > "$STALE"; touch -d '25 hours ago' "$STALE"
run "$CONF_DIR/max2.conf" false "$STOP_MSG" >/dev/null
if [ ! -e "$STALE" ] && [ -e "$CHAIN_FILE" ]; then
  ok "補足7 24時間より古い state は掃除され、現行分は残る"
else ng "補足7" "stale=$([ -e "$STALE" ] && echo 残 || echo 消) cur=$(chain_now)"; fi

# ---- 補足8: run が dispatcher の終了コードを返す（陽性対照）-----------------
# 2026/09/17 Codex 検証レビュー BLOCKING 2 の是正確認。わざと落ちる dispatcher を
# 同じ経路で叩き、rc が 0 以外で返ることを見る。これが通らないと T6 の rc 検査は空振りする。
cat > "$HOOKDIR/broken.py" <<'PY'
import sys
sys.stdin.read()
raise SystemExit(3)
PY
SAVED_DISPATCH="$DISPATCH"; DISPATCH="$HOOKDIR/broken.py"
reset_chain
out=$(run "$CONF_DIR/max2.conf" false "$STOP_MSG"); rc=$?
DISPATCH="$SAVED_DISPATCH"
if [ "$rc" -eq 3 ] && [ -z "$out" ]; then
  ok "補足8 run は dispatcher の終了コードをそのまま返す（陽性対照 rc=3）"
else ng "補足8" "rc=$rc out=$out"; fi
rm -f "$HOOKDIR/broken.py"

# ---- 補足9: max_chain=² は不正値扱い・Traceback を出さない -------------------
# `²` は isdigit() が真だが int() は ValueError。2026/09/17 Codex 検証レビュー
# BLOCKING 1 の是正確認（是正前は rc=1・Traceback）。
printf 'enabled=yes\nrequire_anchor=no\nmax_chain=²\n' > "$CONF_DIR/superscript.conf"
reset_chain
run "$CONF_DIR/superscript.conf" false "$STOP_MSG" >/dev/null
out=$(run "$CONF_DIR/superscript.conf" true "$STOP_MSG"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(chain_now)" = 1 ] \
   && ! command grep -q 'Traceback' "$WORK/last_stderr"; then
  ok "補足9 max_chain=² は不正値として 1 扱い・rc=0・Traceback なし"
else ng "補足9" "rc=$rc chain=$(chain_now) out=$out err=$(cat "$WORK/last_stderr")"; fi

# ---- 補足10: 上限到達の分岐でも古い state は掃除される ----------------------
# 掃除を chain_write の中だけで行っていたあいだ、state を書かない上限到達分岐では
# 古いファイルが残り続けた（2026/09/17 Codex 検証レビュー BLOCKING 3）。
reset_chain
run "$CONF_DIR/max2.conf" false "$STOP_MSG" >/dev/null
echo 2 > "$CHAIN_FILE"                      # 上限に達した状態を作る
OLD="$CHAIN_TMP/agt_stop_phrase_chain/stale_other.txt"
echo 2 > "$OLD"; touch -d '25 hours ago' "$OLD"
out=$(run "$CONF_DIR/max2.conf" true "$STOP_MSG")   # 上限到達＝state を書かない分岐
if [ -z "$out" ] && [ ! -e "$OLD" ]; then
  ok "補足10 上限到達の分岐でも 24時間より古い state が掃除される"
else ng "補足10" "stale=$([ -e "$OLD" ] && echo 残 || echo 消) out=$out"; fi

printf '\n合計: ok=%d NG=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# stop_phrase_block_followup.py の join_log（差し戻しと観測ログ行の突合）のテスト。
#
# 対応 incident: 案C（差し戻しの連鎖上限・2026/09/17 稼働）では、連鎖1回目と2回目の
# 差し戻しが同じ 120 秒窓に並ぶ。従来の join_log は「窓内にちょうど1本」でしか確定
# しなかったため、連鎖ペアでは1回目の log_ts・cwd・approval_anchor が空になる。
# 是正案（封筒 E-20990101000101-761a Task 3-2(b)）は、窓の終端を followup_ts で閉じ、
# 候補が複数なら blocked_ts に最も近い1本を採る。同一秒の同着は従来どおり確定させない。
#
# 使い方: bash hooks/assertion_ground_truth/tests/test_block_followup_join.sh
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stop_phrase_block_followup.py"
[ -r "$SCRIPT" ] || { echo "対象が見つかりません: $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass+1)); }
ng() { printf 'NG   %s\n  --- 実際の出力 ---\n%s\n' "$1" "$2"; fail=$((fail+1)); }

CWD=/home/user/testproj
OTHER=/home/user/otherproj

# transcript は UTC 表記、観測ログはローカル naive。テストはローカル naive で書き、
# transcript 側だけ UTC へ直す（本番と同じ突合経路を通す）。
cat > "$TMP/mk.py" <<'PY'
import datetime as dt
import json
import sys


def utc(s):
    return dt.datetime.fromisoformat(s).astimezone(dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


out, cwd = [], sys.argv[2]
for spec in sys.argv[3:]:
    kind, ts, text = spec.split("|", 2)
    out.append(json.dumps({
        "type": "assistant" if kind == "a" else "user",
        "timestamp": utc(ts),
        "cwd": cwd,
        "message": {"content": [{"type": "text", "text": text}]},
    }, ensure_ascii=False))
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
PY

FB=$'Stop hook feedback:\nassertion_ground_truth 検出: 応答が停止句で終わっている。\n- stop-phrase 検出句=指示をください tier=ask'

mk() { local out="$1"; shift; python3 "$TMP/mk.py" "$out" "$CWD" "$@"; }
run() { python3 "$SCRIPT" --log "$1" --projects "$2" 2>/dev/null; }
col() { awk -F'\t' -v r="$2" -v c="$3" 'NR==r{print $c}' <<<"$1"; }

# ---- J1 陽性: 連鎖ペアで1回目も確定する（窓を followup_ts で閉じる）---------------
D="$TMP/j1"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB" \
  "a|2026-09-17T12:01:00|まとめます" \
  "u|2026-09-17T12:01:10|$FB" \
  "a|2026-09-17T12:02:00|実装し、テストを通しました。"
printf '2026-09-17T12:00:20\t%s\tyes\t指示をください\task\n2026-09-17T12:01:20\t%s\tno\tまとめます\tdeclare\n' "$CWD" "$CWD" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ "$(wc -l <<<"$out")" = "2" ] \
   && [ "$(col "$out" 1 1)" = "2026-09-17T12:00:20" ] && [ "$(col "$out" 1 3)" = "yes" ] \
   && [ "$(col "$out" 2 1)" = "2026-09-17T12:01:20" ] && [ "$(col "$out" 2 3)" = "no" ]; then
  ok "J1 陽性: 連鎖ペアの1回目・2回目とも観測ログ行が確定する"
else ng "J1" "$out"; fi

# ---- J2 陽性対照: 次の応答より後の観測行は拾わない（取り違え防止）----------------
D="$TMP/j2"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB" \
  "a|2026-09-17T12:00:30|実装し、テストを通しました。"
printf '2026-09-17T12:01:00\t%s\tyes\t指示をください\task\n' "$CWD" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ "$(wc -l <<<"$out")" = "1" ] && [ -z "$(col "$out" 1 1)" ] && [ -z "$(col "$out" 1 3)" ]; then
  ok "J2 陽性対照: followup より後の観測行は採らない（log_ts・anchor は空）"
else ng "J2" "$out"; fi

# ---- J3 陰性: 同一秒の同着は確定させない ------------------------------------------
D="$TMP/j3"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB" \
  "a|2026-09-17T12:01:00|実装し、テストを通しました。"
printf '2026-09-17T12:00:20\t%s\tyes\t指示をください\task\n2026-09-17T12:00:20\t%s\tno\t指示をください\task\n' "$CWD" "$CWD" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ -z "$(col "$out" 1 1)" ] && [ -z "$(col "$out" 1 3)" ]; then
  ok "J3 陰性: 同一秒に2本並ぶときは確定させない"
else ng "J3" "$out"; fi

# ---- J4 陰性: 窓内に1本だけなら従来どおり確定する（回帰なし）----------------------
D="$TMP/j4"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB" \
  "a|2026-09-17T12:01:00|実装し、テストを通しました。"
printf '2026-09-17T12:00:20\t%s\tyes\t指示をください\task\n' "$CWD" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ "$(col "$out" 1 1)" = "2026-09-17T12:00:20" ] && [ "$(col "$out" 1 3)" = "yes" ]; then
  ok "J4 陰性: 窓内に1本なら従来どおり確定する"
else ng "J4" "$out"; fi

# ---- J5 陰性: cwd が違う行は採らない -----------------------------------------------
D="$TMP/j5"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB" \
  "a|2026-09-17T12:01:00|実装し、テストを通しました。"
printf '2026-09-17T12:00:20\t%s\tyes\t指示をください\task\n' "$OTHER" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ -z "$(col "$out" 1 1)" ] && [ "$(col "$out" 1 2)" = "$CWD" ]; then
  ok "J5 陰性: cwd の一致しない観測行は採らない"
else ng "J5" "$out"; fi

# ---- J6 陽性: 候補が複数なら blocked_ts に最も近い1本を採る ------------------------
D="$TMP/j6"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB" \
  "a|2026-09-17T12:01:00|実装し、テストを通しました。"
printf '2026-09-17T12:00:20\t%s\tyes\t指示をください\task\n2026-09-17T12:00:40\t%s\tno\t指示をください\task\n' "$CWD" "$CWD" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ "$(col "$out" 1 1)" = "2026-09-17T12:00:20" ] && [ "$(col "$out" 1 3)" = "yes" ]; then
  ok "J6 陽性: 候補が複数なら blocked_ts に最も近い1本を採る"
else ng "J6" "$out"; fi

# ---- J7 陰性: followup が無ければ従来の 120 秒窓のまま -----------------------------
D="$TMP/j7"; mkdir -p "$D"
mk "$D/s1.jsonl" \
  "a|2026-09-17T12:00:00|指示をください" \
  "u|2026-09-17T12:00:10|$FB"
printf '2026-09-17T12:01:30\t%s\tyes\t指示をください\task\n' "$CWD" > "$D/obs.log"
out=$(run "$D/obs.log" "$D/*.jsonl")
if [ "$(col "$out" 1 1)" = "2026-09-17T12:01:30" ] && [ -z "$(col "$out" 1 5)" ]; then
  ok "J7 陰性: followup が無い block は 120 秒窓のまま確定する"
else ng "J7" "$out"; fi

printf '\n合計: PASS=%d NG=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

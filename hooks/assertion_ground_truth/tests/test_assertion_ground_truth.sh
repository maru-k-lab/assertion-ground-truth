#!/usr/bin/env bash
# assertion_ground_truth の実挙動テスト（陽性・陰性・ループガード・fallback）。
# cc/CLAUDE.md 実装規律4項: テスト無しのガードは placebo として扱う。
# fixture は mktemp 上に自前作成（特定 repo に依存しない）。
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dispatch.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs"
echo fixture > "$TMP/docs/real_file.md"
pass=0; fail=0

# checker 97（stop_phrase）の観測ログを全テストで fixture へ逃がす。既定は state repo
# notes/stop_phrase_observations.log であり、dispatch.py 経由のテストも 97 を走らせるため、
# ここで export しないとテスト実行が実測値を汚す（2026/08/22 実測で汚染を確認し是正）。
export AGT_STOP_PHRASE_LOG="$TMP/stop_phrase_observations.log"

# checker 97 の発火モードは 2026/08/22 に repo 既定が enabled=yes となった
# （裁定封筒 E-20990101000046-0316 Task 2）。全テストを conf の現在値に依存させないため、
# 既定を明示 OFF に固定する。発火側のテストは AGT_STOP_PHRASE_ENFORCE=yes で明示上書きし、
# conf 既定そのものの実挙動は T101 が env を外して確認する。
export AGT_STOP_PHRASE_ENFORCE=no

# checker 98（bare_search_cmd）の観測ログも全テストで fixture へ逃がす。97 と同じ理由で、
# dispatch.py 経由のテストも 98 を走らせるため、ここで export しないと実測値を汚す。
export AGT_BARE_SEARCH_LOG="$TMP/bare_search_observations.log"

# checker 94（response_date_header）の観測ログも同じ理由で逃がす。**97・98 と同型の汚染を
# 2026/09/11 に実測した**——新設の run94 は一時パスを渡していたが、dispatch.py 経由で走る
# 既存の 94 テスト（T64・T65・T70）は渡しておらず、スイート1回につき3行を
# notes/date_header_observations.log へ書き込んでいた（8回分24行を確認）。
# 個々の呼出で渡すのではなく、ここで export して経路によらず逃がす。
export AGT_DATE_HEADER_LOG="$TMP/date_header_observations.log"

# 連鎖回数の state（案C・2026/09/17 稼働）も同じ理由で逃がす。dispatch.py は
# `${TMPDIR:-/tmp}/agt_stop_phrase_chain/` へ書くため、TMPDIR を渡さないと本番の
# /tmp へテストケース名のファイルが溜まる（2026/09/17 実測・スイート1回で 41→42 に増える
# ことを対照実験で確認。完了報告 E-20990101000103-ab54 §7-3、是正の授権は
# E-20990101000104-b120 Task 2）。TMPDIR は $TMP 配下へ向けるので、終了時の trap で消える。
mkdir -p "$TMP/tmpdir"
export TMPDIR="$TMP/tmpdir"

# checker 97 の走行中判定（E-20990101000065-d9e4 Task 2）が読む transcript の fixture。
# 非同期実行の起動が無い＝IDLE の transcript を既定にする。これを渡さないと判定が
# UNKNOWN になり、fail-closed により発火系のテストがすべて陰性化する（2026/09/01 実測で
# T96・T101 がこれで落ちた）。走行中を確かめるテストは各々が別の fixture を渡す。
mk_transcript() { # $1=出力先 $2...=行（python の式）
  local out="$1"; shift
  OUTP="$out" ROWS="$*" python3 -c '
import json, os, sys
rows = {
 "human":  {"type":"user","message":{"content":"作業して"}},
 "asst":   {"type":"assistant","message":{"content":[{"type":"text","text":"報告です"}]}},
 "bg":     {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_BG","name":"Bash","input":{"run_in_background":True}}]}},
 "agent":  {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_AG","name":"Agent","input":{}}]}},
 "monitor":{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_MO","name":"Monitor","input":{}}]}},
 "fg":     {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_FG","name":"Bash","input":{}}]}},
 "done_bg":{"type":"user","message":{"content":"<task-notification>\n<task-id>bzz</task-id>\n<tool-use-id>toolu_BG</tool-use-id>\n</task-notification>"}},
 "done_ag":{"type":"user","message":{"content":"<task-notification>\n<task-id>bzz</task-id>\n<tool-use-id>toolu_AG</tool-use-id>\n</task-notification>"}},
}
with open(os.environ["OUTP"], "w", encoding="utf-8") as f:
    for k in os.environ["ROWS"].split():
        f.write(json.dumps(rows[k], ensure_ascii=False, separators=(",", ":")) + "\n")'
}
TR_IDLE="$TMP/tr_idle.jsonl";          mk_transcript "$TR_IDLE" human asst
TR_BG="$TMP/tr_running_bg.jsonl";      mk_transcript "$TR_BG" human bg asst
TR_AGENT="$TMP/tr_running_agent.jsonl"; mk_transcript "$TR_AGENT" human agent asst
TR_MON="$TMP/tr_running_mon.jsonl";    mk_transcript "$TR_MON" human monitor asst
TR_FG="$TMP/tr_fg.jsonl";              mk_transcript "$TR_FG" human fg asst
TR_DONE="$TMP/tr_done.jsonl";          mk_transcript "$TR_DONE" human bg done_bg asst
TR_PREV="$TMP/tr_prevturn.jsonl";      mk_transcript "$TR_PREV" human bg human asst
# 既定として export はしない。80・90 など他の checker も AGT_TRANSCRIPT を読むため、
# 全体に既定値を与えるとそれらの挙動を変えてしまう。97 の発火系テストにだけ渡す。

mk_input() { # $1=stop_hook_active(true/false) $2=message [$3=transcript_path]
  ACTIVE="$1" MSG="$2" CWD="$TMP" TP="${3:-}" python3 -c '
import json, os
d = {"hook_event_name": "Stop",
     "stop_hook_active": os.environ["ACTIVE"] == "true",
     "cwd": os.environ["CWD"]}
if os.environ["MSG"]:
    d["last_assistant_message"] = os.environ["MSG"]
if os.environ["TP"]:
    d["transcript_path"] = os.environ["TP"]
print(json.dumps(d, ensure_ascii=False))'
}

ok()  { echo "PASS $1"; pass=$((pass+1)); }
ng()  { echo "FAIL $1 — actual: ${2:-<empty>}"; fail=$((fail+1)); }

# T1 陽性: 実在パスを「リンク切れ」と断定 → block + negation_vs_exists
out=$(mk_input false "docs/real_file.md はリンク切れです" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'negation_vs_exists' <<<"$out"; then
  ok "T1 陽性: 実在物への否定断定を block"
else ng "T1" "$out"; fi

# T2 陰性: 通常の丁寧語「問題ありません」＋実在パス → 無音（誤爆しない）
out=$(mk_input false "docs/real_file.md を確認しました。問題ありません。" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T2 陰性: 丁寧語で誤爆しない"; else ng "T2" "$out"; fi

# T3 陰性: 正当な否定断定(実在しない物を「存在しません」) → 無音（正しい報告を妨げない）
out=$(mk_input false "docs/zzz_missing.md は存在しません" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T3 陰性: 正当な否定断定を妨げない"; else ng "T3" "$out"; fi

# T4 陰性: 否定断定なし・不在パス言及のみ → 無音（INFO は FAIL 無しでは出ない）
out=$(mk_input false "docs/zzz_missing.md を新規作成する予定です" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T4 陰性: FAIL 無しなら無音"; else ng "T4" "$out"; fi

# T5 ループガード: stop_hook_active=true → 無音（無限差し戻し防止）
out=$(mk_input true "docs/real_file.md はリンク切れです" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T5 ループガード"; else ng "T5" "$out"; fi

# T6 transcript fallback: last_assistant_message 無し → transcript から最終応答を抽出して block
fx="$TMP/transcript.jsonl"
python3 -c '
import json
print(json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": "check"}]}}))
print(json.dumps({"type": "assistant", "message": {"content": [
    {"type": "text", "text": "docs/real_file.md はリンク切れです"}]}},
    ensure_ascii=False))' > "$fx"
out=$(mk_input false "" "$fx" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out"; then ok "T6 transcript fallback"; else ng "T6" "$out"; fi

# fixture transcript は実フォーマット同様 compact JSON（separators）で生成する
mk_jsonl() { python3 -c "
import json, sys
for obj in $1:
    print(json.dumps(obj, ensure_ascii=False, separators=(',', ':')))" ; }
# --- 50_push_state_vs_origin（remote-tracking ref 突合型）---
# fixture: 実 remote 不要。refs/remotes/origin/main を update-ref で直接作る
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
sha_pushed=$(git -C "$REPO" rev-parse --short HEAD)
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
sha_unpushed=$(git -C "$REPO" rev-parse --short HEAD)

mk_input_repo() { # $1=message（cwd=$REPO 固定）
  ACTIVE=false MSG="$1" CWD="$REPO" TP="" python3 -c '
import json, os
print(json.dumps({"hook_event_name": "Stop", "stop_hook_active": False,
                  "cwd": os.environ["CWD"],
                  "last_assistant_message": os.environ["MSG"]},
                 ensure_ascii=False))'
}

# T11 陽性: push 済み SHA を「origin 未反映・push待ち」と断定 → block
out=$(mk_input_repo "コミット $sha_pushed は origin 未反映です（state-push 待ち）" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'push_state_vs_origin' <<<"$out"; then
  ok "T11 陽性: push済みSHAへの未反映断定を block"
else ng "T11" "$out"; fi

# T12 陰性: 真に未 push の SHA への「未反映」断定 → 無音（正しい報告を妨げない）
out=$(mk_input_repo "コミット $sha_unpushed は origin 未反映です（push待ち）" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T12 陰性: 真の未push報告を妨げない"; else ng "T12" "$out"; fi

# T13 陰性: cwd repo で解決しない SHA（他repoへの言及） → 無音
out=$(mk_input_repo "コミット 0123abc4def は origin 未反映です（push待ち）" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T13 陰性: 他repoのSHAで誤爆しない"; else ng "T13" "$out"; fi

# T14 陰性: 過去の状態の記述（〜だった） → 無音
out=$(mk_input_repo "コミット $sha_pushed は当時 origin 未反映だった" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T14 陰性: 過去形の記述で誤爆しない"; else ng "T14" "$out"; fi

# T15 INFO方向: 未到達 SHA への「反映済み」断定は checker 単体で INFO を出す
CHECKER="$(dirname "$HOOK")/checkers/50_push_state_vs_origin.sh"
out=$(AGT_CWD="$REPO" bash "$CHECKER" <<<"コミット $sha_unpushed は origin 反映済みです")
if grep -q $'^INFO\tpush_state_vs_origin' <<<"$out"; then
  ok "T15 INFO方向: stale可能性はINFO並記（blockしない）"
else ng "T15" "$out"; fi

# T16 陰性: 同メッセージは dispatcher 経由では無音（INFO のみでは block しない）
out=$(mk_input_repo "コミット $sha_unpushed は origin 反映済みです" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T16 陰性: INFOのみではblockしない"; else ng "T16" "$out"; fi

# --- 20 弱い否定「はありません」の精密化（2026-07-16 誤爆 incident）---

# T17 陰性: 一般名詞への丁寧な否定＋同一行の無関係な実在パス → 無音（誤爆再現の再発防止）
out=$(mk_input false "docs/real_file.md を配置しました。放置しても実害はありません。" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T17 陰性: 「実害はありません」型で誤爆しない"; else ng "T17" "$out"; fi

# T18 陽性: パス直前の「はありません」は実在断定の否定として維持 → block
out=$(mk_input false "docs/real_file.md はありません" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'negation_vs_exists' <<<"$out"; then
  ok "T18 陽性: パス直前の「はありません」被覆を維持"
else ng "T18" "$out"; fi

# T22 陰性: push完了報告（ahead 0/behind 0）＋push済みSHA → 無音（2026-07-16 誤爆の再発防止）
out=$(mk_input_repo "push を確認しました。origin/main = $sha_pushed = HEAD（ahead 0/behind 0）で全反映です" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T22 陰性: ahead 0 の push完了報告で誤爆しない"; else ng "T22" "$out"; fi

# T23 陽性: 非ゼロ ahead を伴う未push断定×push済みSHA → 引き続き block（絞り込みで被覆を失わない）
out=$(mk_input_repo "コミット $sha_pushed を含む ahead 2 が push 待ちです" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'push_state_vs_origin' <<<"$out"; then
  ok "T23 陽性: ahead 非ゼロの未push断定は引き続き block"
else ng "T23" "$out"; fi

# --- 60_dormant_repo_write（休眠repo書込・状態突合＋process-evidence型）---
# fixture: mktemp 上に休眠repoと差し替え config を自前作成（実 repo に依存しない）
DREPO="$TMP/dormant_repo"
mkdir -p "$DREPO"
git -C "$DREPO" init -q
git -C "$DREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export AGT_DORMANT_REPOS_FILE="$TMP/dormant_repos.txt"
echo "$DREPO" > "$AGT_DORMANT_REPOS_FILE"
echo stray > "$DREPO/stray_file.txt"   # dirty 化（untracked）

fx60w="$TMP/transcript_60_write.jsonl"   # 書込様証拠あり（Write tool_use に repo パス）
DREPO="$DREPO" python3 -c '
import json, os
r = os.environ["DREPO"]
print(json.dumps({"type": "tool_use", "name": "Write",
                  "input": {"file_path": r + "/data/x.json", "content": "x"}},
                 separators=(",", ":")))' > "$fx60w"   # 実transcriptはcompact形式
fx60r="$TMP/transcript_60_read.jsonl"    # 読み取りのみ（書込様トークンなし）
DREPO="$DREPO" python3 -c '
import json, os
r = os.environ["DREPO"]
print(json.dumps({"type": "tool_use", "name": "Bash",
                  "input": {"command": "git -C " + r + " status --porcelain"}},
                 separators=(",", ":")))' > "$fx60r"

# T19 陽性: 休眠repo dirty＋セッション内書込様証拠 → block + dormant_repo_write
out=$(mk_input false "作業を続けます" "$fx60w" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'dormant_repo_write' <<<"$out"; then
  ok "T19 陽性: 休眠repoへの書込を block"
else ng "T19" "$out"; fi

# T20 陰性: dirty だが書込様証拠なし（読み取りのみ） → 無音（INFO のみでは block しない）
out=$(mk_input false "作業を続けます" "$fx60r" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T20 陰性: 外因dirtyはINFO留め・blockしない"; else ng "T20" "$out"; fi

# T21 陰性: repo clean なら書込様証拠があっても無音
rm "$DREPO/stray_file.txt"
out=$(mk_input false "作業を続けます" "$fx60w" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T21 陰性: clean repo では無音"; else ng "T21" "$out"; fi
unset AGT_DORMANT_REPOS_FILE

# --- 80_fabricated_tool_result（ツール結果の地の文捏造・protocol-leak型＋process-evidence型）---
# incident: 2026-07-19 本 checker 発注セッション。直前 session で Bash/Read 空返し＋英語ナラティブ注入下、
# モデルが tab_list 結果「両タブとも AMEX:VDE」を地の文で捏造。
CHECKER80="$(dirname "$HOOK")/checkers/80_fabricated_tool_result.sh"
fx80n="$TMP/t80_notool.jsonl"
mk_jsonl '[{"type":"user","message":{"content":[{"type":"text","text":"q"}]}},
 {"type":"assistant","message":{"content":[{"type":"text","text":"a"}]}}]' > "$fx80n"
fx80t="$TMP/t80_tool.jsonl"
mk_jsonl '[{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}]' > "$fx80t"

M80_APOS='ツールを呼びました。<invoke name="tab_list"> の結果は VDE でした。'
M80_ABT='checker は `<invoke name=` 等の markup を検出します。'
M80_AFN='例:
```
<invoke name="tab_list">
```
これは fence 内なので検出対象外です。'
M80_B='結果:
```json
{"success": true, "tab_id": 3, "symbol": "AMEX:VDE"}
```
確認しました。'

# T29 陽性 FAIL A: 生 protocol markup → block
out=$(mk_input false "$M80_APOS" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'fabricated_tool_result' <<<"$out"; then
  ok "T29 陽性: 地の文の生 protocol markup を block"
else ng "T29" "$out"; fi

# T30 陰性 FAIL A: backtick 議論 → 無音（本 checker の meta 議論を守る＝自己ブロック回避）
out=$(mk_input false "$M80_ABT" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T30 陰性: backtick 議論で誤爆しない"; else ng "T30" "$out"; fi

# T31 陰性 FAIL A: fence 内 markup → 無音
out=$(mk_input false "$M80_AFN" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T31 陰性: fence 内 markup で誤爆しない"; else ng "T31" "$out"; fi

# T32 陽性 FAIL B: 結果JSON＋tool_use 無し → block
out=$(mk_input false "$M80_B" "$fx80n" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'fabricated_tool_result' <<<"$out"; then
  ok "T32 陽性: 未実行の結果JSON提示を block"
else ng "T32" "$out"; fi

# T33 陰性(INFO): 結果JSON＋tool_use 有り → dispatcher 無音（INFO のみでは block しない）
out=$(mk_input false "$M80_B" "$fx80t" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T33 陰性: tool_use 有りは INFO 止まり(block しない)"; else ng "T33" "$out"; fi

# T34 direct INFO: checker 単体では上記ケースで INFO 行を出す
out=$(AGT_TRANSCRIPT="$fx80t" bash "$CHECKER80" <<<"$M80_B")
if grep -q $'^INFO\tfabricated_tool_result' <<<"$out"; then
  ok "T34 INFO方向: tool_use 有りの結果JSONは INFO 並記"
else ng "T34" "$out"; fi

# T35 陰性 fail-open: transcript 不在 → 無音
out=$(mk_input false "$M80_B" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T35 陰性: transcript 不在は fail-open(無音)"; else ng "T35" "$out"; fi

# T36 陰性: 通常応答（固有キー/markup なし）→ 無音
out=$(mk_input false "コマンド結果は count 5 で ok でした。特に問題ありません。" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T36 陰性: 通常応答で誤爆しない"; else ng "T36" "$out"; fi


# ---- checker 94（response_date_header・incident 2026-08-06 00:47 ヘッダ時刻の未実行捏造） ----

mk_date_transcript() { # $1=out_jsonl $2=date_str_before_user $3=date_str_after_user
  local out="$1"
  { if [ -n "$2" ]; then
      B="$2" python3 -c 'import json,os; print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","content":os.environ["B"]}]}},separators=(",",":")))'
    fi
    python3 -c 'import json; print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":"次の作業をお願いします"}]}},separators=(",",":")))'
    if [ -n "$3" ]; then
      A="$3" python3 -c 'import json,os; print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","content":os.environ["A"]}]}},separators=(",",":")))'
    fi
  } > "$out"
}

# T64〜T70 は**従来検査**（冒頭の値が transcript に文字列として在るか）を測るテストである。
# 2026/09/11 に本番 conf が date_header_verify=yes になり（裁定封筒 E-20990101000078-0e18）、
# yes のときは新設の突合判定が先に結論を出して従来検査へ進まないため、conf の現在値に
# 依存させると3件とも別の理由で落ちる。97 の AGT_STOP_PHRASE_ENFORCE と同じ考え方で、
# 従来検査を測る回は明示的に no を渡す。新設判定側は T154〜T172 が測る。
# fixture が tool_use と tool_result の対を持たないのは意図どおりで、従来検査は実行の事実を
# 見ないためこれで足りる。
DHV_OFF=AGT_DATE_HEADER_VERIFY=no

# T64 陽性: ヘッダ時刻がセッションのどの実行記録にも無い（捏造） → block
mk_date_transcript "$TMP/t94_a.jsonl" "" "2026/08/06 00:39:37"
out=$(mk_input false "2026/08/06 0:47:03
Claude Code
作業を完了しました" "$TMP/t94_a.jsonl" | env $DHV_OFF python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'response_date_header' <<<"$out" && grep -q '捏造' <<<"$out"; then
  ok "T64 陽性: 未実行のヘッダ時刻を block(実 incident 値)"
else ng "T64" "$out"; fi

# T65 陰性: ヘッダ時刻（ゼロ詰めなし表示）が直近ユーザー発話以降の実行記録に在る → 無音
mk_date_transcript "$TMP/t94_b.jsonl" "" "2026/08/06 00:46:18"
out=$(mk_input false "2026/08/06 0:46:18
Claude Code
作業を完了しました" "$TMP/t94_b.jsonl" | env $DHV_OFF python3 "$HOOK")
if [ -z "$out" ]; then ok "T65 陰性: 実測値ヘッダ(ゼロ詰め差吸収)を誤爆しない"; else ng "T65" "$out"; fi

# T66 陰性: ヘッダなし応答 → 無音（不在の検出は対象外＝UNCOVERED）
out=$(mk_input false "作業を完了しました。詳細は上記のとおりです。" "$TMP/t94_b.jsonl" | env $DHV_OFF python3 "$HOOK")
if [ -z "$out" ]; then ok "T66 陰性: ヘッダ無し応答は判定しない"; else ng "T66" "$out"; fi

# T70 陽性: 値は在るが直近ユーザー発話より前のみ（過去ターン値の使い回し） → block
mk_date_transcript "$TMP/t94_c.jsonl" "2026/08/06 00:39:37" ""
out=$(mk_input false "2026/08/06 0:39:37
Claude Code
作業を完了しました" "$TMP/t94_c.jsonl" | env $DHV_OFF python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q '使い回し' <<<"$out"; then
  ok "T70 陽性: 過去ターン値の使い回しを block"
else ng "T70" "$out"; fi

# ---- checker 94: 同ターン内の date 実行結果との突合（裁定 E-20990101000076-761a Task 2）----
# 既存の検査は「冒頭の日時が transcript のどこかに文字列として在るか」しか見ない。ここで足すのは
# 「その値が同ターンで実行した date の出力に由来するか」の突合である。本番 conf は観測のみ
# （date_header_verify=no）で配置してあるため、発火側は一時 conf を指して測る。
C94="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/checkers/94_response_date_header.sh"
D94="$TMP/date_header"; mkdir -p "$D94"
printf 'date_header_verify=yes\n'         > "$D94/yes.conf"
printf 'date_header_verify=no\n'          > "$D94/no.conf"
printf '# キーなし\n'                      > "$D94/missing.conf"
printf 'date_header_verify=yes garbage\n' > "$D94/garbage.conf"

# tool_use（Bash）と tool_result を対で持つ transcript を作る。既存の mk_date_transcript は
# tool_result だけを置くため、由来の突合を測れない。
mk_date_turn() { # $1=out $2=command $3=tool_result本文
  OUT="$1" CMD="$2" RES="$3" python3 -c '
import json, os
rows = [
 {"type":"user","message":{"content":[{"type":"text","text":"作業して"}]}},
 {"type":"assistant","message":{"content":[
   {"type":"tool_use","id":"toolu_D","name":"Bash","input":{"command":os.environ["CMD"]}}]}},
 {"type":"user","message":{"content":[
   {"type":"tool_result","tool_use_id":"toolu_D","content":os.environ["RES"]}]}},
]
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")'
}
run94() { # $1=conf $2=transcript $3=本文 $4...=追加env
  local conf="$1" tp="$2" body="$3"; shift 3
  env AGT_DATE_HEADER_CONF="$D94/$conf" AGT_DATE_HEADER_LOG="$D94/obs.log" \
      AGT_TRANSCRIPT="$tp" AGT_CWD=/tmp "$@" bash "$C94" <<<"$body"
}
DH_FAIL='同ターン内の date 実行結果と一致しない'
# **新設 FAIL の不在だけを見る検査と、FAIL がひとつも出ないことを見る検査を分ける。**
# 新設 FAIL の文言だけを grep すると、後段の従来検査が出す FAIL を見落とす。合格判定の回で
# 従来検査が落としていた不具合が、この弱い検査のせいで素通りした
# （2026/09/11 実測・Codex 検証レビュー r3 BLOCKING 1）。

mk_date_turn "$D94/ok.jsonl"       "date '+%Y/%m/%d %-H:%M:%S'" "2026/09/11 9:51:32"
mk_date_turn "$D94/printf.jsonl"   "printf 'date 2026/09/11 10:00:00\n'" "date 2026/09/11 10:00:00"
mk_date_turn "$D94/compound.jsonl" "date '+%Y/%m/%d %-H:%M:%S'; cat some.log" \
                                   "2026/09/11 10:00:00
2026/09/11 22:22:22"
mk_date_turn "$D94/newline.jsonl"  "date '+%Y/%m/%d %-H:%M:%S'
printf '2026/09/11 22:22:22\n'"    "2026/09/11 10:00:00
2026/09/11 22:22:22"
mk_date_turn "$D94/iso.jsonl"      "date -Is" "2026-09-11T10:00:00+09:00"
# date を1度も実行していないターン
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"作業して"}]}}' > "$D94/nodate.jsonl"

H951=$'2026/09/11 9:51:32\nClaude\n\n報告です。'
H1000=$'2026/09/11 10:00:00\nClaude\n\n報告です。'
H2222=$'2026/09/11 22:22:22\nClaude\n\n報告です。'

# T154 陰性: 冒頭が同ターンの date 出力と一致 → FAIL がひとつも出ない
out=$(run94 yes.conf "$D94/ok.jsonl" "$H951")
if [ -z "$out" ]; then
  ok "T154 陰性: 冒頭が同ターンの date 出力と一致（完全無音）"; else ng "T154" "$out"; fi

# T155 陽性: 同ターンに date はあるが値が不一致 → FAIL
out=$(run94 yes.conf "$D94/ok.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T155 陽性: 同ターンの date 出力と不一致"; else ng "T155" "$out"; fi

# T156 陰性: 取得不能の明示は合格（裁定 2-b）。
# 冒頭に日時トークンが在るうえで「取得不能」を書いた形にする——トークンが無いと 94 は
# ヘッダ抽出の時点で無音終了し、2-b の分岐を通らないため検査にならない。
out=$(run94 yes.conf "$D94/nodate.jsonl" $'2026/09/11 10:00:00 は日時取得不能のため参考値\nClaude\n\n報告です。')
if [ -z "$out" ]; then
  ok "T156 陰性: 取得不能の明示は合格（完全無音）"; else ng "T156" "$out"; fi

# T157 陽性: 秒を持たない冒頭は合格にしない（2-a は「秒まで一致」・変更不可）
out=$(run94 yes.conf "$D94/ok.jsonl" $'2026/09/11 9:51\nClaude\n\n報告です。')
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T157 陽性: 秒を持たない冒頭を合格にしない"; else ng "T157" "$out"; fi

# T158 陽性: 同ターンに date 実行が無い → FAIL
out=$(run94 yes.conf "$D94/nodate.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T158 陽性: 同ターンに date 実行が無い"; else ng "T158" "$out"; fi

# T159 陰性: verify=no なら不一致でも FAIL を出さない（本封筒の配置値）
out=$(run94 no.conf "$D94/ok.jsonl" "$H1000")
if ! grep -q "$DH_FAIL" <<<"$out"; then
  ok "T159 陰性: verify=no では新設 FAIL を出さない"; else ng "T159" "$out"; fi

# T160 陰性: キー欠落は no と同じ（fail-closed）
out=$(run94 missing.conf "$D94/ok.jsonl" "$H1000")
if ! grep -q "$DH_FAIL" <<<"$out"; then
  ok "T160 陰性: date_header_verify 欠落は no 扱い"; else ng "T160" "$out"; fi

# T161 陰性: 値の残余を切り詰めて yes と読まない
out=$(run94 garbage.conf "$D94/ok.jsonl" "$H1000")
if ! grep -q "$DH_FAIL" <<<"$out"; then
  ok "T161 陰性: yes+残余は不正値として no 扱い"; else ng "T161" "$out"; fi

# T162 陰性: 差し戻し後の再走では新設 FAIL を出さない（ffd5 の経路）
out=$(run94 yes.conf "$D94/ok.jsonl" "$H1000" AGT_STOP_HOOK_ACTIVE=1)
if ! grep -q "$DH_FAIL" <<<"$out"; then
  ok "T162 陰性: stop_hook_active では新設 FAIL を出さない"; else ng "T162" "$out"; fi

# T163 陽性: date を実行せず printf で書いた日時は証拠にしない
out=$(run94 yes.conf "$D94/printf.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T163 陽性: printf で書いた日時は date の証拠にしない"; else ng "T163" "$out"; fi

# T164 陽性: 複合コマンド（; 区切り）は証拠にしない＝ファイル内の日時が混ざらない
out=$(run94 yes.conf "$D94/compound.jsonl" "$H2222")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T164 陽性: ; 区切りの複合コマンドは証拠にしない"; else ng "T164" "$out"; fi

# T165 陽性: 改行区切りの複合コマンドも単一呼出と見なさない
out=$(run94 yes.conf "$D94/newline.jsonl" "$H2222")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T165 陽性: 改行区切りの複合コマンドは証拠にしない"; else ng "T165" "$out"; fi

# T166 陰性: date -Is の ISO 出力を正規化して突合できる。
# **FAIL がひとつも出ないことまで見る。** 新設判定が ok でも従来検査がスラッシュ形の文字列を
# 探して落としていた経路を塞いだ回帰検査である（r3 BLOCKING 1）。
out=$(run94 yes.conf "$D94/iso.jsonl" "$H1000")
if [ -z "$out" ]; then
  ok "T166 陰性: ISO 形式の date 出力を正規化して一致（完全無音）"; else ng "T166" "$out"; fi

# T168 陰性: 08 時台の一致を不一致にしない。
# bash の `printf '%02d' 08` は八進数の不正値としてエラーになり 00 を返す。10 進として読まないと
# 08・09 時台のヘッダが別の時刻に化ける（Codex 検証レビュー r4 BLOCKING 1）。
mk_date_turn "$D94/h08.jsonl" "date '+%Y/%m/%d %-H:%M:%S'" "2026/09/11 8:00:00"
out=$(run94 yes.conf "$D94/h08.jsonl" $'2026/09/11 08:00:00\nClaude\n\n報告です。' 2>&1)
if [ -z "$out" ]; then
  ok "T168 陰性: 08 時台の一致を八進数解釈で壊さない"; else ng "T168" "$out"; fi

# T169 陽性: 書式へ日時を直書きした date は証拠にしない。
# 引数を制限しないと、現在時刻と無関係な値を date に出力させて合格できる（r4 BLOCKING 2）。
mk_date_turn "$D94/fmt.jsonl" 'date +2026/09/11\ 10:00:00' "2026/09/11 10:00:00"
out=$(run94 yes.conf "$D94/fmt.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T169 陽性: 書式へ日時を直書きした date は証拠にしない"; else ng "T169" "$out"; fi

# T170 陽性: -d で日時を指定した date も証拠にしない
mk_date_turn "$D94/dopt.jsonl" "date -d '2026-09-11 10:00:00' '+%Y/%m/%d %-H:%M:%S'" \
                               "2026/09/11 10:00:00"
out=$(run94 yes.conf "$D94/dopt.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T170 陽性: date -d で指定した日時は証拠にしない"; else ng "T170" "$out"; fi

# T171 陽性: 書式にシェル展開を含む date は証拠にしない。
# shlex は展開を行わないため `+$(cat …)` は「数字を含まない書式」に見えるが、実際の bash は
# ファイル内容へ展開して任意の日時リテラルを date へ渡せる（Codex 検証レビュー r5 BLOCKING 1）。
mk_date_turn "$D94/expand.jsonl" 'date "+$(cat /tmp/stamp.txt)"' "2026/09/11 10:00:00"
out=$(run94 yes.conf "$D94/expand.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out"; then
  ok "T171 陽性: 書式のシェル展開を証拠にしない"; else ng "T171" "$out"; fi

# T172 陰性: 二重引用符の通常の書式は従来どおり証拠として通る（T171 の非退行）
mk_date_turn "$D94/dq.jsonl" 'date "+%Y/%m/%d %-H:%M:%S"' "2026/09/11 10:00:00"
out=$(run94 yes.conf "$D94/dq.jsonl" "$H1000")
if [ -z "$out" ]; then
  ok "T172 陰性: 二重引用符の通常書式は証拠として通る"; else ng "T172" "$out"; fi

# T173 陽性: verify=yes では従来検査の文言が出ない（判定はすべて新設側で決まる）。
# 新設の分岐は ok / exempt / mismatch / no_date / no_seconds の5値すべてを拾って exit するため、
# yes のとき従来検査（捏造の疑い・使い回しの疑い）へは到達しない。この事実を固定する
# ——到達不能になったことに気づかないまま従来検査を直す事故を防ぐため（2026/09/11）。
out=$(run94 yes.conf "$D94/nodate.jsonl" "$H1000")
if grep -q "$DH_FAIL" <<<"$out" \
   && ! grep -q '捏造の疑い' <<<"$out" && ! grep -q '使い回しの疑い' <<<"$out"; then
  ok "T173 陽性: verify=yes では従来検査の文言が出ない"; else ng "T173" "$out"; fi

# T167 陰性: 観測ログの列が仕様どおり6列（時刻・cwd・判定・T_head・T_date・ずれ秒数）
if [ "$(awk -F'\t' 'END{print NF}' "$D94/obs.log")" = 6 ] \
   && grep -qP '\tmismatch\t' "$D94/obs.log" && grep -qP '\tok\t' "$D94/obs.log"; then
  ok "T167 陰性: 観測ログが6列で判定値を記録する"
else ng "T167" "$(tail -3 "$D94/obs.log")"; fi

# ---- checker 96（presented_reference・owner 指示 2026/08/09・incident: rclone コマンド未表示参照） ----

# T71 陽性: 「上記」でコマンド参照 × fence なし（実 incident 文） → block
out=$(mk_input false "残り: 上記 rclone コマンドの実行（owner）をお願いします。" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'presented_reference' <<<"$out"; then
  ok "T71 陽性: fence なしの上記コマンド参照を block(実 incident 文)"
else ng "T71" "$out"; fi

# T72 陰性: 同じ参照文 ＋ 同一応答内に fence あり → 無音
out=$(mk_input false '上記 rclone コマンドの実行をお願いします。
```
rclone copyto "/tmp/a.md" "gdrive:exchange/inbox/ai/a.md"
```' | python3 "$HOOK")
if [ -z "$out" ]; then ok "T72 陰性: fence 同伴の上記参照を誤爆しない"; else ng "T72" "$out"; fi

# T73 陽性: 「提示済」主張 × fence なし → block
out=$(mk_input false "rclone コマンドは 21:22 頃に提示済みです。" | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'presented_reference' <<<"$out"; then
  ok "T73 陽性: fence なしの提示済主張を block"
else ng "T73" "$out"; fi

# T74 陰性: 「提示済」主張 ＋ 再掲 fence あり → 無音
out=$(mk_input false '提示済みですが、コマンドを再掲します。
```
rclone copyto "/tmp/a.md" "gdrive:exchange/inbox/ai/a.md"
```' | python3 "$HOOK")
if [ -z "$out" ]; then ok "T74 陰性: 再掲 fence 同伴の提示済主張を誤爆しない"; else ng "T74" "$out"; fi

# T75 陰性: メタ議論（トークンを backtick で囲む） → 無音（80 と同方針）
out=$(mk_input false '`上記`と`提示済`で checker を作りました。コマンドの実行テストは完了しています。' | python3 "$HOOK")
if [ -z "$out" ]; then ok "T75 陰性: backtick 内トークンのメタ議論を誤爆しない"; else ng "T75" "$out"; fi

# T76 陰性: 振り返り文（負ガード: 誤|訂正|指摘|反論） → 無音
out=$(mk_input false "私は上記コマンドの実行を促す際に、誤って提示済みと主張しました。" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T76 陰性: 振り返り文を誤爆しない"; else ng "T76" "$out"; fi

# T77 陰性: 対象語なしの「上記」（通常の照応） → 無音
out=$(mk_input false "作業は上記のとおり完了しました。実行結果も確認済みです。" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T77 陰性: 対象語なしの上記参照を誤爆しない"; else ng "T77" "$out"; fi

# T78 陽性: 散文中の三連バッククォート言及は fence ではない（検証レビュー BLOCKING 1 の実測入力） → block
out=$(mk_input false '上記 rclone コマンドの実行をお願いします。説明文に ``` を使っています。' | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'presented_reference' <<<"$out"; then
  ok "T78 陽性: 散文中の\`\`\`言及による迂回を block"
else ng "T78" "$out"; fi

# T79 陽性: 未クローズ fence（開始行のみ）は実体と数えない → block
out=$(mk_input false '上記 rclone コマンドの実行をお願いします。
```' | python3 "$HOOK")
if grep -q '"decision": "block"' <<<"$out" && grep -q 'presented_reference' <<<"$out"; then
  ok "T79 陽性: 未クローズ fence を実体と数えない"
else ng "T79" "$out"; fi

# --- 97_stop_phrase（停止句の計数・INFO 限定）---
# この checker は FAIL を出さないため dispatch.py 経由では観測できない
# （dispatch.py:67 の `if not fails: return`）。ここでは checker を直接呼んで判定する。
# 観測経路そのものは裁定封筒 E-20990101000041-4e9e の報告で .ai へ差し戻し中。
C97="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/checkers/97_stop_phrase.sh"

# 観測ログはヘッダで fixture へ逃がしてある。ここでは 97 節ぶんを初期化するだけにする。
: > "$AGT_STOP_PHRASE_LOG"

# T80 陽性: 停止句あり・承認元アンカーあり
out=$(printf '封筒 E-20990101000041-4e9e の実装です。進めてよいでしょうか。\n' | bash "$C97")
if grep -q 'approval_anchor=yes' <<<"$out" && grep -q '検出句=進めてよいでしょうか' <<<"$out"; then
  ok "T80 陽性: 停止句あり・アンカーあり"; else ng "T80" "$out"; fi

# T81 陽性: 停止句あり・アンカーなし
out=$(printf '実装しました。よろしいでしょうか。\n' | bash "$C97")
if grep -q 'approval_anchor=no' <<<"$out"; then
  ok "T81 陽性: 停止句あり・アンカーなし"; else ng "T81" "$out"; fi

# T82 陰性: 停止句なし → 無音
out=$(printf '封筒 E-20990101000041-4e9e を実装しテストも通しました。\n' | bash "$C97")
if [ -z "$out" ]; then ok "T82 陰性: 停止句なしは無音"; else ng "T82" "$out"; fi

# T83 陰性: コードブロック内の停止句は数えない（手順書の引用を誤爆しない）
out=$(printf '次の文面を使います。\n```\nよろしいでしょうか。\n```\n実装は完了しています。\n' | bash "$C97")
if [ -z "$out" ]; then ok "T83 陰性: fence 内の停止句を数えない"; else ng "T83" "$out"; fi

# T84 陰性: 前方にトークン境界が無い文字列はアンカーでない
out=$(printf 'XE-20990101000041-4e9e です。よろしいでしょうか。\n' | bash "$C97")
if grep -q 'approval_anchor=no' <<<"$out"; then
  ok "T84 陰性: XE- 接頭はアンカーと数えない"; else ng "T84" "$out"; fi

# T85 陰性: 後方にトークン境界が無い文字列はアンカーでない
out=$(printf 'E-20990101000041-4e9ea です。よろしいでしょうか。\n' | bash "$C97")
if grep -q 'approval_anchor=no' <<<"$out"; then
  ok "T85 陰性: 4hex 超過はアンカーと数えない"; else ng "T85" "$out"; fi

# T86 陽性: 全角括弧で囲まれた ISSUE はアンカーと数える
out=$(printf '封筒（E-20990101000041-4e9e）です。よろしいでしょうか。\n' | bash "$C97")
if grep -q 'approval_anchor=yes' <<<"$out"; then
  ok "T86 陽性: 全角括弧内の ISSUE を拾う"; else ng "T86" "$out"; fi

# T87 陰性: FAIL/WARN を出さない（封筒の絶対条件）
out=$(printf 'E-20990101000041-4e9e 進めてよいでしょうか。指示をください。\n' | bash "$C97")
if ! grep -qE '^(FAIL|WARN)' <<<"$out"; then
  ok "T87 陰性: FAIL/WARN を出さない"; else ng "T87" "$out"; fi

# T88 陰性: 空入力は無音・rc=0（fail-open）
out=$(printf '' | bash "$C97"); rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  ok "T88 陰性: 空入力は無音・rc=0"; else ng "T88" "out=$out rc=$rc"; fi

# ---- 97_stop_phrase の宣言形層・観測ログ・発火モード（E-20990101000044-fe34 Task C/D/E）----

# T89 陽性: 宣言形が最終散文段落にあれば tier=declare で拾う
out=$(printf '封筒 E-20990101000041-4e9e の作業です。\n\n次は経路を調べます。続けます。\n' | bash "$C97")
if grep -q 'tier=declare' <<<"$out" && grep -q '検出句=続けます,調べます' <<<"$out"; then
  ok "T89 陽性: 最終段落の宣言形を tier=declare で拾う"; else ng "T89" "$out"; fi

# T90 陰性: 宣言形が本文途中にあり最終段落に無ければ数えない（正当な叙述の誤爆回避）
out=$(printf 'E-20990101000041-4e9e です。まず調べます、と書いてから実行しました。\n\n結果は次のとおりで、すべて完了しました。\n' | bash "$C97")
if [ -z "$out" ]; then ok "T90 陰性: 本文途中の宣言形を数えない"; else ng "T90" "$out"; fi

# T91 陽性: 質問形と宣言形が同時に出れば tier=ask,declare
out=$(printf 'E-20990101000041-4e9e です。よろしいでしょうか。\n\n実装します。\n' | bash "$C97")
if grep -q 'tier=ask,declare' <<<"$out"; then
  ok "T91 陽性: 両層の同時検出は tier=ask,declare"; else ng "T91" "$out"; fi

# T92 陽性(Task C): 検出時に観測ログへ1行追記される
: > "$AGT_STOP_PHRASE_LOG"
printf 'E-20990101000041-4e9e です。指示をください。\n' | bash "$C97" >/dev/null
n=$(wc -l < "$AGT_STOP_PHRASE_LOG")
cols=$(awk -F'\t' 'NR==1{print NF}' "$AGT_STOP_PHRASE_LOG")
if [ "$n" = "1" ] && [ "$cols" = "5" ]; then
  ok "T92 陽性: 観測ログへ TSV 5列を1行追記"; else ng "T92" "行数=$n 列数=$cols"; fi

# T93 陰性(Task C): 停止句が無ければ追記しない
: > "$AGT_STOP_PHRASE_LOG"
printf 'E-20990101000041-4e9e を実装しテストも通しました。\n' | bash "$C97" >/dev/null
if [ ! -s "$AGT_STOP_PHRASE_LOG" ]; then
  ok "T93 陰性: 停止句なしでは観測ログへ追記しない"; else ng "T93" "$(cat "$AGT_STOP_PHRASE_LOG")"; fi

# T94 陰性(Task C): 追記先が書けなくても stdout は不変・rc=0（fail-open）
mkdir -p "$TMP/obs_blocked"
out=$(AGT_STOP_PHRASE_LOG="$TMP/obs_blocked" bash "$C97" <<< 'E-20990101000041-4e9e です。指示をください。'); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'approval_anchor=yes' <<<"$out"; then
  ok "T94 陰性: 観測ログ書込不能でも stdout 不変・rc=0"; else ng "T94" "rc=$rc out=$out"; fi

# T95 陰性(Task E): フラグ OFF では発火条件を満たしても FAIL を出さない
# 2026/08/22 に repo 既定の conf が enabled=yes となったため、OFF はヘッダの
# AGT_STOP_PHRASE_ENFORCE=no（明示上書き）で与える。検証内容は従来と同じである。
out=$(printf 'E-20990101000041-4e9e の作業です。\n\n続けます。\n' | bash "$C97")
if ! grep -qE '^(FAIL|WARN)' <<<"$out"; then
  ok "T95 陰性: フラグ OFF では FAIL を出さない"; else ng "T95" "$out"; fi

# T96 陽性(Task E): フラグ ON・アンカーあり・マーカーなし → FAIL
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'E-20990101000041-4e9e の作業です。\n\n続けます。')
if grep -q '^FAIL' <<<"$out" && grep -q '停止条件=N' <<<"$out"; then
  ok "T96 陽性: フラグ ON で発火条件成立なら FAIL"; else ng "T96" "$out"; fi

# T97 陰性(Task E): フラグ ON でも正当停止マーカーがあれば FAIL を出さない
out=$(AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'E-20990101000041-4e9e の作業です。外部送信は人間の手番のため停止条件=1 で止めます。\n\n指示をください。')
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T97 陰性: 正当停止マーカーがあれば発火しない"; else ng "T97" "$out"; fi

# T98 陰性(Task E): フラグ ON でもアンカーが無ければ FAIL を出さない
# 2026/09/10 補足（E-20990101000075-5d39 Task 1-a）: この不変条件は require_anchor=yes の
# ときのものになった。本番 conf は観測目的で no にしてあるため、条件を明示した一時 conf を
# 指して測る。指さないと、非同期判定が UNKNOWN で落ちているだけの合格になり、
# 関門2 を測ったことにならない。
RA_CONF_DIR="$TMP/require_anchor"; mkdir -p "$RA_CONF_DIR"
printf 'enabled=yes\nrequire_anchor=yes\n'        > "$RA_CONF_DIR/yes.conf"
printf 'enabled=yes\nrequire_anchor=no\n'         > "$RA_CONF_DIR/no.conf"
printf 'enabled=yes\n'                            > "$RA_CONF_DIR/missing.conf"
printf 'enabled=yes\nrequire_anchor=no garbage\n' > "$RA_CONF_DIR/garbage.conf"
printf 'enabled=yes\nrequire_anchor=no # 観測目的\n' > "$RA_CONF_DIR/comment.conf"
out=$(AGT_STOP_PHRASE_CONF="$RA_CONF_DIR/yes.conf" AGT_TRANSCRIPT="$TR_IDLE" \
      AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'実装しました。\n\n続けます。')
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T98 陰性: require_anchor=yes ではアンカーなしで発火しない"; else ng "T98" "$out"; fi

# T98b 陽性: require_anchor=no ならアンカーが無くても発火する（今回広げた窓そのもの）
out=$(AGT_STOP_PHRASE_CONF="$RA_CONF_DIR/no.conf" AGT_TRANSCRIPT="$TR_IDLE" \
      AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'実装しました。\n\n続けます。')
if grep -q '^FAIL' <<<"$out" && grep -q 'アンカーの無い応答で停止句を検出' <<<"$out"; then
  ok "T98b 陽性: require_anchor=no はアンカーなしでも発火し、承認済みと断定しない"
else ng "T98b" "$out"; fi

# T98c 陰性: 拡大窓でも正当停止マーカー 停止条件=6 があれば発火しない
out=$(AGT_STOP_PHRASE_CONF="$RA_CONF_DIR/no.conf" AGT_TRANSCRIPT="$TR_IDLE" \
      AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< $'承認待ちのため止まります。停止条件=6\n\n実装しました。\n\n続けます。')
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T98c 陰性: 拡大窓でも 停止条件=6 があれば発火しない"; else ng "T98c" "$out"; fi

# T98d 陰性: キーが無ければ yes 扱い（fail-closed の向き＝窓を広げない）
out=$(AGT_STOP_PHRASE_CONF="$RA_CONF_DIR/missing.conf" AGT_TRANSCRIPT="$TR_IDLE" \
      AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'実装しました。\n\n続けます。')
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T98d 陰性: require_anchor 欠落は yes 扱い"; else ng "T98d" "$out"; fi

# T98e 陰性: 値の残余を切り詰めて no と読まない（2026/09/10 Codex 検証レビュー BLOCKING 2）
out=$(AGT_STOP_PHRASE_CONF="$RA_CONF_DIR/garbage.conf" AGT_TRANSCRIPT="$TR_IDLE" \
      AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'実装しました。\n\n続けます。')
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T98e 陰性: require_anchor=no+残余 は不正値として yes 扱い"; else ng "T98e" "$out"; fi

# T98f 陽性: 行末コメントは値に含めない
out=$(AGT_STOP_PHRASE_CONF="$RA_CONF_DIR/comment.conf" AGT_TRANSCRIPT="$TR_IDLE" \
      AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'実装しました。\n\n続けます。')
if grep -q '^FAIL' <<<"$out"; then
  ok "T98f 陽性: require_anchor=no+行末コメント は no 扱い"; else ng "T98f" "$out"; fi

# T99 陰性(Task E): ループガード（stop_hook_active 相当）が真なら発火しない
out=$(AGT_STOP_HOOK_ACTIVE=true AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" <<< $'E-20990101000041-4e9e の作業です。\n\n続けます。')
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T99 陰性: ループガードが真なら発火しない"; else ng "T99" "$out"; fi

# T100 陰性(Task E): conf の値が yes 以外なら OFF（fail-closed）
CONF_FIX="$TMP/enforce_bad.conf"
printf 'enabled=maybe\n' > "$CONF_FIX"
out=$(AGT_STOP_PHRASE_ENFORCE= bash -c '
  d=$(mktemp -d); cp "$1"/*.txt "$d"/; cp "$2" "$d"/stop_phrase_enforce.conf
  cp "$1/97_stop_phrase.sh" "$d"/
  printf "E-20990101000041-4e9e の作業です。\n\n続けます。\n" | bash "$d/97_stop_phrase.sh"
  rm -rf "$d"' _ "$(dirname "$C97")" "$CONF_FIX")
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T100 陰性: conf が yes 以外なら発火しない"; else ng "T100" "$out"; fi

# T101 陽性(6c74 Task 2): repo 既定の conf が有効化されていること。
# ヘッダの明示 OFF を env -u で外し、conf の現在値だけで判定させる。これが落ちるときは
# stop_phrase_enforce.conf が enabled=yes でない（＝裁定 E-20990101000046-0316 の
# 有効化が失われている）。
out=$(env -u AGT_STOP_PHRASE_ENFORCE AGT_TRANSCRIPT="$TR_IDLE" bash "$C97" <<< $'E-20990101000041-4e9e の作業です。\n\n続けます。')
if grep -q '^FAIL' <<<"$out"; then
  ok "T101 陽性: repo 既定の conf で発火する"; else ng "T101" "$out"; fi

# T102 陰性(c8b4 Task 1): 検算スクリプト stop_phrase_verify_sample.sh が壊れていないこと。
# 本番の検算は全 transcript を使うため重い。ここは fixture 3件だけを与えて「スクリプト自体が
# 壊れていないか」を見る。実 transcript は使わない。
#
# 経緯: 同スクリプトは 2026/08/22 の tier 追加（E-20990101000044-fe34）で壊れていたが、
# tests/ からも checkers/ からも呼ばれない位置にあるため、誰も走らせず1巡気づかれなかった
# （E-20990101000047-17dd §8）。この試験はその穴を塞ぐためにある。
#
# 検証対象のパスは AGT_VERIFY_SAMPLE で差し替えられる。壊れ検出能力そのものを実走で示すため
# （c8b4 Task 1 の受入条件）であり、既定は repo の現物である。
# **落とし穴**: AGT_VERIFY_SAMPLE で壊れ版のコピーを検証するとき、コピー先に checkers/ への
# 参照（symlink 等）が無いと、verify_sample.sh が checker を自分の位置から解決できず全件が
# 「無音＝nostop」に落ちる。壊し方ではなく checker 不在が原因で不一致になるため、壊れ検出の
# 証明にならない（2026/08/23 に実際に踏んだ。裁定 E-20990101000050-d954 Task 3）。
VS="${AGT_VERIFY_SAMPLE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stop_phrase_verify_sample.sh}"
VS_DIR="$TMP/vs"; mkdir -p "$VS_DIR"
# 1件目: アンカーあり・宣言形が最終段落 → checker は拾う（質問形のみの判定では拾わない）
printf 'E-20990101000041-4e9e の作業です。\n\n続けます。\n' > "$VS_DIR/s0000.txt"
# 2件目: アンカーあり・停止句なし → checker は無音
printf 'E-20990101000041-4e9e の作業を完了しました。\n'     > "$VS_DIR/s0001.txt"
# 3件目: アンカーなし・質問形 → checker は拾い approval_anchor=no
printf '実装しました。よろしいでしょうか。\n'               > "$VS_DIR/s0002.txt"
# 列は expect.tsv の仕様どおり ファイル・質問形のみの判定・アンカー・checker が拾うか
{ printf '%s\tnostop\tyes\tstop\n'   "$VS_DIR/s0000.txt"
  printf '%s\tnostop\tyes\tnostop\n' "$VS_DIR/s0001.txt"
  printf '%s\tstop\tno\tstop\n'      "$VS_DIR/s0002.txt"; } > "$VS_DIR/expect.tsv"
out=$(STOP_PHRASE_SAMPLE_DIR="$VS_DIR" bash "$VS" 2>&1)
if grep -q '検算: 一致 3 / 不一致 0' <<<"$out"; then
  ok "T102 陰性: 検算スクリプトが fixture 3件で一致する"
else ng "T102" "$out"; fi

# --- 98_bare_search_cmd（command 前置なしの検索コマンドの観測・INFO 限定）----------------
# 条文の出所は cc/CLAUDE.md「応答・報告様式」節（P-8 承認・裁定 E-20990101000050-d954 Task 1）。
# この checker は FAIL を出さないため dispatch.py 経由では観測できない。97 と同じく直接呼ぶ。
C98="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/checkers/98_bare_search_cmd.sh"

# T103 陽性: code block 内の裸 grep を拾う
out=$(printf '結果です。\n```\ngrep -rl foo .\n```\n' | bash "$C98")
if grep -q 'bare-search-cmd' <<<"$out" && grep -q '件数=1' <<<"$out"; then
  ok "T103 陽性: code block 内の裸 grep を拾う"; else ng "T103" "$out"; fi

# T104 陰性: command 前置は拾わない
out=$(printf '結果です。\n```\ncommand grep -rl foo .\n```\n' | bash "$C98")
if [ -z "$out" ]; then ok "T104 陰性: command 前置は拾わない"; else ng "T104" "$out"; fi

# T105 陰性: 散文中の言及は拾わない（実行行だけが対象）
out=$(printf '実測は grep で行い、find も使いました。\n' | bash "$C98")
if [ -z "$out" ]; then ok "T105 陰性: 散文中の言及は拾わない"; else ng "T105" "$out"; fi

# T106 陽性: パイプ直後・複数行をそれぞれ数える
out=$(printf '```\ncat x | grep -q foo\nfind . -name y\n```\n' | bash "$C98")
if grep -q '件数=2' <<<"$out"; then
  ok "T106 陽性: パイプ直後と複数行を数える"; else ng "T106" "$out"; fi

# T107 陰性: FAIL/WARN を出さない（封筒 E-20990101000050-d954 §2-2 の絶対条件）
out=$(printf '```\ngrep -r foo .\n```\n' | bash "$C98")
if ! grep -qE '^(FAIL|WARN)' <<<"$out"; then
  ok "T107 陰性: FAIL/WARN を出さない"; else ng "T107" "$out"; fi

# T108 陽性: 観測ログへ TSV 4列を1行追記する
: > "$AGT_BARE_SEARCH_LOG"
printf '```\ngrep -r foo .\n```\n' | bash "$C98" >/dev/null
n=$(wc -l < "$AGT_BARE_SEARCH_LOG")
cols=$(awk -F'\t' 'NR==1{print NF}' "$AGT_BARE_SEARCH_LOG")
if [ "$n" = "1" ] && [ "$cols" = "4" ]; then
  ok "T108 陽性: 観測ログへ TSV 4列を1行追記"; else ng "T108" "行数=$n 列数=$cols"; fi

# T109 陰性: 検出が無ければ観測ログへ追記しない
: > "$AGT_BARE_SEARCH_LOG"
printf '```\ncommand grep -r foo .\n```\n' | bash "$C98" >/dev/null
if [ ! -s "$AGT_BARE_SEARCH_LOG" ]; then
  ok "T109 陰性: 検出なしでは追記しない"; else ng "T109" "$(cat "$AGT_BARE_SEARCH_LOG")"; fi

# T110 陰性: 観測ログが書けなくても stdout 不変・rc=0・stderr へ漏らさない（fail-open）
mkdir -p "$TMP/bare_blocked"
out=$(AGT_BARE_SEARCH_LOG="$TMP/bare_blocked" bash "$C98" <<< $'```\ngrep -r foo .\n```' 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '件数=1' <<<"$out" && ! grep -q 'Is a directory' <<<"$out"; then
  ok "T110 陰性: 観測ログ書込不能でも stdout 不変・rc=0"; else ng "T110" "rc=$rc out=$out"; fi

# T111 陰性: 空入力は無音・rc=0（fail-open）
out=$(printf '' | bash "$C98"); rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  ok "T111 陰性: 空入力は無音・rc=0"; else ng "T111" "out=$out rc=$rc"; fi

# ---- 再走時の観測（欠測型ア・裁定 E-20990101000057-600b Task 1）--------------
# stop_hook_active=true の再走でも 97 の観測ログだけは残す。差し戻しは出さない。
STOPMSG='アンカー E-20990101000041-4e9e の作業です。

Task 0 のアンカー検査から着手します。'

# T112 陽性: 再走でも観測ログへ1行残る（差し戻し直後の再応答を測れる）
: > "$AGT_STOP_PHRASE_LOG"
out=$(mk_input true "$STOPMSG" | python3 "$HOOK"); rc=$?
n=$(wc -l < "$AGT_STOP_PHRASE_LOG")
if [ "$n" = "1" ] && [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  ok "T112 陽性: 再走でも観測ログへ1行追記・無音"
else ng "T112" "行数=$n out=$out rc=$rc"; fi

# T113 陰性: 再走経路では enforce ON でも差し戻さない（受入条件②）
: > "$AGT_STOP_PHRASE_LOG"
out=$(mk_input true "$STOPMSG" | AGT_STOP_PHRASE_ENFORCE=yes python3 "$HOOK")
if [ -z "$out" ]; then ok "T113 陰性: 再走経路では enforce ON でも差し戻さない"
else ng "T113" "$out"; fi

# T114 陰性: 再走では 97 以外の checker を走らせない（10_path_exists の FAIL 材料を与えても無音）
out=$(mk_input true "docs/zzz_missing.md は存在しません" | python3 "$HOOK")
if [ -z "$out" ]; then ok "T114 陰性: 再走では 97 以外を走らせない"; else ng "T114" "$out"; fi


# ---- E-20990101000065-d9e4（語彙38語化・走行中除外・future 観測層）--------------
A942="E-20990101000065-d9e4"

# T115 陽性(Task 1): 追加30語のうち実測頻度の高い語で発火する
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。投函が済んだら台帳へ記帳します。")
if grep -q '^FAIL' <<<"$out" && grep -q '検出句=記帳します' <<<"$out"; then
  ok "T115 陽性: 追加語（記帳します）で発火する"; else ng "T115" "$out"; fi

# T116 陰性(Task 2): 背景 Bash が走行中なら発火しない
out=$(AGT_TRANSCRIPT="$TR_BG" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if ! grep -q '^FAIL' <<<"$out" && grep -q '^INFO' <<<"$out"; then
  ok "T116 陰性: 背景 Bash 走行中は発火しない"; else ng "T116" "$out"; fi

# T117 陰性(Task 2): サブエージェントが走行中なら発火しない
out=$(AGT_TRANSCRIPT="$TR_AGENT" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T117 陰性: サブエージェント走行中は発火しない"; else ng "T117" "$out"; fi

# T118 陰性(Task 2): Monitor が走行中なら発火しない
out=$(AGT_TRANSCRIPT="$TR_MON" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T118 陰性: Monitor 走行中は発火しない"; else ng "T118" "$out"; fi

# T119 陽性(Task 2): 完了通知が来ていれば走行中ではない → 発火する
out=$(AGT_TRANSCRIPT="$TR_DONE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if grep -q '^FAIL' <<<"$out"; then
  ok "T119 陽性: 完了通知後は発火する"; else ng "T119" "$out"; fi

# T120 陽性(Task 2): 前のターンで起動したものを走行中と数えない。
# ここを取り違えると、セッション開始時の persistent Monitor（agmsg 監視）で全ターンが
# 除外され、発火が全滅する（2026/09/01 実測で確認した落とし穴）。
out=$(AGT_TRANSCRIPT="$TR_PREV" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if grep -q '^FAIL' <<<"$out"; then
  ok "T120 陽性: 前ターンの起動は走行中に数えない"; else ng "T120" "$out"; fi

# T121 陽性(Task 2): 前景 Bash は非同期ではないので走行中に数えない
out=$(AGT_TRANSCRIPT="$TR_FG" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if grep -q '^FAIL' <<<"$out"; then
  ok "T121 陽性: 前景 Bash は走行中に数えない"; else ng "T121" "$out"; fi

# T122 陰性(Task 2・fail-closed): transcript が読めなければ発火しない
out=$(AGT_TRANSCRIPT="$TMP/does_not_exist.jsonl" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。続けます。")
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T122 陰性: transcript 不明では発火しない（fail-closed）"; else ng "T122" "$out"; fi

# T123 陰性(Task 2・fail-closed): 判定スクリプトが無ければ発火しない。
# 部分配置で発火が静かに死ぬことを防ぐための明示テストである。
out=$(bash -c '
  d=$(mktemp -d); cp "$1"/*.txt "$1"/*.conf "$d"/; cp "$1/97_stop_phrase.sh" "$d"/
  AGT_TRANSCRIPT="$2" AGT_STOP_PHRASE_ENFORCE=yes bash "$d/97_stop_phrase.sh" <<< "$3"
  rm -rf "$d"' _ "$(dirname "$C97")" "$TR_IDLE" "$A942 の作業です。続けます。")
if ! grep -q '^FAIL' <<<"$out"; then
  ok "T123 陰性: async_inflight.py 不在では発火しない（fail-closed）"; else ng "T123" "$out"; fi

# T124 陰性(Task 3): future 層だけでは発火しない。観測ログには tier=future で残る。
: > "$AGT_STOP_PHRASE_LOG"
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。これから確認する予定です。")
n=$(grep -c 'future' "$AGT_STOP_PHRASE_LOG")
if ! grep -q '^FAIL' <<<"$out" && grep -q 'tier=future' <<<"$out" && [ "$n" -eq 1 ]; then
  ok "T124 陰性: future 単独では発火せず観測ログに残る"; else ng "T124" "n=$n out=$out"; fi

# T125 陽性(Task 3): future と declare が同時に立つと発火する。
# ただし FAIL の tier に future を混ぜない（発火理由に観測専用層を書かない）。
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A942 の作業です。これから作業を進めます。")
if grep -q '^FAIL' <<<"$out" && grep -q 'tier=declare' <<<"$out" \
   && ! grep '^FAIL' <<<"$out" | grep -q 'future'; then
  ok "T125 陽性: future＋declare は発火し FAIL の tier に future を含まない"
else ng "T125" "$out"; fi

# T126 陰性(Task 3): future 層は疑問・依頼で終わる文を対象にしない
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=no bash "$C97" \
      <<< "$A942 の件です。これから始めてよろしいでしょうか。")
if ! grep -q 'future' <<<"$out"; then
  ok "T126 陰性: future 層は疑問文を数えない"; else ng "T126" "$out"; fi

# T127 陽性(Task 1): 宣言形リストが39語であること（語数の退行検知）
# 38 → 39 は commit 9368dea「declare 層へ『当て直します』を追加（38→39語）」で増えた分。
# そのとき本行の期待値が据え置かれ、以後この検査だけが失敗し続けていた（2026/09/17 実測・
# 完了報告 E-20990101000103-ab54 §7-2、是正の授権は E-20990101000104-b120 Task 1）。
n=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$(dirname "$C97")/stop_phrases_declare.txt")
if [ "$n" -eq 39 ]; then ok "T127 陽性: 宣言形リストは39語"; else ng "T127" "語数=$n"; fi

# T128 陽性(Task 3): future リストが6語であること
n=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$(dirname "$C97")/stop_phrases_future.txt")
if [ "$n" -eq 6 ]; then ok "T128 陽性: future リストは6語"; else ng "T128" "語数=$n"; fi


# ---- E-20990101000068-f695（negative 観測層）--------------------------------
A2988="E-20990101000068-f695"

# T129 陰性: 否定リストに当たらない丁寧形を negative として記録し、FAIL は出さない。
# 38語に無い動詞（お出しします）で確かめる。これが拾えることが本層の存在理由である。
: > "$AGT_STOP_PHRASE_LOG"
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A2988 の件です。Codex の確認が返り次第、投函コマンドをお出しします。")
n=$(grep -c 'negative' "$AGT_STOP_PHRASE_LOG")
if ! grep -q '^FAIL' <<<"$out" && grep -q 'tier=negative' <<<"$out" \
   && grep -q '検出句=お出しします' <<<"$out" && [ "$n" -eq 1 ]; then
  ok "T129 陰性: negative は38語外の動詞を記録し発火しない"; else ng "T129" "n=$n out=$out"; fi

# T130 陰性: 否定リストの語で終わる末尾文は記録しない（待機＝正当停止の型）
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A2988 の件です。裁定が返るまで待機します。")
if [ -z "$out" ]; then ok "T130 陰性: 否定リストの語は記録しない"; else ng "T130" "$out"; fi

# T131 陰性: 疑問・依頼で終わる末尾文は negative に数えない（ask 層と二重に数えない）
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A2988 の件です。どちらにするか教えてください。")
if ! grep -q 'negative' <<<"$out"; then
  ok "T131 陰性: negative は疑問・依頼を数えない"; else ng "T131" "$out"; fi

# T132 陰性: 丁寧形で終わらない末尾文は数えない
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A2988 の件です。未push は5本です。")
if [ -z "$out" ]; then ok "T132 陰性: 丁寧形で終わらなければ数えない"; else ng "T132" "$out"; fi

# T133 陽性: declare と同時に立っても発火し、FAIL の tier に negative を書かない
out=$(AGT_TRANSCRIPT="$TR_IDLE" AGT_STOP_PHRASE_ENFORCE=yes bash "$C97" \
      <<< "$A2988 の件です。次の巡を出します。")
if grep -q '^FAIL' <<<"$out" && grep -q 'tier=declare,negative' <<<"$out" \
   && ! grep '^FAIL' <<<"$out" | grep -qE 'negative|future'; then
  ok "T133 陽性: declare＋negative は発火し FAIL の tier に観測層を含まない"
else ng "T133" "$out"; fi

# T134 陽性: 否定リストが45語であること（設計封筒 cadb §2 案αで実測した構成）
n=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$(dirname "$C97")/stop_phrases_negative.txt")
if [ "$n" -eq 45 ]; then ok "T134 陽性: 否定リストは45語"; else ng "T134" "語数=$n"; fi

# T135 陰性: 否定リストが読めなくても発火系は変わらない（fail-open。観測層は落ちてよい）
out=$(bash -c '
  d=$(mktemp -d); cp "$1"/*.txt "$1"/*.conf "$1"/*.py "$d"/; cp "$1/97_stop_phrase.sh" "$d"/
  rm -f "$d/stop_phrases_negative.txt"
  AGT_STOP_PHRASE_LOG="$d/obs.log" AGT_TRANSCRIPT="$2" AGT_STOP_PHRASE_ENFORCE=yes \
    bash "$d/97_stop_phrase.sh" <<< "$3"
  rm -rf "$d"' _ "$(dirname "$C97")" "$TR_IDLE" "$A2988 の件です。作業を進めます。")
if grep -q '^FAIL' <<<"$out" && ! grep -q 'negative' <<<"$out"; then
  ok "T135 陰性: 否定リスト不在でも発火系は不変"; else ng "T135" "$out"; fi

echo "== $pass PASS / $fail FAIL =="
[ "$fail" -eq 0 ]

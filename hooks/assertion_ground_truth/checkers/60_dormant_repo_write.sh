#!/usr/bin/env bash
# FAIL checker (状態突合型・行為検出): 休眠保存が裁定された repo の worktree が dirty で、
# かつ本セッションに当該 repo への書込様 tool_use 証拠がある場合に差し戻す。
# 断定文の真偽ではなく「休眠repoに書いた」行為そのものを検出する（assertion 型からの拡張。
# 50 と同じく実状態(git)を ground truth に使い、40 と同じく transcript を process-evidence に使う）。
#
# 対応 incident: 2026-07-16 E-20990101000003-acda セッション。project-b は
# 「分離継続・休眠保存・実装アクションなし」(2026/07/14 裁定 E-20990101000001-4f71・owner承認)
# 確定済みなのに、CC が実装先として handoff を組み、非git manifest を data/ 配下へ作成した
# （owner 指摘で停止・撤去）。checker 化指示: owner 2026-07-16 同セッション発話
# 「lessons と memory じゃなくてcheckerがよいのでは」「assertion_ground_truthのchekerね」。
#
# 対象 repo 一覧: dormant_repos.txt（1行1絶対パス・# コメント可。休眠指定の出所は
# 同ファイルのコメントに併記）。テスト用に AGT_DORMANT_REPOS_FILE で差し替え可。
# 判定:
#   dirty かつ セッション内書込様証拠あり → FAIL（撤去または外因証拠の提示を要求）
#   dirty のみ（書込様証拠なし）          → INFO（外因の可能性・単独では block しない）
# 既知の限界: 書込様トークンはヒューリスティック（読み取り専用 Bash に矢印等が含まれると
# 過剰証拠になりうるが、FAIL は「実際に dirty」が前提のため実害は差し戻し1回の確認要求に留まる）。
set -u
cat >/dev/null   # メッセージ本文は使わない（状態突合型）
TP="${AGT_TRANSCRIPT:-}"
CFG="${AGT_DORMANT_REPOS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dormant_repos.txt}"
[ -f "$CFG" ] || exit 0

write_evidence() { # $1=repo 絶対パス。transcript に書込様 tool_use があるか
  local repo="$1"
  { [ -n "$TP" ] && [ -f "$TP" ]; } || return 1
  # (a) 直接書込ツール（Write/Edit/NotebookEdit）の入力に repo 配下パス
  grep '"type":"tool_use"' "$TP" 2>/dev/null \
    | grep -E '"name":[[:space:]]*"(Write|Edit|NotebookEdit)"' \
    | grep -q -- "$repo" && return 0
  # (b) Bash 実行行に repo パス＋書込様トークン
  grep '"type":"tool_use"' "$TP" 2>/dev/null \
    | grep -E '"name":[[:space:]]*"Bash"' | grep -- "$repo" \
    | grep -qE 'mkdir |rm -|mv |cp |tee |>>|touch |sed -i|git (add|commit|mv|rm|checkout|restore|reset|clean|stash)' \
    && return 0
  return 1
}

grep -vE '^[[:space:]]*(#|$)' "$CFG" | while IFS= read -r repo; do
  { [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; } || continue
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | head -5)
  [ -n "$dirty" ] || continue
  summary=$(printf '%s' "$dirty" | tr '\n\t' '  ' | cut -c1-160)
  if write_evidence "$repo"; then
    printf 'FAIL\tdormant_repo_write\t休眠保存repo %s の worktree が dirty で、本セッションに書込様ツール操作の証拠がある（休眠裁定違反の疑い）: %s — セッション由来なら撤去し、外因なら証拠を示して報告すること\n' "$repo" "$summary"
  else
    printf 'INFO\tdormant_repo_write\t休眠保存repo %s が dirty（セッション内書込様証拠なし・外因の可能性）: %s\n' "$repo" "$summary"
  fi
done
exit 0

#!/usr/bin/env bash
# FAIL checker: commit SHA を伴う push/origin 反映状態の断定を、ローカル remote-tracking
# ref（origin照会の二段方式の正本。owner の push/fetch で更新される）と突合する。
# 対応 incident: 2026-07-15 22:25 受理確認応答で f062409〜fe8ac9c を「origin 未反映・
# state-push 待ち」と断定（21:43 測定の使い回し・実際は push 済みで origin/main=fe8ac9c）。
#
# - FAIL: 「未push/未反映/push待ち」断定行の SHA が origin 既定ブランチの祖先
#   （ref は前進しかしないため「ref上で反映済み」は push 済みの確定証拠）
# - INFO: 「push済/反映済」断定行の SHA が origin 既定ブランチに未到達
#   （ref が stale の可能性（別クローンからの push 等）があるため block しない）
# - cwd repo で解決しない SHA はスキップ（他 repo への言及の誤爆防止）
# - 過去の状態の記述（だった/でした/当時/時点）は対象外
set -u
MSG=$(cat)
G() { git -C "${AGT_CWD:-.}" "$@"; }
G rev-parse --git-dir >/dev/null 2>&1 || exit 0

ORIGIN=""
for ref in "$(G symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" origin/main origin/master; do
  [ -n "$ref" ] || continue
  if G rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
    ORIGIN="$ref"
    break
  fi
done
[ -n "$ORIGIN" ] || exit 0   # remote-tracking ref が無い repo では判定不能 (fail-open)

# ahead は非ゼロ件数を伴う場合のみ未push断定とみなす（「ahead 0/behind 0」は
# push 完了報告であり対象外 — 2026-07-16 誤爆 incident: push確認応答の ahead 0 行の
# SHA 3件を未push断定と誤分類して block）
UNPUSHED='未push|未プッシュ|未反映|push待ち|ahead[= ][1-9]|push.{0,40}(実行待ち|反映待ち)'
PUSHED='push済|プッシュ済|反映済|origin.{0,10}(到達|反映)'
PAST='だった|でした|当時|時点'

grep -E "$UNPUSHED" <<<"$MSG" | grep -vE "$PAST" \
| grep -oE '\b[0-9a-f]{7,40}\b' | sort -u | head -8 \
| while IFS= read -r sha; do
    G cat-file -e "$sha^{commit}" 2>/dev/null || continue
    if G merge-base --is-ancestor "$sha" "$ORIGIN" 2>/dev/null; then
      printf 'FAIL\tpush_state_vs_origin\t%s を未push/未反映と断定しているが %s の祖先として反映済み（remote-tracking ref 実測。ref は前進のみ＝push済みの確定証拠）\n' "$sha" "$ORIGIN"
    fi
  done

grep -E "$PUSHED" <<<"$MSG" | grep -vE "$PAST" \
| grep -oE '\b[0-9a-f]{7,40}\b' | sort -u | head -8 \
| while IFS= read -r sha; do
    G cat-file -e "$sha^{commit}" 2>/dev/null || continue
    if ! G merge-base --is-ancestor "$sha" "$ORIGIN" 2>/dev/null; then
      printf 'INFO\tpush_state_vs_origin\t%s を反映済みと断定しているがローカル %s には未到達（ref が stale の可能性・要 fetch 確認）\n' "$sha" "$ORIGIN"
    fi
  done
exit 0

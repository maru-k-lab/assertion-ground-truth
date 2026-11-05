#!/usr/bin/env bash
# INFO checker: 応答が commit として引用する hash 様トークンが repo で解決するか並記。
# NOT-A-COMMIT はセッションID断片等の可能性もあるため INFO 止まり（block しない）。
set -u
MSG=$(cat)
git -C "${AGT_CWD:-.}" rev-parse --git-dir >/dev/null 2>&1 || exit 0
grep -E 'commit|コミット|SHA|rev' <<<"$MSG" \
| grep -oE '\b[0-9a-f]{7,40}\b' \
| sort -u | head -10 \
| while IFS= read -r h; do
    if git -C "${AGT_CWD:-.}" cat-file -e "$h^{commit}" 2>/dev/null; then
      s=RESOLVES
    else
      s=NOT-A-COMMIT
    fi
    printf 'INFO\tgit_sha_cited\t%s %s\n' "$s" "$h"
  done
exit 0

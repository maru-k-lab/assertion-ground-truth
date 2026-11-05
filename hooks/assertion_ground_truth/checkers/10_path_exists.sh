#!/usr/bin/env bash
# INFO checker: 応答中のパス様トークンの実在/不在を機械並記する (ground truth 並記)。
# 単独では block しない。FAIL 発生時に突合材料として reason へ添付される。
set -u
sed -E 's#https?://[^ )>"]+##g' \
| grep -oE '(~/|/)?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+/?' \
| grep -vE '^[0-9/.:-]+/?$' \
| sort -u | head -30 \
| while IFS= read -r tok; do
    p=$tok
    case $p in
      "~/"*) p="$HOME/${p#\~/}" ;;
      /*) : ;;
      *) p="${AGT_CWD:-.}/$p" ;;
    esac
    if [ -e "$p" ]; then s=EXISTS; else s=MISSING; fi
    printf 'INFO\tpath_exists\t%s %s\n' "$s" "$tok"
  done
exit 0

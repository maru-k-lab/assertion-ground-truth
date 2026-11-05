#!/usr/bin/env python3
"""過去 transcript へ冒頭時刻の突合規則を当てる（裁定封筒 E-20990101000076-761a Task 3）。

`date_header_verify=yes` にしたときに何件が差し戻されるかを、有効化の前に測るための道具。
判定・ターンの切り出し・date の同定・正規化は checkers/date_header_evidence.py と
94_response_date_header.sh に揃えてある。ずれたら結果が checker の実挙動を表さなくなるため、
どちらかを直したらここも直すこと。

判定するのは各ターンの最終 assistant テキスト応答のうち、冒頭3行に日時ヘッダを持つものだけ。
ヘッダが無い応答は checker が無音で返す（ヘッダ不在の検出は 94 の対象外）ため、対象外と数える。

使い方:
  python3 date_header_backtest.py [開始日 YYYY-MM-DD]     # 既定 2026-08-28
"""
import os as _os
_AGT_ROOT = _os.environ.get("AGT_STATE_ROOT") or _os.path.abspath(_os.path.join(_os.path.dirname(__file__), "..", ".."))
_CLAUDE_PROJECTS = _os.path.join(_os.path.expanduser("~"), ".claude", "projects", "*", "*.jsonl")
import collections
import datetime as dt
import glob
import json
import re
import shlex
import sys

# 94 の冒頭ヘッダ抽出と同じ形。
HEAD_STAMP = re.compile(r"20[0-9]{2}/[0-9]{2}/[0-9]{2} [0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?")
# date_header_evidence.py と同じ形。
SLASH = re.compile(
    r"(20[0-9]{2})/([0-9]{2})/([0-9]{2})[ T]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?")
ISO = re.compile(
    r"(20[0-9]{2})-([0-9]{2})-([0-9]{2})[ T]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?")
# 引数の許可制は date_header_evidence.py と同一にする。ずれるとバックテストが checker の
# 実挙動を表さなくなる（2026/09/11 Codex 検証レビュー r4 BLOCKING 1・2）。
SAFE_DATE_OPTS = {"-u", "--utc", "--universal", "-R", "--rfc-email",
                  "--iso-8601", "--rfc-3339"}
SAFE_DATE_I = re.compile(r"-I[a-z]*")
DIGIT = re.compile(r"[0-9]")
# シェル展開は shlex では見抜けない。`date "+$(…)"` が任意の日時リテラルを出せるため、
# 分割前の生文字列で弾く（r5 BLOCKING 1）。
EXPANSION = re.compile(r"[$`]")


def is_current_time_date(cmd):
    if EXPANSION.search(cmd):
        return False
    try:
        toks = shlex.split(cmd)
    except ValueError:
        return False
    if toks and toks[0] == "command":
        toks = toks[1:]
    if not toks or toks[0] != "date":
        return False
    fmt_seen = False
    for tok in toks[1:]:
        if tok.startswith("+"):
            if fmt_seen or DIGIT.search(tok):
                return False
            fmt_seen = True
            continue
        if SAFE_DATE_I.fullmatch(tok) or tok.split("=", 1)[0] in SAFE_DATE_OPTS:
            continue
        return False
    return True


PROJECTS = _CLAUDE_PROJECTS


def blocks(rec):
    c = (rec.get("message") or {}).get("content")
    return c if isinstance(c, list) else []


def is_raw_user(rec):
    if rec.get("type") != "user":
        return False
    return not any(isinstance(b, dict) and b.get("type") == "tool_result"
                   for b in blocks(rec))


def result_text(b):
    c = b.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c
                         if isinstance(x, dict) and x.get("type") == "text")
    return ""


def canonical(text):
    out = []
    for pat in (SLASH, ISO):
        for m in pat.finditer(text):
            y, mo, d, h, mi, s = m.groups()
            key = "%s-%s-%s %02d:%s" % (y, mo, d, int(h), mi)
            if s is not None:
                key += ":" + s
            if key not in out:
                out.append(key)
    return out


def head_key(stamp):
    d, t = stamp.split(" ", 1)
    h, r = t.split(":", 1)
    return "%s %02d:%s" % (d.replace("/", "-"), int(h), r)


def epoch(key):
    if key.count(":") < 2:
        key += ":00"
    try:
        return dt.datetime.strptime(key, "%Y-%m-%d %H:%M:%S").timestamp()
    except ValueError:
        return None


def main():
    since = sys.argv[1] if len(sys.argv) > 1 else "2026-08-28"
    tally = collections.Counter()
    by_cwd = collections.defaultdict(collections.Counter)
    diffs, samples = [], []

    for path in sorted(glob.glob(PROJECTS)):
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        recs = []
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") in ("user", "assistant") and not rec.get("isSidechain"):
                    recs.append(rec)

        bounds = [i for i, r in enumerate(recs) if is_raw_user(r)] + [len(recs)]
        for bi in range(len(bounds) - 1):
            turn = recs[bounds[bi]:bounds[bi + 1]]
            if not turn or (turn[0].get("timestamp") or "")[:10] < since:
                continue

            wanted, cands, final, cwd = set(), [], "", ""
            for r in turn:
                for b in blocks(r):
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use" and b.get("name") == "Bash":
                        cmd = ((b.get("input") or {}).get("command") or "").strip()
                        if is_current_time_date(cmd):
                            wanted.add(b.get("id"))
                    elif b.get("type") == "tool_result" and b.get("tool_use_id") in wanted:
                        cands += canonical(result_text(b))
                if r.get("type") == "assistant":
                    t = "\n".join(b.get("text", "") for b in blocks(r)
                                  if isinstance(b, dict) and b.get("type") == "text")
                    if t.strip():
                        final, cwd = t, r.get("cwd") or ""

            if not final:
                continue
            head3 = "\n".join(final.splitlines()[:3])
            m = HEAD_STAMP.search(head3)
            if not m:
                tally["ヘッダなし(対象外)"] += 1
                continue
            t_head = m.group(0)
            if "取得不能" in head3:
                tally["取得不能の明示(合格)"] += 1
                by_cwd[cwd]["exempt"] += 1
                continue
            if t_head.count(":") != 2:
                tally["不合格: 冒頭に秒が無い"] += 1
                by_cwd[cwd]["no_seconds"] += 1
                continue

            key = head_key(t_head)
            if not cands:
                tally["不合格: date 実行なし"] += 1
                by_cwd[cwd]["no_date"] += 1
                continue
            if key in cands:
                tally["合格"] += 1
                by_cwd[cwd]["ok"] += 1
                continue
            best, bd = None, None
            for c in cands:
                a, b2 = epoch(key), epoch(c)
                if a is None or b2 is None:
                    continue
                if bd is None or abs(a - b2) < bd:
                    bd, best = abs(a - b2), c
            tally["不合格: 不一致"] += 1
            by_cwd[cwd]["mismatch"] += 1
            if bd is not None:
                diffs.append(bd)
                samples.append((turn[0].get("timestamp") or "", cwd, t_head, best, bd))

    print("判定対象期間: %s 以降\n" % since)
    keys = ("合格", "不合格: 不一致", "不合格: date 実行なし", "不合格: 冒頭に秒が無い",
            "取得不能の明示(合格)", "ヘッダなし(対象外)")
    print("%-26s %6s" % ("区分", "件数"))
    for k in keys:
        print("%-26s %6d" % (k, tally[k]))

    judged = sum(tally[k] for k in keys[:-1])
    ng = tally["不合格: 不一致"] + tally["不合格: date 実行なし"] + tally["不合格: 冒頭に秒が無い"]
    print("\n判定した応答: %d 件（うち不合格 %d 件・%.1f%%）"
          % (judged, ng, 100.0 * ng / judged if judged else 0))

    print("\nずれ秒数の分布（不一致 %d 件）" % len(diffs))
    band = collections.Counter()
    for d in diffs:
        band["60秒以内" if d <= 60 else "10分以内" if d <= 600 else "10分超"] += 1
    for k in ("60秒以内", "10分以内", "10分超"):
        print("  %-10s %4d" % (k, band[k]))

    print("\ncwd 別")
    print("  %-42s %5s %5s %5s %5s" % ("cwd", "合格", "不一致", "date無", "秒無"))
    for cwd, c in sorted(by_cwd.items(), key=lambda x: -sum(x[1].values())):
        print("  %-42s %5d %5d %5d %5d"
              % (cwd[:42], c["ok"], c["mismatch"], c["no_date"], c["no_seconds"]))

    if samples:
        print("\nずれの大きい不一致（上位8件）")
        for ts, cwd, th, td, d in sorted(samples, key=lambda s: -s[4])[:8]:
            print("  %s  冒頭=%s  date=%s  ずれ=%d秒  %s"
                  % (ts[:19], th, td, int(d), cwd[:34]))


if __name__ == "__main__":
    main()

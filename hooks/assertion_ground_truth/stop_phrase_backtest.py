#!/usr/bin/env python3
"""発火モードのバックテスト（封筒 E-20990101000044-fe34 §4 Task E）。

97_stop_phrase.sh の発火条件を過去 transcript へ適用し、would-fire 件数を実測する。
発火は**有効化しない**（checkers/stop_phrase_enforce.conf は enabled=no のまま）。

発火条件（checker と同一・stop_phrase_enforce.conf が enabled=yes のときの分岐）:
  1. 停止句を検出（ask 層＝散文全体／declare 層＝最終散文段落）
  2. approval_anchor=yes
  3. 正当停止マーカー 停止条件=<1-5> が応答全体に無い
  4. ループガード（dispatcher 側で成立。過去 transcript には適用しない）

分母は stop_phrase_baseline.py と同じ「ターンの最終 assistant 応答」で、カットオフも同じ
`--until 2026-08-19T15:52:06Z`（案2 を入れた commit d7141da のコミット時刻）を既定にする。
"""
import os as _os
_AGT_ROOT = _os.environ.get("AGT_STATE_ROOT") or _os.path.abspath(_os.path.join(_os.path.dirname(__file__), "..", ".."))
_CLAUDE_PROJECTS = _os.path.join(_os.path.expanduser("~"), ".claude", "projects", "*", "*.jsonl")
import json, os, re, glob, sys, collections, random, hashlib

BASE = _os.path.join(_AGT_ROOT, "hooks/assertion_ground_truth/checkers")


def load(name):
    out = []
    with open(os.path.join(BASE, name), encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("#"):
                continue
            out.append(ln)
    return out


PH_ASK = load("stop_phrases.txt")
PH_DECLARE = load("stop_phrases_declare.txt")

ANCHOR = re.compile(r"(^|[^0-9A-Za-z])E-[0-9]{14}-[0-9a-fA-F]{4}([^0-9A-Za-z]|$)", re.M)
MARKER = re.compile(r"停止条件[ \t]*=[ \t]*[1-5]")
FENCE = re.compile(r"^[ \t]*```")
INLINE = re.compile(r"`[^`]*`")


def prose(msg):
    out, f = [], False
    for line in msg.split("\n"):
        if FENCE.match(line):
            f = not f
            continue
        if not f:
            out.append(line)
    return INLINE.sub("", "\n".join(out))


def tail_para(pr):
    """最終散文段落＝空行区切りで見た最後の非空ブロック（checker の TAIL と同一）。"""
    lines = pr.split("\n")
    end = -1
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip():
            end = i
            break
    if end < 0:
        return ""
    start = 0
    for i in range(end, -1, -1):
        if not lines[i].strip():
            start = i + 1
            break
    return "\n".join(lines[start:end + 1])


# harness の自動注入の見分け（裁定封筒 E-20990101000046-0316 §3-2）。
# stop_phrase_baseline.py と同一の定義を使う。
AUTO_PREFIXES = ("<task-notification>", "Stop hook feedback")


def human_text(obj):
    c = (obj.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def is_auto_injection(obj):
    return human_text(obj).lstrip().startswith(AUTO_PREFIXES)


def is_human_input(obj, exclude_auto=False):
    if obj.get("type") != "user":
        return False
    c = (obj.get("message") or {}).get("content")
    if isinstance(c, str):
        pass
    elif isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return False
    else:
        return False
    if exclude_auto and is_auto_injection(obj):
        return False
    return True


def assistant_text(obj):
    if obj.get("type") != "assistant":
        return None
    c = (obj.get("message") or {}).get("content")
    if not isinstance(c, list):
        return None
    parts = [b.get("text", "") for b in c
             if isinstance(b, dict) and b.get("type") == "text"]
    t = "\n".join(p for p in parts if p)
    return t or None


def iter_final(path, exclude_auto=False):
    pend, pts = None, None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if is_human_input(obj, exclude_auto) and pend:
                yield pts, pend
                pend, pts = None, None
                continue
            t = assistant_text(obj)
            if t:
                pend, pts = t, obj.get("timestamp", "")
    if pend:
        yield pts, pend


def main():
    until = "2026-08-19T15:52:06Z"
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        if argv[i] == "--until" and i + 1 < len(argv):
            until = argv[i + 1]; i += 2
        else:
            i += 1

    # 自動注入の除外あり／なしの両方を集計する（裁定封筒 E-20990101000046-0316 §3-2）。
    # 既定＝除外なしが主指標（6b53 §6-5 との連続性）。重複排除は参考値として併記する。
    cases = collections.defaultdict(list)
    for exclude_auto in (False, True):
        scanned = skipped = no_ts = 0
        records = []
        for p in sorted(glob.glob(_CLAUDE_PROJECTS)):
            scanned += 1
            for ts, text in iter_final(p, exclude_auto):
                if not ts:
                    no_ts += 1
                    continue
                if ts >= until:
                    skipped += 1
                    continue
                pr = prose(text)
                tl = tail_para(pr)
                a_hits = [ph for ph in PH_ASK if ph in pr]
                d_hits = [ph for ph in PH_DECLARE if ph in tl] if tl else []
                anchor = bool(ANCHOR.search(text))
                marker = bool(MARKER.search(text))
                dkey = (ts, hashlib.sha1(text.encode("utf-8")).hexdigest())
                records.append((p, ts, text, a_hits, d_hits, anchor, marker, dkey))

        def tally(records, dedup):
            total = anchor_total = dropped = 0
            fire = collections.Counter()
            hit_only = collections.Counter()
            marker_saved = collections.Counter()
            seen = set()
            for p, ts, text, a_hits, d_hits, anchor, marker, dkey in records:
                if dedup:
                    if dkey in seen:
                        dropped += 1
                        continue
                    seen.add(dkey)
                total += 1
                if anchor:
                    anchor_total += 1
                for combo, hits in (("ask", a_hits), ("declare", d_hits),
                                    ("both", a_hits + d_hits)):
                    if not hits:
                        continue
                    hit_only[combo] += 1
                    if not anchor:
                        continue
                    if marker:
                        marker_saved[combo] += 1
                        continue
                    fire[combo] += 1
                    if not dedup and not exclude_auto:
                        cases[combo].append((p, ts, hits, text))
            return total, anchor_total, fire, hit_only, marker_saved, dropped

        mode = ("自動注入 除外なし（主・従来定義）" if not exclude_auto
                else "自動注入 除外あり（参考）")
        for dedup in (False, True):
            total, anchor_total, fire, hit_only, marker_saved, dropped = \
                tally(records, dedup)
            label = mode + ("・重複排除あり（参考）" if dedup else "")
            print("== 入力スナップショット: %s ==" % label)
            print("  走査ファイル数: %d" % scanned)
            print("  カットオフ(--until): %s" % until)
            print("  カットオフ以降で除外: %d" % skipped)
            print("  timestamp 欠落で除外: %d" % no_ts)
            print("  母集団（最終 assistant 応答）: %d" % total)
            print("  うちアンカーあり窓: %d" % anchor_total)
            if dedup:
                print("  重複排除で落ちた応答: %d 件（timestamp ＋ 本文 sha1 が一致するもの）"
                      % dropped)
            print()
            print("== would-fire（発火条件をすべて満たす応答）: %s ==" % label)
            print("%-9s %8s %10s %12s %10s" %
                  ("層", "停止句検出", "would-fire", "アンカー窓率", "全体率"))
            for combo in ("declare", "ask", "both"):
                f = fire[combo]
                print("%-9s %8d %10d %11.2f%% %9.2f%%" %
                      (combo, hit_only[combo], f,
                       (f / anchor_total * 100) if anchor_total else 0.0,
                       (f / total * 100) if total else 0.0))
            print("  正当停止マーカーで免れた件数: declare %d / ask %d / both %d"
                  % (marker_saved["declare"], marker_saved["ask"],
                     marker_saved["both"]))
            print()

    # 人手分類用のサンプル。無作為抽出は固定 seed で再現可能にする。
    outdir = os.environ.get("STOP_PHRASE_BACKTEST_DIR", "/tmp/stop_phrase_backtest")
    os.makedirs(outdir, exist_ok=True)
    rnd = random.Random(20260822)
    picked = cases["both"]
    n = min(20, len(picked))
    sample = rnd.sample(picked, n) if len(picked) > n else list(picked)
    with open(os.path.join(outdir, "index.tsv"), "w", encoding="utf-8") as idx:
        for i, (p, ts, hits, text) in enumerate(sample):
            fn = os.path.join(outdir, "c%02d.txt" % i)
            with open(fn, "w", encoding="utf-8") as fh:
                fh.write(text)
            idx.write("%s\t%s\t%s\t%s\n" % (fn, ts, ",".join(hits), p))
    print("\n人手分類用サンプル %d 件（both 層の would-fire から seed=20260822 で無作為抽出）を %s へ書き出した"
          % (n, outdir))


main()

#!/usr/bin/env python3
"""案3 ベースライン計数（封筒 E-20990101000041-4e9e Task 2）。

97_stop_phrase.sh と同一の判定を python で再実装し、全 transcript の「ターンの最終
assistant 応答」に適用する。checker を1応答ずつ起動すると現実的な時間で終わらないための
措置であり、同一性は無作為抽出したサンプルへ実 checker を適用して検算する
（検算は verify_sample.sh 側）。

checker と揃えた判定:
  - fenced code block（行頭空白＋```）を行トグルで除去し、inline code（`...`）を除去した
    散文に対して停止句を部分一致で探す。
  - 承認元アンカーは応答全体（コードブロックを含む）に対し E-\\d{14}-[0-9a-fA-F]{4} で探す。
"""
import os as _os
_AGT_ROOT = _os.environ.get("AGT_STATE_ROOT") or _os.path.abspath(_os.path.join(_os.path.dirname(__file__), "..", ".."))
_CLAUDE_PROJECTS = _os.path.join(_os.path.expanduser("~"), ".claude", "projects", "*", "*.jsonl")
import json, os, re, glob, sys, collections, hashlib

PHRASES = []
with open(_os.path.join(_AGT_ROOT, "hooks/assertion_ground_truth/checkers/stop_phrases.txt"),
          encoding="utf-8") as fh:
    for ln in fh:
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#"):
            continue
        PHRASES.append(ln)

# 宣言形（tier=declare）。4象限の集計には使わない——20f9 のベースラインは質問形のみで測って
# おり、定義を変えると連続性が切れるためである。ここで読むのは、実 checker との判定一致を
# 検算するサンプル（verify_sample.sh が読む expect.tsv）に「checker が実際に何を拾うか」を
# 書き出すためだけである（2026/08/22・tier 2層化に伴う検算の是正）。
PHRASES_DECLARE = []
with open(_os.path.join(_AGT_ROOT, "hooks/assertion_ground_truth/checkers/") +
          "stop_phrases_declare.txt", encoding="utf-8") as fh:
    for ln in fh:
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#"):
            continue
        PHRASES_DECLARE.append(ln)

ANCHOR = re.compile(r"(^|[^0-9A-Za-z])E-[0-9]{14}-[0-9a-fA-F]{4}([^0-9A-Za-z]|$)",
                    re.M)
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
# 20f9 §3-2 の定義は type=="user" で tool_result を含まないものを人間入力と数えるが、
# 背景タスクの完了通知（<task-notification>）と Stop hook の差し戻し（Stop hook feedback）も
# この形で流れてくる。どちらも人間は打鍵していない。E-20990101000045-6dcb §9-2 の実測では
# 人手分類20件のうち7件の「直後の人間発話」がこれであった。
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
    # --until <ISO8601> でカットオフを与える。timestamp がそれ以降の応答は数えない。
    # 走行中の transcript を glob するため、カットオフが無いと分母が実行のたびに増えて
    # ベースラインが再現できない（2026/08/20 Codex 検証レビュー BLOCKING 2 対応）。
    # 案2 適用前のベースラインは --until 2026-08-19T15:52:06Z（案2 を入れた commit d7141da の
    # コミット時刻）で測る。transcript は追記のみのため、この時刻以前の内容は後から変わらない。
    since = ""
    until = ""
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        if argv[i] == "--until" and i + 1 < len(argv):
            until = argv[i + 1]; i += 2
        elif argv[i] == "--since" and i + 1 < len(argv):
            since = argv[i + 1]; i += 2
        else:
            since = argv[i]; i += 1
    # 自動注入の除外あり／なしの両方を集計する（裁定封筒 E-20990101000046-0316 §3-2）。
    # 既定＝除外なしが主指標である（20f9 のベースラインとの連続性を保つため）。
    # 重複排除（timestamp ＋ 本文 hash）は参考値として併記する（6b53 §10-2〈2〉対応。
    # セッションの分岐・再開で同一応答が複数 transcript に残るため）。
    results = {}
    samples = []
    for exclude_auto in (False, True):
        scanned_files = 0
        skipped_after_cutoff = 0
        no_timestamp = 0
        records = []          # (ts, anchor, hits, dedup_key)
        for p in sorted(glob.glob(_CLAUDE_PROJECTS)):
            scanned_files += 1
            for ts, text in iter_final(p, exclude_auto):
                if since and ts and ts < since:
                    continue
                if until:
                    if not ts:
                        # timestamp が取れない応答はカットオフの内外を判定できない。
                        # 分母を動かさないため、判定不能は除外側へ倒す（fail-closed）。
                        no_timestamp += 1
                        continue
                    if ts >= until:
                        skipped_after_cutoff += 1
                        continue
                pr = prose(text)
                hits = [ph for ph in PHRASES if ph in pr]
                anchor = bool(ANCHOR.search(text))
                dkey = (ts, hashlib.sha1(text.encode("utf-8")).hexdigest())
                records.append((ts, anchor, hits, dkey))
                if not exclude_auto and len(samples) < 400:
                    tl = tail_para(pr)
                    d_hits = [ph for ph in PHRASES_DECLARE if ph in tl] if tl else []
                    samples.append((p, ts, text, bool(hits), anchor,
                                    bool(hits or d_hits)))
        results[exclude_auto] = (scanned_files, skipped_after_cutoff,
                                 no_timestamp, records)

    def aggregate(records, dedup):
        quad = collections.Counter()
        per_phrase = collections.Counter()
        per_month = collections.Counter()
        seen = set()
        dropped = 0
        for ts, anchor, hits, dkey in records:
            if dedup:
                if dkey in seen:
                    dropped += 1
                    continue
                seen.add(dkey)
            quad[("anchor" if anchor else "noanchor",
                  "stop" if hits else "nostop")] += 1
            for h in hits:
                per_phrase[h] += 1
            if ts:
                per_month[(ts[:7], "stop" if hits else "nostop")] += 1
        return quad, per_phrase, per_month, dropped

    def show_quad(label, quad):
        print("== 4象限（応答数）: %s ==" % label)
        for a in ("anchor", "noanchor"):
            tot = quad[(a, "stop")] + quad[(a, "nostop")]
            rate = (quad[(a, "stop")] / tot * 100) if tot else 0.0
            print("%-9s 停止句あり=%5d  なし=%6d  計=%6d  停止率=%.2f%%"
                  % (a, quad[(a, "stop")], quad[(a, "nostop")], tot, rate))
        gtot = sum(quad.values())
        gstop = quad[("anchor", "stop")] + quad[("noanchor", "stop")]
        print("全体      停止句あり=%5d  計=%6d  停止率=%.2f%%"
              % (gstop, gtot, (gstop / gtot * 100) if gtot else 0.0))

    for exclude_auto in (False, True):
        scanned_files, skipped, no_ts, records = results[exclude_auto]
        mode = ("自動注入 除外なし（主・従来定義）" if not exclude_auto
                else "自動注入 除外あり（参考）")
        print("== 入力スナップショット: %s ==" % mode)
        print("  走査ファイル数: %d" % scanned_files)
        print("  カットオフ(--until): %s" % (until or "なし"))
        print("  カットオフ以降で除外: %d" % skipped)
        print("  timestamp 欠落で除外: %d" % no_ts)
        print()
        quad, per_phrase, per_month, _ = aggregate(records, dedup=False)
        show_quad(mode, quad)
        quad_d, _, _, dropped = aggregate(records, dedup=True)
        print()
        show_quad(mode + "・重複排除あり（参考）", quad_d)
        print("  重複排除で落ちた応答: %d 件（timestamp ＋ 本文 sha1 が一致するもの）" % dropped)
        if not exclude_auto:
            print("\n== 句別ヒット数（重複計上）==")
            for ph, n in per_phrase.most_common():
                print("  %-20s %d" % (ph, n))
            print("\n== 月別 ==")
            months = sorted(set(m for m, _ in per_month))
            for m in months:
                s = per_month[(m, "stop")]; ns = per_month[(m, "nostop")]
                t = s + ns
                print("  %s  停止句あり=%4d / 計=%5d  (%.2f%%)"
                      % (m, s, t, (s / t * 100) if t else 0))
        print()
    # 検算用サンプルを書き出す
    # 検算用サンプルの出力先。環境変数で差し替えられる（既定は /tmp 配下の固定パス）。
    outdir = os.environ.get("STOP_PHRASE_SAMPLE_DIR", "/tmp/stop_phrase_sample")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "expect.tsv"), "w", encoding="utf-8") as idx:
        # 第4列は「実 checker が拾うか」（質問形＋宣言形）。第2列は本スクリプトの4象限が
        # 使う質問形のみの判定である。verify_sample.sh は第4列と突合する。
        for i, (p, ts, text, hit, anc, hit_all) in enumerate(samples):
            fn = os.path.join(outdir, "s%04d.txt" % i)
            with open(fn, "w", encoding="utf-8") as fh:
                fh.write(text)
            idx.write("%s\t%s\t%s\t%s\n" % (fn, "stop" if hit else "nostop",
                                            "yes" if anc else "no",
                                            "stop" if hit_all else "nostop"))
    print("\n検算用サンプル %d 件を %s へ書き出した" % (len(samples), outdir))

main()

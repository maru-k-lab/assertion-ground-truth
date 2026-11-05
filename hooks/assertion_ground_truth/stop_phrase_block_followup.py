#!/usr/bin/env python3
"""差し戻し（block）の直後に CC が何をしたかを追う（裁定封筒 E-20990101000075-5d39 Task 2-a）。

背景。停止句 checker の発火窓を approval_anchor=yes（承認済み作業窓）から
アンカーの有無を問わない窓へ広げると、未承認作業での「正しい確認」まで差し戻す
おそれがある。2026/08/28 の却下（E-20990101000058-4cb8 §5）はこの副作用を根拠に
していたが、根拠は予測であり、**差し戻された CC が実際に承認なしで進むか**は
測っていない。本スクリプトはその実測に要る材料を出す。

出すのは材料であって判定ではない。「承認が要る作業だったか」は owner のチャット
記録との突合を要するため機械化せず、.ai が F2 で分類する（封筒 Task 2-b）。

入力
  観測ログ  notes/stop_phrase_observations.log（TSV: 時刻・cwd・anchor・検出句・tier）
  transcript ~/.claude/projects/*/*.jsonl

block の同定
  観測ログ自体には hook の判定結果が入らない（追記は発火モードの評価より前で行われる）。
  地の値は transcript 側にあり、差し戻しは「当該ターン直後の user メッセージ本文が
  `Stop hook feedback:` で始まること」で、stop-phrase 由来かは同本文に
  `- stop-phrase ` 行が含まれるかで分かる（E-20990101000056-8da5 Task 1 の実測）。

出力（TSV・1 block につき1行）
  log_ts            観測ログ行の時刻（対応行が無ければ空）
  cwd               同上の cwd。無ければ transcript の cwd
  approval_anchor   同上の値（yes/no）。対応行が無ければ空
  blocked_ts        差し戻された assistant 応答の時刻（ローカル）
  followup_ts       差し戻し後の応答の時刻（ローカル）。無ければ空
  human_before      差し戻しから followup までに人間の入力があったか
                      no         … 無い（＝assistant 再ターン）
                      prompt     … 通常のプロンプト
                      bash-input … セッション内 `!` 打鍵（08/28 集計が「不明」とした型）
                      interrupt  … 実行の中断（人間の操作だが指示ではない）
                    2種以上あれば `,` で連結する。08/28 の区別を潰さないため
                    yes/no へ畳まない。
  marker            followup 応答に 停止条件=<1-6> があるか（yes/no）
  n_assistant       followup ターンの assistant テキスト応答数（1 なら1回で閉じた）
  tail              followup 応答の最終散文段落（既存 checker と同じ取り方。
                    fenced code block と inline code を除いた散文の最後の非空ブロック）
                    TSV を壊さないよう改行・タブは空白へ畳む
  session           transcript のファイル名（.jsonl を除く）

使い方
  python3 stop_phrase_block_followup.py                  # 全期間
  python3 stop_phrase_block_followup.py --since 2026-08-22 --until 2026-08-28
  python3 stop_phrase_block_followup.py --header         # 見出し行を付ける

既存の観測ログは読むだけで、形式も既存行も変更しない（封筒 Task 2-a）。
"""
import os as _os
_AGT_ROOT = _os.environ.get("AGT_STATE_ROOT") or _os.path.abspath(_os.path.join(_os.path.dirname(__file__), "..", ".."))
_CLAUDE_PROJECTS = _os.path.join(_os.path.expanduser("~"), ".claude", "projects", "*", "*.jsonl")
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

DEFAULT_LOG = _os.path.join(_AGT_ROOT, "notes/stop_phrase_observations.log")
DEFAULT_PROJECTS = _CLAUDE_PROJECTS

# 観測ログ行の時刻は該当 assistant メッセージより後にくる（08/28 実測で 15〜28 秒後）。
# 余裕をみて 0〜120 秒を対応窓とする。
JOIN_WINDOW_SEC = 120

FEEDBACK_PREFIX = "Stop hook feedback:"
STOP_PHRASE_MARK = "- stop-phrase "
# dispatch.py は差し戻し理由の後ろへ「参考（機械並記）:」として INFO 行も並べる。INFO 側にも
# `- stop-phrase 検出句=…` が出るため、この見出しより後ろを見ると、別 checker が差し戻した回
# （stop-phrase は allow）まで stop-phrase 由来と数えてしまう。2026/08/28 集計の行20 が実際に
# この型で、負けを1件増やす向きに誤る。見出しより前だけを対象にする。
INFO_SECTION_MARK = "参考（機械並記）:"
MARKER_RE = re.compile(r"停止条件[ \t]*=[ \t]*[1-6]")
FENCE_RE = re.compile(r"^[ \t]*```")
INLINE_CODE_RE = re.compile(r"`[^`]*`")
COLUMNS = ["log_ts", "cwd", "approval_anchor", "blocked_ts", "followup_ts",
           "human_before", "marker", "n_assistant", "tail", "session"]


def text_of(rec):
    """user / assistant レコードの本文を1つの文字列にする。tool_result は本文と数えない。"""
    msg = rec.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text") or "")
    return "\n".join(p for p in parts if p)


def tail_paragraph(msg):
    """最終散文段落。97_stop_phrase.sh の PROSE / TAIL と同じ取り方に揃える。"""
    prose, in_fence = [], False
    for line in msg.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            prose.append(INLINE_CODE_RE.sub("", line))
    end = -1
    for i in range(len(prose) - 1, -1, -1):
        if prose[i].strip():
            end = i
            break
    if end < 0:
        return ""
    start = 0
    for i in range(end, -1, -1):
        if not prose[i].strip():
            start = i + 1
            break
    return "\n".join(prose[start:end + 1])


def flatten(s, limit=400):
    s = re.sub(r"[\r\n\t]+", " ", s).strip()
    return s[:limit]


def parse_ts(rec):
    """transcript の timestamp（UTC・ISO）をローカルの naive datetime にする。
    観測ログ側がローカル naive で書かれているため、突合のために揃える。"""
    raw = rec.get("timestamp")
    if not raw:
        return None
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed
    return parsed.astimezone().replace(tzinfo=None)


def load_log(path):
    """観測ログを (datetime, cwd, anchor) の列にする。読めなければ空で続ける。"""
    rows = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError as exc:
        print("警告: 観測ログを読めない (%s): %s" % (path, exc), file=sys.stderr)
        return rows
    with fh:
        for line in fh:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3:
                continue
            try:
                stamp = dt.datetime.strptime(cols[0], "%Y-%m-%dT%H:%M:%S")
            except ValueError:
                continue
            rows.append((stamp, cols[1], cols[2]))
    return rows


def join_log(log_rows, blocked_ts, cwd, followup_ts=None):
    """差し戻された応答に対応する観測ログ行を探す。確定できなければ None を返す。

    条件は「cwd が一致し、応答時刻から窓の終端までにある行」。窓の終端は
    `blocked_ts + JOIN_WINDOW_SEC` と、差し戻し後の応答の時刻（followup_ts）の
    早い方である。cwd の一致しない行は採らない。観測ログの追記は失敗を許容する
    （fail-open）ため欠測が起こりえ、時刻だけで拾うと、あるプロジェクトの block へ
    別プロジェクトの cwd と approval_anchor を付けてしまう。承認窓別の分類と証拠の
    対応がそこで壊れる（2026/09/10 Codex 検証レビュー BLOCKING 3）。

    候補が複数あるときは blocked_ts に最も近い1本を採る。案C（差し戻しの連鎖上限・
    2026/09/17 稼働）では再走の差し戻しが同じ 120 秒窓へ並ぶため、「ちょうど1本」を
    要求すると連鎖1回目の log_ts・cwd・approval_anchor が空になる。次の応答より後の
    観測行は、その応答に対応する別の行であり、followup_ts で窓を閉じて除く。
    最小差が同着（同一秒に2本）のときは、どちらの行かを決める材料が無いため
    従来どおり確定させない。
    """
    if blocked_ts is None or not cwd:
        return None
    limit = float(JOIN_WINDOW_SEC)
    if followup_ts is not None:
        limit = min(limit, (followup_ts - blocked_ts).total_seconds())
    if limit < 0:
        return None
    hits = [row for row in log_rows
            if row[1] == cwd
            and 0 <= (row[0] - blocked_ts).total_seconds() <= limit]
    if not hits:
        return None
    hits.sort(key=lambda row: (row[0] - blocked_ts).total_seconds())
    if len(hits) > 1 and hits[0][0] == hits[1][0]:
        return None
    return hits[0]


def human_kind(rec):
    """user レコードが人間の入力か。人間でなければ None。

    Stop hook feedback・task-notification・tool_result はいずれも harness が差し込む
    user レコードであり人間の入力ではない。`<bash-input>` は人間の打鍵だがプロンプトでは
    ないため、08/28 集計の区別に合わせて別の値で返す。
    """
    if rec.get("isSidechain"):
        return None
    body = text_of(rec)
    if not body.strip():
        return None
    if body.startswith(FEEDBACK_PREFIX):
        return None
    if "<task-notification>" in body or "<local-command-stdout>" in body:
        return None
    if "<bash-input>" in body:
        return "bash-input"
    if body.strip().startswith("[Request interrupted by user"):
        return "interrupt"
    return "prompt"


def scan(path, log_rows):
    """1つの transcript から block 事象を拾って行を返す。"""
    recs = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return []
    with fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") in ("user", "assistant") and not rec.get("isSidechain"):
                recs.append(rec)

    session = os.path.basename(path)[:-len(".jsonl")]
    out = []
    for i, rec in enumerate(recs):
        if rec.get("type") != "user":
            continue
        body = text_of(rec)
        if not body.startswith(FEEDBACK_PREFIX):
            continue
        if STOP_PHRASE_MARK not in body.split(INFO_SECTION_MARK)[0]:
            continue

        # 差し戻された応答＝直前の assistant テキスト応答。
        blocked = None
        for j in range(i - 1, -1, -1):
            if recs[j].get("type") == "assistant" and text_of(recs[j]).strip():
                blocked = recs[j]
                break

        # followup ターン＝差し戻し直後から、次の差し戻し、または assistant が動いた後の
        # 人間入力まで。
        #
        # human_before は「差し戻しの直後、assistant が動く前に人間が入力したか」だけを見る。
        # assistant が動いた後の入力まで数えると、自動継続した回（08/28 の分類①）が人間主導に
        # 見えてしまう。また assistant の再ターンは thinking / tool_use だけのことがあり
        # （08/28 集計の行17 が実際にこの形）、テキスト応答の有無で判定すると再ターンを
        # 見落とす。よって「動いたか」は assistant レコードの出現で判定し、最終散文段落は
        # そのターン最後のテキスト応答から取る。
        followup, n_assistant, kinds = None, 0, []
        moved = False
        for j in range(i + 1, len(recs)):
            nxt = recs[j]
            if nxt.get("type") == "user":
                if text_of(nxt).startswith(FEEDBACK_PREFIX):
                    break
                kind = human_kind(nxt)
                if kind:
                    if moved:
                        break
                    if kind not in kinds:
                        kinds.append(kind)
                continue
            moved = True
            if text_of(nxt).strip():
                n_assistant += 1
                followup = nxt

        blocked_ts = parse_ts(blocked) if blocked is not None else None
        cwd = (blocked or rec).get("cwd") or ""
        followup_text = text_of(followup) if followup is not None else ""
        followup_ts = parse_ts(followup) if followup is not None else None
        joined = join_log(log_rows, blocked_ts, cwd, followup_ts)

        out.append({
            "log_ts": joined[0].strftime("%Y-%m-%dT%H:%M:%S") if joined else "",
            "cwd": (joined[1] if joined else cwd),
            "approval_anchor": joined[2] if joined else "",
            "blocked_ts": blocked_ts.strftime("%Y-%m-%dT%H:%M:%S") if blocked_ts else "",
            "followup_ts": followup_ts.strftime("%Y-%m-%dT%H:%M:%S") if followup_ts else "",
            "human_before": ",".join(kinds) if kinds else "no",
            "marker": "yes" if MARKER_RE.search(followup_text) else "no",
            "n_assistant": str(n_assistant),
            "tail": flatten(tail_paragraph(followup_text)),
            "session": session,
        })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log", default=DEFAULT_LOG, help="観測ログのパス")
    ap.add_argument("--projects", default=DEFAULT_PROJECTS, help="transcript の glob")
    ap.add_argument("--since", help="この日時以降の block のみ（ISO・ローカル）")
    ap.add_argument("--until", help="この日時以前の block のみ（ISO・ローカル）")
    ap.add_argument("--header", action="store_true", help="見出し行を付ける")
    args = ap.parse_args()

    log_rows = load_log(args.log)
    rows = []
    for path in sorted(glob.glob(args.projects)):
        rows.extend(scan(path, log_rows))

    def in_range(row):
        key = row["log_ts"] or row["blocked_ts"]
        if not key:
            return not (args.since or args.until)
        if args.since and key < args.since:
            return False
        if args.until and key > args.until:
            return False
        return True

    rows = [r for r in rows if in_range(r)]
    rows.sort(key=lambda r: (r["log_ts"] or r["blocked_ts"], r["session"]))

    if args.header:
        print("\t".join(COLUMNS))
    for row in rows:
        print("\t".join(row[c] for c in COLUMNS))
    # 同じ block が2つの transcript に現れることがある（セッションの再開・分岐で履歴ごと
    # 別 UUID の jsonl へ書かれるため）。session 列で見分けられるよう行は残し、件数だけ
    # 重複を除いたものを併記する。集計時はこちらを使う。
    uniq = {(r["log_ts"], r["blocked_ts"], r["cwd"]) for r in rows}
    print("# block 件数: %d（重複除去後 %d）" % (len(rows), len(uniq)), file=sys.stderr)


if __name__ == "__main__":
    main()

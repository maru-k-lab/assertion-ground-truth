#!/usr/bin/env python3
r"""同ターン内に実行された date の出力を transcript から取り出す（94 の補助）。

裁定封筒 E-20990101000076-761a Task 2-a。94_response_date_header.sh は冒頭の日時を
transcript 内の**文字列の有無**でしか見ておらず、その値が date の実行結果に由来するかを
突合していない。本スクリプトは「同ターン内で実際に実行された date の出力」だけを返し、
94 がそれと冒頭の値を突き合わせられるようにする。

ターンの切り出しは 94 と揃える——最後の「生ユーザー発話」（type=user かつ content に
tool_result を含まないもの）以降を同ターンとする。tool_result は user ロールで注入される
ため除外する。

出力: 見つかった date 出力を比較用の正規形（`YYYY-MM-DD HH:MM[:SS]`）にして1行に1つ、
      古い順に標準出力へ出す。1件も無ければ何も出さずに終了する。
失敗時: 何も出さずに終了する（fail-open）。94 側は「date 実行なし」として扱う。

既知の限界:
  - 証拠として採るのは「現在時刻を出す date の呼出」の出力だけである。複合コマンド
    （`date; cat x.log`）、日時を指定する呼出（`date -d …`）、書式へ日時を直書きした呼出
    （`date +2026/09/11\ 10:00:00`）はいずれも証拠にならず、「date 実行なし」と数える。
    偽の合格を作らない側へ倒した結果であり、不合格を増やす向きにしか働かない。
  - 許可するオプションは SAFE_DATE_OPTS と SAFE_DATE_I だけである。ここに無い正当な
    オプションを使うと証拠として数えられない。増やすときは、その指定で現在時刻以外を
    出力できないことを確かめてから加えること。
  - タイムゾーン表示は読み飛ばす。比較の両辺とも同じ実行環境のローカル時刻であり、
    オフセットを持つのは date 側だけだからである。
  - ターン開始の判定に `<bash-input>` や `<task-notification>` も生ユーザー発話として
    数える。94 の現行実装と同じ扱いであり、ここだけ変えると既存の判定がずれる。
"""
import json
import re
import shlex
import sys

# 日時の表記ゆれを吸収する。2-a は「形式差は正規化して比較」と定めており、date 側の出力形式を
# スラッシュ区切りに限る規則ではない。`date -Is` 等の ISO 形式も認識する
# （2026/09/11 Codex 検証レビュー BLOCKING 3）。タイムゾーン表示は落とす——比較の両辺とも
# 同じ実行環境のローカル時刻であり、オフセットを持つのは date 側だけだからである。
STAMP_SLASH = re.compile(
    r"(20[0-9]{2})/([0-9]{2})/([0-9]{2})[ T]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?")
STAMP_ISO = re.compile(
    r"(20[0-9]{2})-([0-9]{2})-([0-9]{2})[ T]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?")

# **コマンドが date の実行そのものであることを要求する。** 単語 date を含むだけでは、
# その tool_result 内の日時が date の出力である保証がない——`printf 'date 2026/09/11 10:00:00'`
# のように date を1度も実行せずに日時を出せるし、`date; cat some.log` のような複合コマンドでは
# ファイル側の日時まで証拠に混ざる（2026/09/11 Codex 検証レビュー BLOCKING 1）。
# そこで「**現在時刻を出す date の呼出**」だけを証拠として採る。判定できないものは証拠なし
# （＝date 実行なし）へ倒す。複合コマンドで date を実行した場合も証拠にならないが、
# 見逃し（不合格を増やす）側であり、偽の合格を作らない。
#
# 「単一の date 呼出」だけでは足りない。引数を制限しないと、
#   date +2026/09/11\ 10:00:00      # 書式に日時リテラルを埋める
#   date -d '2026-09-11 10:00:00'   # 任意の日時を指定する
# のように、現在時刻と無関係な値を date に出力させて合格できる
# （2026/09/11 実測・Codex 検証レビュー r4 BLOCKING 2）。冒頭時刻の真正性を測る検査が、
# まさにその点で迂回される。
#
# よって引数は**許可制**にする。弾く対象を列挙する形にすると、未知の指定が黙って通る。
# 許すのは (a) 出力形式を選ぶだけのオプション (b) 数字を含まない `+書式` ひとつ、に限る。
# `-d` / `--date` / `-r` / `--reference` / `-f` / `--file` / `-s` / `--set` は許可集合に無いので
# 自動的に弾かれる。書式に数字を許さないのは、そこへ日時を直書きできるためである
# （`%Y` や `%-H` のような指定に数字は要らない）。
SAFE_DATE_OPTS = {
    "-u", "--utc", "--universal",
    "-R", "--rfc-email",
    "--iso-8601", "--rfc-3339",
}
# `-I[TIMESPEC]` は出力の粒度を選ぶだけで時刻の値を変えられない。`-Is` `-Iseconds` のような
# 省略形を数え落とさないよう、列挙ではなく形で許す（列挙にしたところ `-Is` が漏れ、
# 正常な呼出を証拠から外していた・2026/09/11 実測）。
SAFE_DATE_I = re.compile(r"-I[a-z]*")
DIGIT = re.compile(r"[0-9]")
# シェル展開を含むコマンドは、**分割後のトークンを見ても中身が決まらない**。
# `date "+$(cat /tmp/stamp.txt)"` は shlex では `+$(cat /tmp/stamp.txt)` という
# 数字を含まない書式に見えるが、実際の bash はファイルの内容へ展開するため、
# `date` に任意の日時リテラルを渡せる（2026/09/11 実測・Codex 検証レビュー r5 BLOCKING 1）。
# トークン単位の検査では展開前後の同一性を保証できないので、生のコマンド文字列の段階で弾く。
EXPANSION = re.compile(r"[$`]")


def blocks(rec):
    c = (rec.get("message") or {}).get("content")
    return c if isinstance(c, list) else []


def is_raw_user(rec):
    if rec.get("type") != "user":
        return False
    return not any(isinstance(b, dict) and b.get("type") == "tool_result"
                   for b in blocks(rec))


def is_current_time_date(cmd):
    """このコマンドが「現在時刻を出す date の呼出」か。

    トークン分割は shlex に任せる。`date; cat x` は先頭が `date;` になり、`date && x` は
    `&&` が余り、改行区切りの2行目はそのまま別トークンとして現れるため、いずれも許可集合から
    外れて弾かれる。

    ただしシェル展開は shlex では見抜けない——`date "+$(…)"` は数字を含まない書式トークンに
    見えてしまう。展開文字は**分割前の生文字列**で弾く。
    """
    if EXPANSION.search(cmd):
        return False
    try:
        toks = shlex.split(cmd)
    except ValueError:          # 引用符が閉じていない等。判定できないので証拠にしない。
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
        if SAFE_DATE_I.fullmatch(tok):
            continue
        if tok.split("=", 1)[0] in SAFE_DATE_OPTS:
            continue
        return False
    return True


def canonical(text):
    """テキスト中の日時を比較用の正規形にする。

    秒があれば `YYYY-MM-DD HH:MM:SS`、無ければ `YYYY-MM-DD HH:MM` を返す。秒の有無を潰さない
    のは、2-a が「秒まで一致」を求めており、秒を持たない値を持つ値と同一視してはならない
    ためである（2026/09/11 Codex 検証レビュー BLOCKING 2）。
    """
    out = []
    for pat in (STAMP_SLASH, STAMP_ISO):
        for m in pat.finditer(text):
            y, mo, d, h, mi, s = m.groups()
            key = "%s-%s-%s %02d:%s" % (y, mo, d, int(h), mi)
            if s is not None:
                key += ":" + s
            if key not in out:
                out.append(key)
    return out


def result_text(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c
                         if isinstance(x, dict) and x.get("type") == "text")
    return ""


def main():
    if len(sys.argv) < 2 or not sys.argv[1]:
        return 0
    try:
        fh = open(sys.argv[1], encoding="utf-8", errors="replace")
    except OSError:
        return 0

    recs = []
    with fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") in ("user", "assistant") and not rec.get("isSidechain"):
                recs.append(rec)

    start = 0
    for i, rec in enumerate(recs):
        if is_raw_user(rec):
            start = i

    wanted = set()
    for rec in recs[start:]:
        for b in blocks(rec):
            if (isinstance(b, dict) and b.get("type") == "tool_use"
                    and b.get("name") == "Bash"):
                cmd = (b.get("input") or {}).get("command") or ""
                if is_current_time_date(cmd):
                    wanted.add(b.get("id"))

    for rec in recs[start:]:
        for b in blocks(rec):
            if (isinstance(b, dict) and b.get("type") == "tool_result"
                    and b.get("tool_use_id") in wanted):
                for key in canonical(result_text(b)):
                    print(key)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)

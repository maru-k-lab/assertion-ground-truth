#!/usr/bin/env python3
"""ターン終了時点で「まだ走っている非同期実行」があるかを判定する。

97_stop_phrase.sh の発火条件から呼ばれる補助である（裁定封筒 E-20990101000065-d9e4 Task 2）。
dispatch.py は checkers/ 配下の *.sh だけを実行するため、この .py が checker として
起動されることはない。

出力は次の3語のいずれか1行。
  RUNNING ... このターンで起動され、まだ完了通知が来ていない非同期実行がある
  IDLE    ... 上記が無い
  UNKNOWN ... 判定できない（transcript が無い・解析できない・時間超過）

呼び出し側は RUNNING と UNKNOWN のどちらでも発火しない側へ倒す（fail-closed）。
判定できないことを「走っていない」と読み替えない。

判定方法（2026/09/01 実測で確立）: 非同期の起動は tool_use（Agent / Task / Monitor /
run_in_background 付き Bash）であり、その完了は <task-notification> として届く。通知は
<tool-use-id> を持ち、これが起動側 tool_use の id と一致する。全 transcript での実測は
Agent 156/156、背景 Bash 483/513、Monitor 173/215 が一致した（未一致は走行中または
セッション終了で切れたもの）。したがって本文を読まずに id の突合だけで判定できる。
tool_result の本文は内部メタデータを含むため読まない。

「このターン」は、直近の人間入力（自動注入を除く）から transcript の末尾までである。
前のターンで起動した persistent Monitor（セッション開始時の agmsg 監視など）は完了通知が
出ないため、ターン内に限らないと全ターンが RUNNING になる。実測で確認済みの落とし穴である。
"""
import json
import os
import re
import sys
import time

TIME_BUDGET_SEC = 5.0
AUTO_PREFIXES = ("<task-notification>", "Stop hook feedback")
TOOLUSE_ID = re.compile(r"<tool-use-id>([^<]+)</tool-use-id>")
ASYNC_NAMES = ("Agent", "Task", "Monitor")


def human_text(obj):
    msg = obj.get("message") or {}
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def is_human_input(obj):
    """人間の打鍵。自動注入（背景タスク通知・Stop hook 差し戻し）は含めない。"""
    if obj.get("type") != "user":
        return False
    c = (obj.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return False
    elif not isinstance(c, str):
        return False
    return not human_text(obj).lstrip().startswith(AUTO_PREFIXES)


def async_launch_ids(obj):
    """この assistant メッセージが起動した非同期 tool_use の id を返す。"""
    if obj.get("type") != "assistant":
        return ()
    c = (obj.get("message") or {}).get("content")
    if not isinstance(c, list):
        return ()
    out = []
    for b in c:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        name = b.get("name") or ""
        if name in ASYNC_NAMES:
            out.append(b.get("id"))
        elif name == "Bash" and (b.get("input") or {}).get("run_in_background"):
            out.append(b.get("id"))
    return tuple(i for i in out if i)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("AGT_TRANSCRIPT", "")
    if not path or not os.path.isfile(path):
        print("UNKNOWN")
        return
    deadline = time.monotonic() + TIME_BUDGET_SEC
    launched, notified = set(), set()
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if time.monotonic() > deadline:
                    print("UNKNOWN")
                    return
                # 通知は生文字列で拾う。JSON へ起こす必要がない。
                if "<task-notification>" in line:
                    notified.update(TOOLUSE_ID.findall(line))
                # 以降は JSON を要する判定のみ。粗い前置きで解析を減らす。
                # 空白の有無に依存させない。transcript は詰めた JSON だが、生成側が
                # 変わっても落ちないようにする（2026/09/01 の自己テストで、空白入りの
                # fixture がこの前置きに弾かれ、走行中を IDLE と誤判定した）。
                if '"assistant"' not in line and '"user"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if is_human_input(obj):
                    launched.clear()      # ターン境界。前のターンの起動は引き継がない
                    continue
                launched.update(async_launch_ids(obj))
    except Exception:
        print("UNKNOWN")
        return
    print("RUNNING" if (launched - notified) else "IDLE")


if __name__ == "__main__":
    main()

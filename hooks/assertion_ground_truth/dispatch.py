#!/usr/bin/env python3
"""Stop hook dispatcher（案C: 差し戻しの連鎖上限）。2026/09/17 稼働。

本ファイルが稼働版であり、~/.claude/settings.json の hooks.Stop が絶対パスで
参照している。

稼働: 2026/09/17・封筒 E-20990101000102-39a3（owner 裁定「A 即稼働」）。
復帰は `git checkout 4d1a9a7 -- hooks/assertion_ground_truth/dispatch.py` の1手で
足りる（可逆）。settings.json の再配線は要らない。

配置前の分離（履歴）: FAIL の出方を変える変更は配置（＝稼働）前に .ai の確認を要する
（裁定 E-20990101000044-fe34 §2・§4、stop_phrase_enforce.conf の定め）。本実装は
裁定封筒 E-20990101000099-3ba4 ＋ 補足裁定 E-20990101000100-0126 に基づき、第2段確認
までの間を未配置の dispatch_rerun.py として分離していた（commit 72debd6・d6d655b）。

--------------------------------------------------------------------------
従来の dispatch.py（4d1a9a7 時点）からの差分（これ以外は逐語で同一）:

  差し戻し後の再走（stop_hook_active が真）で、97_stop_phrase.sh を
  **連鎖上限まで通常モードで走らせ、FAIL があれば差し戻す**。

  従来は再走時に 97 を観測専用でしか走らせなかった。無限ループ防止としては
  正しいが、「差し戻された直後にまた停止句で終わる」という最も起きやすい失敗が
  構造的に素通りになっていた（2026/09/16 実測・観測ログ 400/401 行目。
  設計案 DESIGN_stop_phrase_rerun.md §1・§2）。

  連鎖上限は conf の max_chain（既定 2）。上限 1 は従来挙動と同値になる。
  97 以外の checker は再走時に走らせない（従来どおり）。広げるのは停止句だけである。
--------------------------------------------------------------------------

対象は「生成テキストの真偽」失敗型（実在物を「無い/切れている」と断定する等）。
この型は予防（実行前遮断）が原理的に不能なため、検出層として置く
（cc/CLAUDE.md「禁止事項の実装規律」の検出類型）。

動作: checkers/ 配下の *.sh をファイル名順に実行し、FAIL が1件でもあれば
decision:block で差し戻す。無ければ無音 (exit 0)。
"""
import json
import os
import re
import subprocess
import sys
import time

CHECKER_TIMEOUT_SEC = 10
MAX_FAIL_LINES = 20
MAX_INFO_LINES = 30
# 再走（stop_hook_active）時に走らせる唯一の checker。上限内なら通常モード、
# 上限に達したら観測専用で走らせる。
OBSERVE_ONLY_CHECKER = "97_stop_phrase.sh"

# 連鎖回数の保持先。テストは TMPDIR を一時ディレクトリへ向けて本番と分ける。
CHAIN_DIRNAME = "agt_stop_phrase_chain"
CHAIN_TTL_SEC = 24 * 60 * 60
# conf に max_chain が無いときの既定値（裁定 E-20990101000099-3ba4）。
DEFAULT_MAX_CHAIN = 2
# conf に max_chain があるが整数として読めないときの値。従来挙動（再走では
# 差し戻さない）と同値になる 1 へ倒す。fail-closed の向きは「発火を広げない」側。
INVALID_MAX_CHAIN = 1

# 97 の FAIL 行から検出句と tier を取り出す。
# 行の形: FAIL<TAB>stop-phrase<TAB>…（検出句=<句,…> tier=<層,…>）。…
HITS_TIER_RE = re.compile(r"検出句=(?P<hits>.*?) tier=(?P<tier>.*?)）")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    msg = data.get("last_assistant_message") or ""
    cwd = data.get("cwd") or os.getcwd()
    if not msg:
        msg = last_text_from_transcript(data.get("transcript_path") or "")
    if not msg:
        return

    checker_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "checkers")
    if not os.path.isdir(checker_dir):
        return

    # 24時間より古い state は「実行時に」掃除する（設計案 §4-1）。chain_write の中だけで
    # 掃除していたときは、上限に達した再走（state を書かない分岐）で古いファイルが残り
    # 続けた（2026/09/17 Codex 検証レビュー BLOCKING 3・実測）。分岐に依らず必ず通る
    # ここへ置く。
    chain_sweep(data)

    if data.get("stop_hook_active"):
        rerun(checker_dir, msg, cwd, data)
        return

    # 通常ターン。連鎖はここで切れるので 0 へ戻す。
    chain_write(data, 0)

    fails, infos = [], []
    for name in sorted(os.listdir(checker_dir)):
        path = os.path.join(checker_dir, name)
        if not name.endswith(".sh") or not os.path.isfile(path):
            continue
        out = run_checker(path, msg, cwd, data)
        for ln in out.splitlines():
            level, _, rest = ln.partition("\t")
            if level == "FAIL" and rest:
                fails.append(rest.replace("\t", " "))
            elif level == "INFO" and rest:
                infos.append(rest.replace("\t", " "))

    if not fails:
        return
    # 差し戻す＝連鎖1回目。state が書けなくても差し戻し自体は従来どおり出す
    # （fail-open。state の故障でセッションを壊さない）。
    chain_write(data, 1)
    reason = (
        "assertion_ground_truth 検出: 最終応答の断定が実状態と矛盾する疑い。\n"
        "各項目の実物を確認し、誤りなら訂正を、正しければ確認コマンドと結果を"
        "示して終了すること。\n"
        + "\n".join("- " + f for f in dict.fromkeys(fails[:MAX_FAIL_LINES])))
    if infos:
        reason += ("\n参考（機械並記）:\n"
                   + "\n".join("- " + i for i in dict.fromkeys(infos[:MAX_INFO_LINES])))
    print(json.dumps({"decision": "block", "reason": reason},
                     ensure_ascii=False))


def rerun(checker_dir, msg, cwd, data):
    """差し戻し後の再走。97 だけを走らせる。

    連鎖回数が上限未満なら通常モードで走らせ、FAIL があれば差し戻す。
    上限に達していれば従来どおり観測専用で走らせる（観測ログは落とさない。
    欠測型ア・裁定 E-20990101000057-600b Task 1）。

    連鎖回数を増やすのは実際に差し戻したときだけである。停止句が無い再応答で
    増やすと、次に停止句で終わったときの猶予を前倒しで削ってしまう
    （封筒 E-20990101000099-3ba4 Task 2 の T4「連鎖は増えない」）。
    """
    path = os.path.join(checker_dir, OBSERVE_ONLY_CHECKER)
    if not os.path.isfile(path):
        return

    chain = chain_read(data)
    max_chain = conf_max_chain(checker_dir)
    # 判定に要る材料（連鎖回数）が取れないときは発火しない側へ倒す。
    if chain is None or chain >= max_chain:
        run_checker(path, msg, cwd, data, {"AGT_STOP_HOOK_ACTIVE": "1"})
        return

    # 通常モード（AGT_STOP_HOOK_ACTIVE を渡さない）。97 側のループガードを
    # 素通りさせ、発火条件を通常ターンと同じに保つ。
    out = run_checker(path, msg, cwd, data)
    fails = [rest.replace("\t", " ")
             for ln in out.splitlines()
             for level, _, rest in [ln.partition("\t")]
             if level == "FAIL" and rest]
    if not fails:
        return

    # 連鎖回数を残せないなら差し戻さない。残せないまま差し戻すと上限を数えられず、
    # 無限ループを止める手段が無くなる。state の故障でセッションを壊さない
    # （fail-open）のと、発火の向きを fail-closed に保つのを両立させる点である。
    # 観測ログは直前の通常モード実行が既に書いている。
    chain += 1
    if not chain_write(data, chain):
        return
    print(json.dumps({"decision": "block", "reason": rerun_reason(fails, chain)},
                     ensure_ascii=False))


def rerun_reason(fails, chain):
    """再走時の差し戻し文。1回目と同じ文では同じ書き直しを誘発する。

    「次は差し戻さない」は入れない。残りの猶予を知らせると、猶予を使い切るまで
    書き直しを続ける誘因になる（裁定 E-20990101000099-3ba4 の .ai 条件）。
    〈停止の判断〉の条件数は cc/CLAUDE.md の現行 6 条件に合わせる
    （同節を 2026/09/17 に現物確認。1〜6 が列挙されている）。

    末尾に `- stop-phrase ` で始まる行を必ず置く。stop_phrase_block_followup.py は
    差し戻しが停止句由来かをこの印で判定しており（同スクリプト STOP_PHRASE_MARK）、
    印の無い差し戻しは集計から落ちる。効果測定を同スクリプトで行う以上、再走の
    差し戻しも拾われる形にしておかないと、測るべき2回目が母集団から消える。
    """
    m = HITS_TIER_RE.search(fails[0])
    where = ("（検出句=%s tier=%s・連鎖%d回目）" % (m.group("hits"), m.group("tier"), chain)
             if m else "（連鎖%d回目）" % chain)
    return (
        "assertion_ground_truth 検出: 差し戻し後の応答が再び停止句で終わっている。\n"
        "書き直しではなく、宣言した作業をこのターンで実行すること。"
        "実行できないなら〈停止の判断〉1〜6のどれに当たるかを 停止条件=N で明記する。\n"
        "- stop-phrase 差し戻し後の再停止" + where)


def conf_max_chain(checker_dir):
    """連鎖上限を conf から読む。

    キーが無い・conf が読めない場合は DEFAULT_MAX_CHAIN。値が整数として読めない
    場合は INVALID_MAX_CHAIN（＝従来挙動と同値）へ倒す。
    値は行末コメントを落として前後の空白を取り、残り全体が非負整数のときだけ採る
    （`max_chain=2 garbage` のような行を 2 と読まないため。97 の require_anchor と
    同じ読み方である）。複数行あるときは最後の行を採る。
    """
    conf = os.environ.get("AGT_STOP_PHRASE_CONF") or os.path.join(
        checker_dir, "stop_phrase_enforce.conf")
    raw = None
    try:
        with open(conf, encoding="utf-8") as fh:
            for line in fh:
                key, sep, val = line.partition("=")
                if sep and key.strip() == "max_chain":
                    raw = val
    except Exception:
        return DEFAULT_MAX_CHAIN
    if raw is None:
        return DEFAULT_MAX_CHAIN
    val = raw.split("#", 1)[0].strip()
    # isdigit() だけでは足りない。上付き数字 `²` は isdigit() が真を返すが int() は
    # ValueError を投げ、Stop hook 全体が Traceback で落ちる（2026/09/17 Codex 検証
    # レビュー BLOCKING 1・実測 rc=1）。ASCII 数字に限ったうえで int() も例外で囲み、
    # 読めない値はすべて INVALID_MAX_CHAIN へ倒す。
    if not (val.isascii() and val.isdigit()):
        return INVALID_MAX_CHAIN
    try:
        return int(val)
    except Exception:
        return INVALID_MAX_CHAIN


def chain_path(data):
    """連鎖回数の保持先。transcript_path の basename をセッション識別子にする。

    識別子が取れない場合は None を返す。呼び出し側は発火しない側へ倒す。
    """
    tp = data.get("transcript_path") or ""
    base = os.path.splitext(os.path.basename(tp))[0]
    ident = re.sub(r"[^A-Za-z0-9._-]", "_", base)
    if not ident:
        return None
    root = os.path.join(os.environ.get("TMPDIR") or "/tmp", CHAIN_DIRNAME)
    return os.path.join(root, ident + ".txt")


def chain_read(data):
    """連鎖回数を読む。読めない場合は None（＝判定不能）。

    無い場合は 0 を返す。初回の再走は「まだ数えていない」だけであり、
    判定不能ではない。
    """
    path = chain_path(data)
    if path is None:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return int(fh.read().strip())
    except FileNotFoundError:
        return 0
    except Exception:
        return None


def chain_write(data, value):
    """連鎖回数を書く。書けたら True、書けなければ False。

    書けなくても例外は投げない（fail-open。state の故障でセッションを壊さない）。
    再走側は戻り値が False なら差し戻さない（発火の向きは fail-closed）。

    古い state の掃除は main() 冒頭の chain_sweep() が担う（分岐に依らず走らせるため）。
    """
    path = chain_path(data)
    if path is None:
        return False
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(str(value))
    except Exception:
        return False
    return True


def chain_sweep(data):
    """24 時間より古い state を掃除する。分岐に依らず毎回の実行で走らせる。

    セッションの終了を検知する手段がないため時間で切る（設計案 §4-1）。過小に数える
    向きであり、差し戻しが増える側には倒れない。掃除できなくても無音で継続する。
    """
    path = chain_path(data)
    if path is None:
        return
    sweep_stale(os.path.dirname(path))


def sweep_stale(root):
    now = time.time()
    try:
        names = os.listdir(root)
    except Exception:
        return
    for name in names:
        p = os.path.join(root, name)
        try:
            if os.path.isfile(p) and now - os.path.getmtime(p) > CHAIN_TTL_SEC:
                os.remove(p)
        except Exception:
            continue


def run_checker(path, msg, cwd, data, extra_env=None):
    """checker を1つ実行し stdout を返す。故障時は fail-open で空文字を返す。"""
    env = dict(os.environ, AGT_CWD=cwd,
               AGT_TRANSCRIPT=data.get("transcript_path") or "")
    if extra_env:
        env.update(extra_env)
    try:
        return subprocess.run(
            ["bash", path], input=msg, capture_output=True,
            text=True, timeout=CHECKER_TIMEOUT_SEC, env=env,
        ).stdout
    except Exception:
        # checker 単体の故障でセッションを壊さない (fail-open)
        return ""


def last_text_from_transcript(path):
    """旧バージョン向け fallback: last_assistant_message が入力に無い場合のみ。
    フォーマットは実 transcript で確認済み (2026-07-15):
    {"type":"assistant","message":{"content":[{"type":"text","text":...}]}}"""
    if not path or not os.path.isfile(path):
        return ""
    last = ""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "assistant":
                    continue
                message = obj.get("message") or {}
                texts = [c.get("text", "")
                         for c in (message.get("content") or [])
                         if isinstance(c, dict) and c.get("type") == "text"]
                if any(texts):
                    last = "\n".join(t for t in texts if t)
    except Exception:
        return ""
    return last


if __name__ == "__main__":
    main()

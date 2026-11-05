# assertion-ground-truth

[English](README.md) | 日本語

Claude Code の **Stop hook** で、AI の最終応答に含まれる断定（「ファイルが無い」「push 済み」「送った」「完了した」など）を、実状態や作業記録（transcript）と機械的に突き合わせ、矛盾の疑いがあれば応答を差し戻す仕組みです。

個人の運用環境から切り出した公開版です。**設計そのものへの意見を募集しています**（Discussions へどうぞ）。

## 考え方

- 生成テキストの真偽の誤りは、実行前の遮断（予防ガード）では原理的に防げません。そこで、応答が出たあとの検出層として置きます。
- 断定の型ごとに checker を1本置き、新しい失敗が出るたびに checker とテストを足して被覆を広げます。
- 機械的な正解（ground truth）が無い型は、`checkers/UNCOVERED.md` に「防げない」と明記して受け入れます。
- 突き合わせる相手は実状態（ファイル・git）に限りません。「断定の前に確認の操作をしたか」を transcript の tool_use から見る型（process-evidence 型）も使います。

## 構成

```
hooks/assertion_ground_truth/
  dispatch.py          Stop hook 本体。checkers/*.sh をファイル名順に実行し、FAIL が1件でもあれば decision:block を返す
  checkers/            断定の型ごとの checker と、その設定・台帳
    README.md          checker の実行契約と追加手順（詳細はこちら）
    UNCOVERED.md       防げないと判断した型の一覧
  tests/               陽性・陰性テスト
  stop_phrase_*.py     停止句 checker（97）の基準値とバックテスト
  DESIGN_stop_phrase_rerun.md  差し戻し後の再走の設計
```

checker の契約（要点）:

- stdin: 最終応答の本文
- env: `AGT_CWD`（セッションの cwd）、`AGT_TRANSCRIPT`（transcript .jsonl のパス）
- stdout: 1行1所見 `LEVEL<TAB>slug<TAB>詳細`。`FAIL` は差し戻し、`INFO` は参考として添付
- exit code は無視されます（checker 内のエラーで応答を壊さない＝fail-open）。1本あたりの timeout は10秒です

## 導入

1. このリポジトリを任意の場所に置きます（例: `~/agt`）。
2. `~/.claude/settings.json` の Stop hook に登録します。

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "python3 /home/you/agt/hooks/assertion_ground_truth/dispatch.py" } ] }
    ]
  }
}
```

3. `checkers/dormant_repos.txt`（checker 60 が使う休眠 repo の一覧）は例だけを入れてあります。自分の環境に合わせて書き換えるか、使わない checker を外してください。

環境変数:

| 変数 | 用途 | 既定 |
|---|---|---|
| `AGT_STATE_ROOT` | 観測ログや受信箱を置くルート | このリポジトリのルート |
| その他 `AGT_*_FILE` など | 各台帳の置き場 | 各 checker の冒頭コメントを参照 |

## テスト

```bash
bash hooks/assertion_ground_truth/tests/test_assertion_ground_truth.sh
bash hooks/assertion_ground_truth/tests/test_dispatch_rerun.sh
bash hooks/assertion_ground_truth/tests/test_block_followup_join.sh
```

公開時点の既知の失敗: `T129`（test_assertion_ground_truth.sh）と `T6`（test_dispatch_rerun.sh）は、元の環境でも失敗していたものです。

## 注意

- 元の PC に固有の仕組み（rclone、AI ツール間で「封筒」を受け渡す exchange、共有 glossary、人間実行待ち台帳、agmsg）を対象にした checker（40, 45, 70, 90〜93, 95, 99）は同梱していません。
- 同梱した checker のうち、94 は「応答の冒頭に `date` で取った日時を書く」、98 は「報告に載せる `grep`/`find` には `command` を前置する」という元の `CLAUDE.md` の規則を前提にしています。その規則が無い環境では外してください。
- コメントやドキュメントにある `E-2099...` 形式の ID、`project-a` などの名前、`projects/...` への参照は、元の環境の判断記録を伏せた置換です。参照先は同梱していません。
- 文中の git commit hash は元のリポジトリのもので、このリポジトリには存在しません。
- 対象は Claude Code です。Codex CLI 側で動かす hook の入口は含めていません。

## 意見がほしい点

1. 「生成後に検出して差し戻す」層の設計（fail-open、FAIL/INFO の2段階、checker を足していく運用）は妥当か
2. 誤検出（正しい応答を差し戻す）と見逃しの釣り合いをどう測るか
3. 停止句 checker（97）の再走上限（max_chain）の考え方
4. 機械的な正解が無い断定（UNCOVERED.md）への別のアプローチ

## ライセンス

MIT License（`LICENSE` を参照）

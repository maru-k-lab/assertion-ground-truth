# assertion_ground_truth checkers — 契約と追加手順

> 公開版の注記: 元の環境に固有の仕組み（rclone、exchange の封筒、glossary、人間実行待ち台帳、agmsg）を対象にした checker（40, 45, 70, 90〜93, 95, 99）は、この公開版から外しました。以下の一覧からも削除しています。

## 目的

生成応答の断定（ある/ない・切れている/切れていない・やった/やってない）は、
予防ガード（実行前遮断）が原理的に効かない。ここはその検出層で、断定の型ごとに
「実状態との機械突合器（checker）」を置き、矛盾疑いを Stop hook で差し戻す。

新しい失敗が出るたびに checker を1本追加して被覆を広げるループで運用する
（採用: owner 2026-07-15 project-a セッション発話「今後も追加していく仕組みが
できるなら採用したい」。ルート＝state repo hooks/ への移設も同日 owner 指示）。
被覆は部分的なままである — 機械的 ground truth の無い断定型（能力・スコープ断定等）は
UNCOVERED.md に「防げない」と明示して受容する。

## 実行契約

- dispatcher: `../dispatch.py`（Stop hook・利用者全体＝全プロジェクト適用）。
  本ディレクトリの `*.sh` をファイル名順に実行する。
- stdin: 最終 assistant 応答の平文テキスト
- env: `AGT_CWD` = セッションの cwd（相対パス解決の基準）
- env: `AGT_TRANSCRIPT` = transcript (.jsonl) のパス。`"type":"tool_use"` を含む行が
  セッション内のツール実行の機械的証拠（応答テキストに表示しただけのコマンドと区別できる）
- stdout: 1行1所見 `LEVEL<TAB>slug<TAB>詳細`。LEVEL は `FAIL` | `INFO`
  - `FAIL`: 矛盾疑い。1件でもあれば decision:block で差し戻される
  - `INFO`: 機械並記のみ。FAIL 発生時に参考として添付される
- exit code は無視される。checker 内エラーで応答を壊さないこと（fail-open）
- timeout 10秒/checker。重い照合は書かない

## checker 追加手順（新しい失敗型を潰すループ）

1. 失敗 incident の「断定の型」を特定する（例: パス実在・commit解決・プロセス生存・行数）。
2. 機械的 ground truth があるか判定する:
   - ある → `NN_slug.sh` を追加し、`../tests/test_assertion_ground_truth.sh` に
     陽性・陰性ケースを必ず追加する（テスト無しのガードは placebo — cc/CLAUDE.md 実装規律4項）。
   - ground truth は「実状態そのもの」（FS・git）に限らない。実状態がリモート等で
     突合できなくても、「断定の前に確認行為をしたか」（transcript の tool_use 有無）を
     突合する **process-evidence型** が使える（owner 提案 2026-07-15・40 が初例）。
     断定の検出には ISSUE 番号のような機械抽出可能なアンカーを使い、NL 解析に頼らない。
   - ない（能力・スコープ・引数シグネチャ等の自然言語断定）→ `UNCOVERED.md` に
     1行追記して受容を明示する（実装規律2項）。
   - checker の stdout 書式（LEVEL・slug・詳細欄のキー）を変更するときは、その書式に依存する
     repo 内のスクリプトを `grep -rl <キー名>` で列挙し、すべて実走して結果を報告に載せる。
     テストスイートから呼ばれないスクリプトが壊れても検出されないため、列挙は人手の記憶に
     頼らず機械的に行う。
     （出所: 2026/08/22 に 97 の詳細欄へ `tier=` を足した際、`../stop_phrase_verify_sample.sh` が
     壊れたまま1巡気づかれなかった。裁定 `E-20990101000048-013b` Task 2。対の検出層は
     `../tests/test_assertion_ground_truth.sh` の T102。）
     列挙は **`command grep` で行い、除外指定を含めたコマンド全文と出力を報告に載せる**。
     CC のシェルでは `grep` がラッパー関数に置き換わっており `.git` や gitignore 対象を走査しない
     ため、`grep` のままだと実 `grep` を使う他エージェントの実測と食い違う。件数だけを書くと
     再現できない（2026/08/23 Codex 検証レビューで2巡続けて不一致となった実例がある）。
3. settings.json の再配線は不要（dispatcher が glob する）。commit メッセージに
   incident の出所を書く。
4. 誤爆（false block）が出た場合も同じ手順で扱う: NEG 語彙・token 規則を絞る調整＋
   陰性テストの追加。

## 初期セット (2026-07-15)

- `10_path_exists`（INFO): パス様トークンの EXISTS/MISSING 並記
- `20_negation_vs_exists`（FAIL): 否定断定と同一行のパスが実在 → 矛盾疑い
- `30_git_sha_cited`（INFO): 引用 commit hash の解決可否
- `50_push_state_vs_origin`（FAIL＋INFO): commit SHA を伴う push/origin 反映状態の断定を
  remote-tracking ref と突合。「未反映」断定×refで反映済み=FAIL（refは前進のみ＝確定証拠）、
  「反映済み」断定×ref未到達=INFO（ref stale の可能性があるため block しない）

## 追加 (2026-07-16)

- `60_dormant_repo_write`（FAIL＋INFO・状態突合＋process-evidence型）: 休眠保存が裁定された
  repo（`dormant_repos.txt`・出所コメント必須）の worktree dirty × セッション内書込様
  tool_use 証拠 = FAIL、書込様証拠なしの dirty = INFO。断定の真偽ではなく「休眠repoへ
  書いた」行為を検出する拡張（incident: 2026-07-16 E-20990101000003-acda で CC が
  休眠裁定済み project-b へ実装 handoff・非git manifest 作成。owner 指摘で停止）。
## 追加 (2026-07-19)

- `80_fabricated_tool_result`（FAIL＋INFO・protocol-leak型＋process-evidence型）: 最終応答の地の文に
  「ツール実行結果を模した塊」が混入していないかを検出する。tool_result は harness が枠外(tool_result
  チャネル)で注入するもので、地の文にツール結果様の構造が現れるのはツール出力の代筆＝捏造の疑いが強い
  （cc/CLAUDE.md Output Integrity I001/I002 の検出層）。**FAIL A（protocol-markup leak）**: harness の
  ツール呼出/結果マークアップ（invoke/function_calls/function_results/parameter タグ）が地の文に生で出現。
  inline-code・fenced code を除去した散文に対して突合するため、本 checker やその設計の meta 議論はトークンを
  backtick/fence する限り除去後の散文に残らず素通しになる（誤爆回避）。**FAIL B（output-without-tool・
  process-evidence型）**: ツール結果様 JSON（"success" ＋ tradingview 固有キー
  tab_id/chart_id/tab_index/sessionId/targetId）を提示しているのに transcript に "type":"tool_use" が
  1件も無い（＝1つもツールを実行せず結果を提示）。transcript 不在なら判定しない(fail-open)。**INFO C**: 同
  JSON があり tool_use が在る場合は、正当な引用と捏造を機械判別できないため INFO 並記に留める(block しない)。
  incident: 2026-07-19（本 checker 発注セッション）——直前 session で Bash/Read が空返し＋英語ナラティブ注入
  （プロンプトインジェクション疑い）を受け、モデルが tab_list 結果「両タブとも AMEX:VDE」を地の文で捏造。
  ツール実行済み・結果汚染下でモデルが尤もらしい結果を再構成する中核型は本 checker では INFO 止まりのため
  UNCOVERED.md に残余記帳（将来 work: 実 tool_result との突合・注入署名検出）。tests: T29-T36
  （陽性 A/B・backtick/fence 誤爆回避・INFO 方向・fail-open・通常応答）。



## 追加 (2026-08-06)

- `94_response_date_header`（FAIL・process-evidence 型〈値一致〉）: 応答冒頭3行の日時ヘッダ
  （yyyy/MM/dd H:mm[:ss]・ユーザー対応方針の必須表示）の値を、transcript の**直近の生ユーザー
  発話以降**の行と突合する（時を2桁正規化・秒なしは分精度前方一致）。不在 = FAIL（メッセージは
  2種: セッション全体にも無い=未実行の捏造疑い／発話前にのみ在る=過去ターン値の使い回し疑い）。
  ヘッダ不在の応答は判定しない（不在の強制は全プロジェクト共通 Stop hook では摩擦過大 →
  UNCOVERED 受容）。生ユーザー発話 = '"type":"user"' を含み '"tool_result"' を含まない行。
  fail-open: transcript 不在。incident: 2026-08-06 00:47 頃——ヘッダ時刻 0:47:03 を bash date
  未実行のまま記載（実測列 00:39:37→00:46:18 のどこにも無い値・自己申告で発覚）。
  tests: T64-T66・T70（陽性=実 incident 値/ゼロ詰め差吸収の陰性/ヘッダ無し陰性/使い回し陽性）。
## 追加 (2026-08-09)

- `96_presented_reference`（FAIL・自己完結型）: コピー用実体への「上記」参照（上記＋対象語
  rclone|コマンド|トリガー＋行為語 実行|コピ|貼）と既提示主張（提示済|表示済|掲載済|再掲済＋対象語）を
  含む応答が、fenced code block（行頭空白＋``` で始まる行が2行以上）を伴わなければ差し戻す。過去ターンの
  表示成否は機械検証不能（テキストを書いてもツール実行を続けたターンの本文は画面に出ないことがある）ため、
  ground truth を「参照・主張する応答自身がコピー可能な実体を再掲しているか」に置く（『書いた』でなく
  『届いた』の担保）。負ガード=文に（誤|訂正|指摘|反論）を含めばスキップ（振り返りの誤爆回避）。前処理で
  fenced block・inline code を除去するためメタ議論はトークンを backtick で囲めば素通し（80 と同方針）。
  fence があれば内容の同一性は検証しない（取りこぼし側へ倒す）。散文中の三連バッククォート言及・
  未クローズ fence は実体と数えない（FAIL 側へ倒す）。incident: 2026-08-09——ex-send の
  HUMAN_WRITE_COMMAND（rclone コマンド）を agmsg 送信ツール実行と同一ターンの本文に書いたため画面未表示の
  まま「上記 rclone コマンドの実行」と参照し、「表示されていない」との指摘へ「提示済み」と過去の自分の
  出力を根拠に反論した（tasks/lessons.md 2026/08/09・owner 指示「『上記』『提示済』で checker 作って」で
  checker 化）。検証レビュー（Codex）: 初回 BLOCKING 1件（fence 判定 `grep -q` の部分一致が散文中の
  ``` 言及1箇所で素通り・Codex 実測入力つき）→ 行トグル規則の2行以上判定へ修正し T78/T79 を追加 →
  再レビュー BLOCKING 0件（agmsg 2026-08-09T13:33:52Z）。tests: T71-T79（陽性4=実 incident 文・提示済
  主張・``` 言及迂回・未クローズ fence／陰性5=fence 同伴再掲・backtick メタ議論・振り返り文・対象語なし上記）。

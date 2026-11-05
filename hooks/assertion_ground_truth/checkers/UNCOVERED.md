> 公開版の注記: 本文中の 40・90〜93・95・99 などは、公開版から外した checker です（元の環境に固有の仕組みが対象のため）。

# 検出不能として受容した断定型（台帳）

機械的 ground truth が存在せず checker 化できない断定型の記録。
cc/CLAUDE.md 実装規律2項「防止できないことを明示して受容する」に基づく。
露見時は即訂正し、本台帳を再評価する（checker 化できる部分型が見つかれば移す）。

| 断定型 | incident | 受容理由 |
|-|-|-|
| ツール/skill の能力・スコープ断定 | agmsg「CC↔CC専用」捏造 (2026-06-01) | 正否の正本が SKILL.md 等の自然言語文書。機械突合には自然言語理解が必要で、モデルの再導入（自己裁定問題）になる |
| コマンド引数シグネチャの推測使用 | watch.sh の引数流用→全呼び出し空振りを「no messages」と事実報告 (2026-06-01) | 呼び出し前の署名照合は生成時点で強制不能。--help 照合の義務は散文指示（遵守天井の内側） |
| リモート状態の断定のうち ISSUE 等の機械抽出可能なアンカーを含まない一般形（やった/やってない） | 00fd incident (2026-07-15) の一般化 | アンカーが無い断定は claim 検出が自然言語理解になる。ISSUE つき送達断定は 40_delivery_claim_evidence（process-evidence型＝真偽でなく確認行為の有無を突合・owner 提案）で被覆済み。記録側の即時更新（送達完了時に「残」を消す）も併用 |

被覆済みへ移った型:
- commit SHA を伴う push/origin 反映状態の断定 → `50_push_state_vs_origin`
  （incident: 2026-07-15 22:25 state-push 済み（origin/main=fe8ac9c）の f062409〜fe8ac9c を
  「origin 未反映・push待ち」と誤報。21:43 測定の使い回しで、Stop時点の remote-tracking ref
  1回の照合で防げた。SHA アンカー無しの一般形「push待ち」は引き続き上表3行目の受容範囲）
- パス実在の否定断定 → `20_negation_vs_exists`
  （incident: 2026-07-14 project-a READ_FIRST.html「11本リンク切れ」誤断定・全11件実在）
- 封筒 ISSUE の送達状態断定 → `40_delivery_claim_evidence`（process-evidence型）
  （incident: 2026-07-15 E-20990101000002-edb6「送達が残」誤報・実際は前日送達済み。
  当初は本台帳に「checker 化不成立」と記帳したが、owner 提案「実物チェック済みかを確認すればよい」で被覆化）

追加受容 (2026-07-16):

| 断定型 | incident | 受容理由 |
|-|-|-|
| 委譲経路の選択誤り（agmsg 体制下での codex exec 新規 spawn） | 2026-07-16 E-20990101000003-acda セッション。project-e チームで codex-main 待機中に CC が codex exec を spawn（owner 指摘で切替・部分ファイル撤去） | 「どちらの経路が正しいか」は体制・意図の文脈判断で機械 ground truth が無い（正当な fresh spawn も存在する）。予防は PreToolUse hook（Bash `codex exec` × agmsg 登録済み codex agent の照合警告）で原理的に可能だが、hook 新設の settings 配線は owner 手動（project-a 運用先例 2026/07/12）のためバックログとして報告（実装規律5項）。散文層は memory feedback-codex-via-agmsg-when-team-waiting と project-a lessons に記録 |

追加受容 (2026-07-19):

| 断定型 | incident | 受容理由 |
|-|-|-|
| チャネル汚染下でツール実行済み・結果が空/汚染のとき、モデルが尤もらしいツール結果を地の文で再構成する型 | 2026-07-19 直前 session。Bash/Read 空返し＋英語ナラティブ注入（プロンプトインジェクション疑い）下で tab_list 結果「両タブとも AMEX:VDE」を地の文で捏造 | `80_fabricated_tool_result` が FAIL A（地の文の生 protocol markup）と FAIL B（tool_use ゼロでの結果提示）を被覆。ただし tool_use が在り結果のみ汚染された本 incident 中核型は、地の文の主張と実 tool_result 内容の突合が自然言語照合になるため FAIL 化せず INFO 止まり。ground truth（実 tool_result）は transcript に在るので将来 work: tool_result の空/エラー検出＋主張照合、または tool channel 側の注入署名検出（後者は grep で本文に注入語を含む正当な結果と衝突しうるため要精度設計） |

追加受容 (2026-08-05):

| 断定型 | incident | 受容理由 |
|-|-|-|
| 目的より検証容易性を優先する設計選択の一般形（PL-08: 効率・検証のしやすさへ逃げて成果物の目的を満たさない） | 2026-08-05 E-20990101000016-1731 Task 1。人間用 html 化を diff ゼロ検証が容易な pre 逐語格納で実装（project-a 66a87df）。owner 指摘で fc2271d のレンダリング版へ差し替え | 「選択が目的を犠牲にしたか」は意味論的判定で機械 ground truth が無い（散文指示の遵守天井）。狭い形は checker 化済み: `91_human_html_structure`（md-as-pre 構造の検出）＋ `92_human_html_purpose_axes`（完了報告封筒の目的適合/忠実性2軸判定の欠落検出）。散文層= lessons/lessons.md PL-08・レビュー依頼契約への目的記載必須化（cc/CLAUDE.md 改訂・owner 適用）。候補集合は発想レビュー6巡・25件で棄却前確認済み（2026-08-05） |

追加受容 (2026-08-06):

| 断定型 | incident | 受容理由 |
|-|-|-|
| 日時ヘッダの不在（表示義務の不履行） | 2026-08-05 深夜セッション序盤の複数応答でヘッダ欠落（同セッション後半の値捏造は 94 が被覆） | `94_response_date_header` は存在するヘッダの真正性のみ検査する。不在の強制は本 hook が全プロジェクト共通 Stop であるため摩擦過大（ヘッダ規則はユーザー対応方針由来で、短い相槌応答や別文脈まで一律 block になる）。散文層=cc/CLAUDE.md ユーザー対応方針 |
| 「人間実行待ち」項目の完了実態の一般形 | 2026-08-06 owner 発案「対象が毎回違うから難しいか」 | 対象が毎回異なり機械 ground truth が定まらない。狭い形を2段で被覆: `95_human_pending_ledger`=宣言時記帳の強制（record-evidence）・`../sweep_human_pending.sh`=登録時に必須化した完了判定コマンド（read-only・exit 0=完了）の一括実行。完了判定コマンドを書けない項目はそもそも台帳登録不可であり、その型は残余として受容 |

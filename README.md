# assertion-ground-truth

[English] | [日本語](README.ja.md)

A **Claude Code Stop hook** that checks the assertions in an AI agent's final reply ("pushed", "the file does not exist", "sent", "done") against the actual state of the machine and the session transcript, and sends the reply back to the agent when they contradict.

This is a public extract from a personal setup. **I am looking for feedback on the design** — please use [Discussions](../../discussions).

## Why

- A wrong factual claim in generated text cannot be prevented by a pre-execution guard. So this sits *after* generation, as a detection layer.
- One checker per *type* of assertion. Every time a new failure shows up, add a checker and its tests, and the coverage grows.
- Assertion types with no machine-checkable ground truth are listed in `checkers/UNCOVERED.md` as "not covered", explicitly.
- Ground truth is not only the file system or git. Some checkers are *process-evidence* checks: "did the agent actually run a verifying tool call before making this claim?", read from `tool_use` entries in the transcript.

## Language support — please read

The original setup runs in **Japanese**, and most checkers match Japanese wording.

| Checker | English replies |
|---|---|
| `10_path_exists` (INFO: lists whether each path in the reply exists) | works (language-independent) |
| `20_negation_vs_exists` (FAIL: "does not exist / not found / no such file" next to a path that exists) | **works** (bilingual vocabulary, tested) |
| `30_git_sha_cited` (INFO: cited commit hashes that do not resolve) | works (language-independent) |
| `50_push_state_vs_origin` ("pushed / not pushed" vs. remote-tracking ref) | **Japanese only**, except `ahead=N` |
| `97_stop_phrase` (reply ends by handing a decision back to the human) | **Japanese only** (`checkers/stop_phrases*.txt`) |
| 60, 80, 94, 96, 98 | not tested with English replies; most use Japanese wording |

So in an English session, out of the box, you mainly get 10/20/30. Adding English vocabulary to the other checkers is a small, well-defined change (each checker keeps its patterns in one or two variables), and contributions or opinions on how to make this language-neutral are very welcome.

Code comments and design notes are in Japanese.

## Layout

```
hooks/assertion_ground_truth/
  dispatch.py          The Stop hook. Runs checkers/*.sh in filename order; any FAIL → decision:block
  checkers/            One checker per assertion type, plus their config and ledgers
    README.md          Checker contract and how to add one (Japanese)
    UNCOVERED.md       Assertion types judged not coverable (Japanese)
  tests/               Positive and negative tests
  stop_phrase_*.py     Baseline and backtest for checker 97
  DESIGN_stop_phrase_rerun.md  Design of the re-run after a block (Japanese)
```

Checker contract:

- stdin: the final reply text
- env: `AGT_CWD` (session cwd), `AGT_TRANSCRIPT` (path to the transcript .jsonl)
- stdout: one finding per line, `LEVEL<TAB>slug<TAB>detail`. `FAIL` blocks the reply; `INFO` is attached as context
- exit codes are ignored (fail-open: a broken checker never breaks the reply). Timeout is 10 s per checker

## Install

1. Put this repository anywhere (e.g. `~/agt`).
2. Register the Stop hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "python3 /home/you/agt/hooks/assertion_ground_truth/dispatch.py" } ] }
    ]
  }
}
```

3. `checkers/dormant_repos.txt` (used by checker 60) contains an example only. Edit them for your environment, or remove checkers you do not need.

| Variable | Purpose | Default |
|---|---|---|
| `AGT_STATE_ROOT` | Root for observation logs and inboxes | repository root |
| other `AGT_*_FILE` etc. | Ledger locations | see the header comment of each checker |

## Tests

```bash
bash hooks/assertion_ground_truth/tests/test_assertion_ground_truth.sh
bash hooks/assertion_ground_truth/tests/test_dispatch_rerun.sh
bash hooks/assertion_ground_truth/tests/test_block_followup_join.sh
```

Known failures at publication: `T129` and `T6` also fail in the original environment.

## Caveats

- Checkers built for mechanisms specific to the original machine (rclone, the inter-agent "envelope" exchange, a shared glossary, a human-pending ledger, agmsg — checkers 40, 45, 70, 90–93, 95, 99) are not included.
- Some included checkers enforce rules from the original `CLAUDE.md`: 94 expects every reply to start with a date header taken from `date`, and 98 expects `grep`/`find` in reported commands to be prefixed with `command`. Remove them if you do not have those rules.
- IDs like `E-2099…`, names like `project-a`, and references to `projects/…` are redactions of the original records. The referenced files are not included. Commit hashes in comments refer to the original repository.
- This targets Claude Code. The Codex CLI–side hook is not included.

## Feedback I am looking for

1. Is a post-generation "detect and send back" layer a sound design (fail-open, FAIL/INFO levels, growing by adding checkers)?
2. How would you measure the balance between false blocks and misses?
3. How should the re-run limit after a block (`max_chain`, checker 97) be decided?
4. Other approaches for assertion types with no machine ground truth (`UNCOVERED.md`)?
5. How to make the checkers language-neutral instead of keeping per-language vocabularies?

## License

MIT (see `LICENSE`)

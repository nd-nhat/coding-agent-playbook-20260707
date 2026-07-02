---
name: a2a-review
description: "Sends a file path, diff, or code instruction to a codex (OpenAI) reviewer running in a separate sbx microVM that reads the same live source tree, and returns its findings as an issue list or LGTM. A fast codex-only second opinion to fire mid-implementation. Use when the user asks for a codex review or second opinion on specific code, mentions a2a review / codex review / 別の目で見て / codex にレビューさせて, or to cross-check code with codex before committing. A thin wrapper over scripts/internal/a2a-review.sh (leaf-layer skill per rules/skills.md, not an orchestrator); codex reads the same source claude is editing."
---

# a2a-review

codex (OpenAI) を別 sbx microVM の A2A server に立て、**claude が編集中の同一ソースツリーを codex 自身が直接読んで**レビューさせる。外部 AI 多重レビューに対し、**codex 1 体の速い second opinion** を実装の途中で投げるための daily tool。`tools/a2a-review/` の参照実装を host helper `scripts/internal/a2a-review.sh` 経由で呼ぶ薄い wrapper（leaf 層、[rules/skills.md](../../../rules/skills.md) 参照）で、A2A のロジックは再実装しない。

## 前提条件（box の中から自動で揃う）

本 skill は **`bash scripts/dev.sh` (auto-name) または `bash scripts/dev.sh <NAME>` (明示名) で起動した dev box (bind-mount) の中から呼ぶ**ことを想定する。dev.sh が起動時に対応する **`cdx-<NAME>` reviewer box** を auto-provision し、`pair-serve` を bg fork して egress 許可と advertise URL (`$A2A_CODEX_URL`) を box の env に注入する (per-pair lifecycle、claude box TTY 終了で auto teardown)。

事前準備 (host 側で一度だけ):
- `sbx` (Docker Sandboxes) + image `coding-agent-playbook-sbx` が load 済み
- openai OAuth secret 登録済み: `sbx secret set -g openai --oauth`

これらが揃っていれば `bash scripts/dev.sh` 起動時に **cdx-`<NAME>` reviewer box が auto-provision される** (初回 ~30s、以降は再利用)。事前の手動 setup は不要。

sandbox box (`bash scripts/dev.sh sandbox`、`--clone .` 隔離) では本 skill は使えない (sandbox box は host checkout を mount しないため codex が claude の編集を見られない)。dev box (`bash scripts/dev.sh` 系統) を使うこと。

**reviewer の所在 (混同しがちなので明示)**: codex reviewer は **claude が動いている box とは別の sbx microVM** (`cdx-<NAME>`) で動く。自 box (claude box) の中から `ps aux | grep cdx` / `pgrep` 等を叩いても reviewer process は**原理的に見えない** (microVM の PID namespace は隔離されている)。reviewer の生死は **lease ファイル (`.claude/tmp/cdx-serve-<NAME>.lease`) の advertise URL に対する agent-card probe** でしか分からない。本 skill 起動前に自 box 内 `ps` で down 判定して skip するのは誤り ([../../../rules/pr-followup.md](../../../rules/pr-followup.md) 「禁止する自己判断」参照)。reviewer 健康確認は本 skill 自身 (step 3 で `ask` invoke → reachability 確認) + caller orchestrator (`/pr-codex-ci` step 1a の lease 確認) に委ねる。

## 使い方

引数 = レビュー対象。repo-root 相対のファイルパス / `diff` / 自由な指示文（日本語可）。引数が空なら何をレビューするか先に聞く。

### 手順

1. **環境チェック**: 自分が動いている box が dev box (bind-mount、`$SANDBOX_VM_ID` set かつ `bash scripts/dev.sh` で起動された) かを確認する。sandbox box (`bash scripts/dev.sh sandbox` 起動の `--clone .` box、box 名が `sbx-` prefix) の中なら本 skill を停止し HOTL escalate:
   > 「現 box は sandbox / clone mode (host checkout を mount しないため codex から不可視) です。`/a2a-review` を使うには dev box で起動してください: host で `bash scripts/dev.sh` を新規起動するか、`bash scripts/dev.sh attach` で既存 dev box に attach してください。」

2. **指示文の組み立て** (下記「指示文の組み立て」参照)

3. **実行**: `bash scripts/internal/a2a-review.sh ask "<instruction>"` (Windows: `powershell -ExecutionPolicy Bypass -File scripts/internal/a2a-review.ps1 ask "<instruction>"`)。URL は `$A2A_CODEX_URL` env (dev.sh の pair-serve が注入) か fallback `http://host.docker.internal:9999`。

4. **reviewer 未到達時** (接続不可 / "Blocked by network policy" / 空応答): 本 skill を停止し HOTL escalate メッセージを出す (黙って止まらない / 選択肢を出さない)。**escalate を出す前に、box 内で `echo $SANDBOX_VM_ID` の値を取得し、メッセージ内の `<box-name>` placeholder を実 box 名 (リテラル) で置換すること** (host shell には `$SANDBOX_VM_ID` env が無いため、literal を貼らないと空展開で別 session に化ける):
   > 「box 内から codex reviewer に到達できません (cdx-`<box-name>` reviewer box が起動していないか、`sbx policy allow network` の egress 許可が無い可能性)。recovery は box 内 dev session と active lock が dev.sh 再起動を block するため**順序が重要**です:
   > 1. **box の terminal で Ctrl-D (または `exit`)** で claude を抜けて dev.sh を正常終了させる (trap が pair-teardown + lock 削除を走らせる)
   > 2. host で **`bash scripts/dev.sh <box-name>`** を再起動 (新 lock 取得 + cdx pair 再 provision + pair-serve 再 fork)
   > 3. 起動後 claude が立ち上がったら、呼び出し元の skill / `/pr-codex-ci` を再度叩いてください
   >
   > もし box 内 dev session が hang していて exit できない場合は、host で `sbx rm -f <box-name>` で box を強制終了 → step 2 に進む (state は失われます)。」

5. 下記「結果提示」

**指示文の組み立て**: 引数を 1 つの review 指示文にする。codex はコード片を貼られず同一ソースを自分で読むので、**パス/diff を指示で渡す**:
- ファイル: `tools/a2a-review/codex-a2a-server/server.py を correctness / edge-case 観点でレビューして`
- diff: `git の HEAD の diff をレビューして` (box は main checkout root を mount するので、worktree の diff は `git -C .worktrees/<NN>/ diff HEAD をレビューして` のように `-C` でツリーを明示する)

**結果提示**: codex の最終 artifact (指摘 or LGTM) を要約してユーザーに返す。codex の指摘は **second opinion** であり、採否は claude / ユーザーが判断する (AI 1 体の指摘を独立根拠にしない)。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `box 内から codex reviewer に到達できません` | 上記 HOTL escalate メッセージに従う (host で `bash scripts/dev.sh <box-name>` 再起動。`<box-name>` は box 内 `echo $SANDBOX_VM_ID` の literal で置換) |
| `cdx-<NAME>` box が auto-provision されなかった | host で openai secret 登録確認: `sbx secret ls -g \| grep openai`、未登録なら `sbx secret set -g openai --oauth` |
| `server が起動しません` | host log (`.claude/tmp/cdx-serve-<NAME>.log` = pair-serve の sbx ports / policy / 起動 echo) と box log (`sbx exec cdx-<NAME> cat /tmp/a2a-server.log` = server.py 内部) の両方を確認 |
| 別ツリー (worktree 等) をレビューしたい | box は main checkout root を mount するため、`.worktrees/<NN>/...` の repo-root 相対パスで指示する |
| 指示にダブルクォートが含まれて崩れる | instruction を全体としてダブルクォートで囲む。内側はシングルクォートか「」を使う |

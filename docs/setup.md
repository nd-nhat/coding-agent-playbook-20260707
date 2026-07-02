# Setup 詳細

[README](../README.md) §1 の Quick start で扱わない補足。秘密情報の権限根拠、cdx-`<NAME>` pair reviewer の運用、image / claude / codex の更新手順。

## 認証 secret の詳細

box 起動時に sbx が自動で box に provision するため、毎回 `/login` / GitHub 認証する必要なし。**secret はグローバルでも box の作成時にのみ provision される**ため、`scripts/dev.sh` で box を立てる前に下記 3 つの secret (anthropic / github / openai) を登録しておく必要がある (後から登録すると box を再作成しないと反映されない)。**API key 経路 / 箱内 /login 経路 / codex サブスク (`~/.codex/auth.json` 転送) 経路の使い分け** は [sbx/README.md](../sbx/README.md) 「認証」セクション参照。

### anthropic (claude を box の中で動かす)

```bash
claude setup-token                         # 長期トークン sk-ant-oat01-... を発行 (host で 1 回)
sbx secret set -g anthropic                # 表示されたトークンを貼る
```

長期トークンを発行せず API key 経路で済ませたい場合は、`claude setup-token` の代わりに [sbx/README.md 経路 A](../sbx/README.md#経路-a-api-keyproxy-注入トークンは-box-に入らない) (`sbx secret set -g anthropic` に API key を貼る) に置き換える。この場合 `claude` CLI の host install は省略可。

### github (PR 操作)

[README](../README.md) §3 の PR フローで box の中の `gh pr create` / `gh pr checks` / `gh run view` が叩く。**fine-grained PAT** ([https://github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)) を発行する:

- **Repository access**: 本リポ (fork なら自分のコピー) のみに限定
- **Permissions** (Repository permissions):
  - Contents: Read and write — `gh pr create` / `git push` 用
  - Pull requests: Read and write — `gh pr create` / `gh pr edit` / `gh pr comment` / `gh pr merge` 用
  - Issues: Read and write — レビュー由来の backlog を box 内から `gh issue create` で起票する用（無いと `Resource not accessible by personal access token (createIssue)` で失敗する）
  - Actions: Read-only — `gh pr checks` の statusCheckRollup / `gh run view --log` の CI 失敗診断用
  - Commit statuses: Read-only — legacy status check API (`gh pr checks` が併用)
  - (Metadata: Read-only は自動付与)
- **Expiration**: 90 日程度を推奨 (期限切れたら再発行 + 再登録)

発行された PAT (`github_pat_...`) を `sbx secret` に貼る:

```bash
sbx secret set -g github                   # 表示されたプロンプトに PAT を貼る
```

> ℹ️ **fine-grained PAT を選ぶ理由**: classic PAT や `gh auth login` 由来の OAuth token はアカウント全体の repo に対する scope を持つため、box 内 (YOLO 実行) で乗っ取られると blast radius が大きい。fine-grained PAT は対象 repo + 必要権限のみに絞れるため、box から抜けた攻撃者が触れる範囲を構造的に最小化できる ([Docker Sandboxes 公式ガイダンス](https://docs.docker.com/ai/sandboxes/security/credentials/) の最小権限原則と同型)。期限を切ることで漏洩時の有効期間も bound できる。

### github を App identity 化する (opt-in・canonical repo)

上記 PAT だと PR author = 自分になり、GitHub の self-approve 禁止で human approval を **機械強制 gate にできない** ([repo-settings.md](repo-settings.md) 原則 1)。box を **GitHub App bot** で回すと author=bot になり human approve が satisfiable な gate になる (設計根拠と trade-off は [decisions/app-identity-gate.md](decisions/app-identity-gate.md))。canonical repo で使う時だけの opt-in:

1. **GitHub App 作成** (org/account の設定画面。box からは不可): Repository permissions は**上記 PAT と同じ**セット = `Contents: RW` + `Pull requests: RW` + `Issues: RW` + `Actions: Read` + `Commit statuses: Read` (`Workflows` / `Administration` は付けない = 原則 3/4)、install は本 repo のみ。App ID と private key (.pem) を控える。
2. **broker config** (gitignore・per-machine): `.claude/app-broker.local.json.example` を `.claude/app-broker.local.json` にコピーし `appId` + `keyPath` (host の .pem 絶対パス) を記入 (owner/repo は origin remote から自動導出)。private key は **host のみ**に置き、box に配らない / commit しない。
3. **有効化 marker** (box 単位 / 全 box):

```bash
sbx secret set-custom <box> --host app-identity.invalid --env APP_IDENTITY_ENABLE --value 1   # -g で全 box
```

marker が立つ box で `scripts/dev.sh` 起動時に broker (`scripts/internal/app-token-broker.js`) が bg 起動し、per-box github secret を App installation token に live 更新する (~50min refresh)。box は sentinel のまま author=bot。marker 無し = 現行 PAT のまま (fail-open)。box を抜けると teardown で per-box secret を除去して PAT に戻す。

4. **gate 有効化** (最後・手動): App 発 PR を human approve できるのを実運用で確認後、ruleset の `required_approving_review_count` を 0→1 にする ([repo-settings.md](repo-settings.md) の App-gate 節)。**本 canonical repo では一度実施したが、PAT fallback 経路との衝突により revert 済み** ([decisions/app-identity-gate.md](decisions/app-identity-gate.md) 「残差・未決」参照)。**再有効化の条件は「全 box が常時 marker 有効」だけでは不十分**: host session（本 repo の場合、`/pr-ci` 等が host `codex` CLI 直で動く経路）が author=owner PAT で PR を作る経路も存在し、box を全て marker 有効化しても host 発 PR は同じ deadlock を再現する。再有効化するなら host session 発 PR にも App bot（または別アカウント）からの approve 手段を用意してから行う。

> ℹ️ marker の presence で切り分けるのは、host が sbx secret の**値**を読めない (masked) 一方 **presence は `sbx secret ls` で読める**ため。手動 `dev.sh` でも Claude 経由でも効き、per-box で永続する。

### openai (codex review = /a2a-review / /pr-codex-ci)

```bash
sbx secret set -g openai --oauth           # browser で ChatGPT 認証 (codex CLI と同じフロー、サブスク経路推奨)
```

## cdx-`<NAME>` pair reviewer の運用 (per-pair lifecycle)

codex second-opinion (`/a2a-review` / `/pr-codex-ci`、[README](../README.md) §3 の PR フロー step 4) は **claude box `<NAME>` とペアの codex box `cdx-<NAME>`** に立てた A2A server に instruction を投げる構成。

**per-pair lifecycle**:

- **起動**: `bash scripts/dev.sh` (引数なし、自動命名) または `bash scripts/dev.sh <NAME>` (明示名、bind-mount path) を叩くと dev.sh が auto で `cdx-<NAME>` を pair-setup し、`pair-serve` (server 起動 + host port を kernel ephemeral で publish + claude box の egress 許可 + lease file 書き込み) を子プロセスとして bg fork する (初回 ~30s、以降は box 再利用で速い)。
- **使用中**: claude box の env に `$A2A_CODEX_URL=http://host.docker.internal:<port>` が注入され、`/a2a-review` (= `bash scripts/internal/a2a-review.sh ask`) が透過的に reach する。並列で別 `<NAME>` を起動しても各 pair が独立 port を持ち干渉しない (debate 2026-06-27 で確定した per-pair 設計、port は dynamic ephemeral)。
- **終了**: claude box の TTY を抜けると `sbx run` が return し、dev.sh の trap で `pair-teardown` (server 停止 + `cdx-<NAME>` box 削除 + lease 削除) が走る。orphan reviewer box が残らない。明示停止は `bash scripts/dev.sh kill <NAME|N>`。

手動で reviewer box を立てる必要はない (上記 lifecycle 通り auto)。Host で常駐 daemon / launchd / systemd を入れない方針 (workshop premise: clone するだけで揃う、PR #68/#70 で revert 済みの方向と整合)。

> ⚠️ **openai secret を rotate / 更新した場合は既存 `cdx-<NAME>` box を破棄する必要がある**: secret は box 作成時に provision される設計のため、rotate 後の既存 box は古い credential のまま固定される (`/a2a-review` が後で fail する原因)。`bash scripts/dev.sh <NAME>` を抜けて `cdx-<NAME>` が auto-teardown されれば、次回起動で新 secret で auto-provision される。手動破棄: `sbx rm -f cdx-<NAME>` (または `bash scripts/dev.sh kill <NAME>`)。
>
> ⚠️ **sandbox box (`bash scripts/dev.sh sandbox`) では pair reviewer が無い**: sandbox は `--clone .` で起動し host checkout を mount しないため codex から claude の編集が見えず、`/a2a-review` / `/pr-codex-ci` は使えない。reviewer が要るときは dev box (`bash scripts/dev.sh`) を使う ([parallel.md](parallel.md))。

## image / claude / codex の更新 (たまに)

macOS / Linux / Git Bash (Windows):

```bash
bash scripts/build-image.sh                # image rebuild + sbx template 再 load (1 行)
bash scripts/dev.sh ls                     # 旧 image で立てた dev box の一覧
bash scripts/dev.sh kill <NAME|N>          # 旧 dev box を破棄 (cdx-<NAME> pair も同時破棄、state は失われる)
bash scripts/dev.sh                        # 新 image で再作成 (引数なし = 自動命名 dev box)
# sandbox box (clone) は dev.sh ls に出ない。残っている場合は `sbx ls` で確認して `sbx rm <生成名>` で別途整理
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-image.ps1
powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 ls
powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 kill <NAME|N>
powershell -ExecutionPolicy Bypass -File scripts/dev.ps1
# Optional cleanup of ad-hoc sandbox boxes: sbx ls; sbx rm <generated name>
```

`scripts/build-image.sh` は `AGENT_CACHEBUST` で installer layer の cache を破棄し、上流の apt / Chromium は cache 再利用 (重い layer を毎回 download しない)。

# 決定記録: 安全に並列化した coding agent / HOTL の実行基盤

**ステータス: Accepted（2026-06-18）** — 下記「検証ゲート (spike)」を実機で通過し、sbx (Docker Sandboxes) を実行基盤として採用。これに伴い [devcontainer-sandbox.md](devcontainer-sandbox.md) の `.devcontainer/` は撤去した（soft boundary は並列 HOTL に構造的に不足するため、2 系統を持たない = YAGNI）。検証結果は末尾「検証ゲート (spike)」の各項に記録。

## 背景: 目的の明確化

[devcontainer-sandbox.md](devcontainer-sandbox.md) は `.devcontainer/` を「Claude Code を隔離環境で安全に回す
実行基盤」として main に置く決定で、教材性は限界節の「teaching workshop 用途として defense-in-depth で受容する」に
留まる。本記録はこの「自作 sandbox を安全な実行基盤とする」前提を、オーナーが表明した**目的の更新**で上書きする:

> 目指すのは **安全に並列化した coding agent**、そして **HOTL (Human-On-The-Loop)**。

つまりゴールは「sandbox の primitive を教えること」ではなく「**多数の agent を安全に並列で回し、人間は逐次承認ではなく
監視・介入の立場 (on the loop) に立つ**」運用を成立させること。教材はその destination に到達するための手段。

## 判断軸: HOTL は「境界の硬さ」を要求する

HOTL の本質は **1 アクションごとの人間承認ゲートを外す** こと（= 既存 box-primary の YOLO 運用の延長）。
承認ゲートが無くなると、安全性は **境界が「侵害された agent」に対して持ちこたえるか** だけで決まる。
並列度が上がるほど「全 agent を常時凝視する」のは非現実的になり、**監視の薄さを境界の硬さで補う** 必要がある。

## 現状 (自作 devcontainer) の限界

自作 firewall は **defense-in-depth であって hard boundary ではない**。箱の中の `node` は passwordless root sudo と
docker 権限を持つため、乗っ取られた agent は `sudo iptables -F` / `docker run --network host` で egress を破壊できる
（[devcontainer-sandbox.md](devcontainer-sandbox.md) 「限界」参照）。**人間が密に監視していれば**気づけるが、
**並列 HOTL では監視が薄くなる**ため、soft boundary は構造的に不足する。

## 候補比較

| 観点 | 自作 devcontainer | Docker Sandboxes (sbx) |
|------|------------------|------------------------|
| 並列 | worktree ごと box（手組み・可） | clone mode / 複数 microVM（並列がファーストクラス） |
| HOTL の安全境界 | **soft**（root agent が破れる）→ 密な監視前提 | **hard**（hypervisor 境界、VM 内 root でも破れない） |
| credential | 箱内（scope で律速） | 箱外注入（sentinel + proxy）が既定で真の隔離。但し proxy 注入の対象は API key のみで、サブスク認証（claude サブスク = 箱内 /login、codex サブスク = auth.json 転送）はトークンが箱内に入る（sbx/README.md の security 注記参照） |
| microservices | DinD で箱内 compose 可 | sandbox 内 Docker engine で箱内 compose 可 |
| 配布 | repo に同梱（clone だけ）+ host に Docker | host に sbx を別途導入（brew/winget）+ 認証 |
| 成熟度 | 自前管理 | GA 2026-01-30（新しめ）。商用 pricing は未確定 |

sbx は "Run AI Coding Agents **Safely**" を掲げ、**microVM-per-agent の hypervisor 境界**を中核とする。
「承認ゲートを外して並列で回す」用途に対し設計思想が直接一致する。一方、host への別途導入と認証が要り
「clone するだけ」原則からは外れる。

## 方向 (Accepted)

1. **実行基盤は sbx を採用する**。HOTL の安全要件（侵害 agent に持ちこたえる hard boundary）と
   並列のしやすさ（microVM-per-agent）に対し purpose-built のため。`sbx/` に中立 `shell-docker` base の
   カスタム image（claude/codex 同梱）と codex egress mixin を置き、**built-in claude agent**
   （claude は API key を proxy 注入、サブスクは箱内 /login）で `sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .`
   起動する。codex のサブスクは host の `~/.codex/auth.json` を box に転送して使う（sbx/README.md 参照）。
2. **devcontainer (`.devcontainer/`) は撤去した**。sbx が spike を通過し採用された以上、劣る soft-boundary 側を
   残す既定の理由はない（YAGNI: sandbox を 2 系統持たない）。存続させる例外（配布障壁: sbx は host 導入＋認証が
   要るため「Docker のみで動く devcontainer を no-install fallback として残す」）も、**オーナー判断でその障壁を
   非問題とした**（spike #3 参照）ため適用せず撤去。「層を理解する教材として残す」は当初から存続理由にしない方針。
3. **PAT の scope 絞りは sbx 採用後も必須**。hypervisor 境界は token の流出・脱出は止めるが、
   乗っ取られた agent が **scope 内で git push する悪用は止まらない**（HOTL は人間ゲートが無い分むしろ重要）。
   fine-grained・対象 repo 限定・短命 PAT を併用する。

## 残差 (隔離しても消えない)

- **scope 内悪用**: 上記 3 のとおり、sbx でも token の scope 内での悪用（malicious commit / PR）は残る。
  blast radius は token の scope が律速。
- **許可ドメイン経由 exfil**: GitHub 許可 → gist 等は両構成で残る。

## 検証ゲート (spike) — 結果（2026-06-18 実機検証で通過）

macOS arm64 / sbx v0.32.0 で確認（sbx プラットフォームのゲート。現行構成は `sbx/` の shell-docker base カスタム image + multi-agent kit `playbook-kit`）。

1. ✅ **sbx 導入 → clone-mode sandbox 起動**: `sbx create --name <box> claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit --clone .` で複数箱を並存起動。
2. ✅ **並列 YOLO**: 複数 box を独立に起動し並走（box ごと 1 セッション、`sbx run <box>` で attach）。
3. ✅ **コスト / multi-user**: sbx は各自マシンでローカル実行（per-box 中央課金なし）。ローカル使用は実質無料
   （free Docker account の login のみ）、有料は不要な enterprise governance（Admin Console / AI Governance）のみ。
   実質的な並列上限は課金でなく各自の RAM（microVM-per-agent は RAM を食う。`--memory` で box ごとに絞る）。
   オーナー判断でコスト / 規模は非問題とした。残差: 公式 pricing 未確定（GA 2026-01-30 の新 product）。
4. ✅ **観測・介入 (HOTL の要)**: `sbx ls`（全 box の status / ports）・`sbx exec`（read-only 覗き）・`sbx run`
   （attach 介入）・`sbx ports --publish`（host browser）で、1 オペレータが数個の box を on the loop で回す用途に
   十分。ローカルにライブ集約 dashboard は無い（aggregated UI は有料 Admin Console のみ）が nice-to-have で blocker でない。
5. ✅ **host から in-sandbox dev server 閲覧**: 箱内 8080 を `sbx ports <box> --publish 8080` で host
   `127.0.0.1:<port>` に公開し、host curl / headful chrome で到達確認（escape hatch 成立）。
6. ✅ **箱内 compose stack（2 サービス）**: 箱内 docker (29.5.3) + compose (v5.1.4) で nginx + alpine の
   inter-service 疎通 OK。nested container の直接 egress も VM 境界で遮断（allowlist bypass 不能）を確認。

補足（egress 境界）: 箱内 runtime は default-deny + allowlist（anthropic / github / npm / docker は許可、それ以外は
proxy が 403 で能動拒否）。HTTP proxy `gateway.docker.internal:3128` 経由で TLS 傍受。コールド起動直後は proxy /
DinD が温まりきらず transient な失敗が出るが温まれば安定。

## Sources

- [https://docs.docker.com/ai/sandboxes/](https://docs.docker.com/ai/sandboxes/)
- [https://docs.docker.com/ai/sandboxes/security/isolation/](https://docs.docker.com/ai/sandboxes/security/isolation/)
- [https://docs.docker.com/ai/sandboxes/security/credentials/](https://docs.docker.com/ai/sandboxes/security/credentials/)
- [https://docs.docker.com/ai/sandboxes/workflows/](https://docs.docker.com/ai/sandboxes/workflows/)
- [https://github.com/dockersamples/sbx-quickstart](https://github.com/dockersamples/sbx-quickstart)
- [https://github.com/github/gh-aw-firewall/blob/main/docs/api-proxy-sidecar.md](https://github.com/github/gh-aw-firewall/blob/main/docs/api-proxy-sidecar.md)

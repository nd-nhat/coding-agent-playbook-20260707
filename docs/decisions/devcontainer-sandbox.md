# 決定記録: devcontainer サンドボックスを main の土台に置く

**ステータス: Superseded（2026-06-18）** — [parallel-hotl-execution.md](parallel-hotl-execution.md) が sbx (Docker Sandboxes) を実行基盤として Accepted にし、本記録の devcontainer サンドボックス（`.devcontainer/`）は repo から撤去された。soft boundary（自作 firewall は侵害 agent への hard boundary でない、下記「限界」参照）が並列 HOTL に構造的に不足するため。以下は撤去前の経緯として歴史的に残す。

## 決定

Claude Code を隔離環境で安全に回すための **devcontainer サンドボックス（`.devcontainer/`）を main にファウンデーションとして置く**。
stage 固有ではない。

理由: `stage/*` は base branch からの fork にすぎず、サンドボックスは playbook 全体で共有する実行基盤のため、
分岐元である main に最初から存在すべき。これは「main は講義進行ファイルのみ」という当初前提（`CLAUDE.md` の構成の前提）を、
オーナー判断で更新するもの。`.devcontainer/` は講義コンテンツでも特定 stage の project コードでもなく、**リポジトリ横断の実行環境**として扱う。

## 技術選定の結論（要約）

- 要件: ① Claude Code ② VM/container 隔離 ③ YOLO/auto-mode で安心 ④ Mac/Windows 両対応
- 結論: **公式 dev container（egress firewall 込み）**。Docker Desktop で Mac/Windows 同一、whole-process 隔離、
  `--dangerously-skip-permissions` を安全に回せる。クラウド可なら Claude Code on the web が対抗（管理 VM・設定ゼロ）。
- 不採用/限定: 組込み Bash sandbox 単体（Bash しか縛らず YOLO に不十分）、sandbox-runtime（native Windows 非対応・beta）、
  Edera 等カーネル隔離（Linux/K8s 専用）。

## 実機検証（2026-06-14, macOS arm64 / Docker 29.3 / `@devcontainers/cli` 0.87）

`up` → postStart 自動適用で以下を確認:

- Claude Code 2.1.177 導入（claude-code feature、PATH も機構任せで正常）
- 非 root（uid 1000 node）／ vanilla（`~/.claude` 無し）／ ホスト FS 不可視（`/Users` 無し）
- egress 既定ポリシー DROP、非許可 `example.com` → HTTP 000 遮断、許可 `api.github.com` → 200
- 擬似 AWS 鍵を非許可ホストへ POST → 遮断（注入鍵が漏れない）

## 発見と対処（公式そのままは危険）

公式 `init-firewall.sh` は許可ドメイン 1 つの解決失敗で **DROP 前に中断＝ fail-open**。`statsig.anthropic.com` で発火。
ハードン: ①解決失敗の非致命化（skip）②異常終了時 fail-closed トラップ。feature 同梱版（fail-open）を避けるため別名 `firewall.sh`。

## egress firewall を Squid ドメイン allowlist 化（2026-06-17）

当初の IP ベース ipset allowlist（起動時にドメインを解決して IP を pin + GitHub CIDR）は、Docker Hub の
registry/blob CDN（cloudflare/cloudfront）の **IP ローテーションに追従できず**、箱内 `docker pull` が
`dial tcp <ip>:443: i/o timeout` で失敗した。IP でなく**ドメインで許可する Squid explicit forward proxy** に置換:

- Squid を `127.0.0.1:3128` で explicit forward proxy として動かし、CONNECT のホスト名を `dstdomain` allowlist で
  判定して **復号せず blind tunnel**（MITM/CA/ssl-bump 不要）。透過 intercept は同一ホストの OUTPUT では
  SO_ORIGINAL_DST がローカルに化けて機能しないため採らない。
- iptables は box の OUTPUT を default DROP し、**Squid（proxy uid）のみ外向き 80/443 を許可**。proxy を
  使わない直接 egress は遮断（fail-closed）。QUIC(udp443) DROP、IPv6 は sysctl 無効化 + ip6tables DROP backstop。
- box のツールは `HTTPS_PROXY` env、dockerd は `daemon.json` proxy で Squid 経由。
- **DinD 共存**: firewall は dockerd の chain（DOCKER-FORWARD 等）を flush/削除しない（壊すと
  `docker network create` / compose が失敗する）。nested container の egress 封じ込めは dockerd が参照する
  DOCKER-USER chain に置き、nested↔nested は通し外部のみ DROP。
- **5 AI debate-review（Claude/Codex/Antigravity/Cursor/Grok）で hardening**: ① ip6tables backstop
  ② fail-open window 解消（policy DROP を flush 前に）③ Squid を loopback 限定 bind ④ telemetry/login
  ドメインを先頭ドット形 ⑤ DinD chain 破壊の修正。実機検証（arm64）: docker pull / network create /
  nested↔nested / nested→外部遮断 / box egress 封じ込め すべて確認。

## 限界

- **egress firewall は defense-in-depth であり、侵害された agent への hard boundary ではない**。箱の中の
  `node` は passwordless root sudo と docker 権限を持つため、乗っ取られた agent は `sudo iptables -F` /
  `sudo -u proxy <cmd>` / `docker run --network host ... iptables -F` で firewall を破壊し、注入鍵を任意ホストへ
  exfil できる。**通常運用（非侵害）では egress を封じ込めるが、本気で壁を壊しにくる侵害には無力**。鍵を持つ者
  （root/docker）が壁と同じ箱にいる以上、in-container では構造的に塞げない。真の封じ込めは host 側 firewall /
  別 netns sidecar / VM 隔離（Claude Code on the web 等）の **out-of-container enforcement** が要る。公式
  Anthropic devcontainer も同性質。本箱は teaching workshop 用途として defense-in-depth で受容する。
- 許可ドメイン経由の exfil は不可避（GitHub 許可 → gist 等）。DNS（udp/tcp 53）は開いており DNS tunneling は残る
  （accepted residual）。広域 RFC1918 を直接許可するため corp/VPC 上では内部 host へ到達しうる（dev laptop 限定運用が前提）。
- Squid は upstream の dst IP を制限しないため、許可ドメインが内部 IP に解決すると Squid が代理接続しうる（debate-review R2
  指摘）。dev laptop 脅威では non-concrete（信頼 vendor の DNS 制御 or root が要る）ため未実装だが、**cloud VM 上で運用する
  場合は IMDS（169.254.169.254）/ loopback / RFC1918 への dst-deny を `squid.conf` に追加すること**。
- コンテナ隔離であり VM 級ではない。untrusted code は VM / web。注入鍵は short-lived / scoped token を推奨。

## 反映方法と git 再構築の前提

本変更を反映した当時の repo ポリシーは **PR 不要**（main へ直接 commit / push）だったため、本変更は main へ直接反映した。**その後ポリシーは PR 経由に改訂されている**（現 `CLAUDE.md`「コミット / PR 運用」: 変更は PR 経由で行い main へ直接 commit / push しない）。
各ディレクトリの commit / branch 関係は、後日オーナーが **git 履歴の改変・再構築**で整える予定で、
本 `.devcontainer/` は「main に最初から存在する」状態に再構成される想定。履歴の書き換え自体はオーナー作業。

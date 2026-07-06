# Skills（粒度とレイヤー）

skill / capability を **抽象度のレイヤー**で扱う。上にいくほど抽象（何を・いつ）、下にいくほど具体（どう・実体）で、各層は「1 つ下」だけを知り、下の詳細を隠して具体化を委譲する（SOLID の「抽象に依存する」と同型）。本 rule は本 repo の skill 構造の SoT。フロー全体は [CLAUDE.md](../CLAUDE.md)「開発フロー」、skill 同梱の前提は [CLAUDE.md](../CLAUDE.md)「Workshop 前提」参照。

## レイヤー

| レイヤー | 抽象度 | 役割 | 例 |
|---|---|---|---|
| **フロー層**（CLAUDE.md + rules/） | 最も抽象 | lifecycle と「いつ・どの skill が発火するか」。skill ではない常時 context | 「開発フロー」overview |
| **orchestrator skill** | 中 | フェーズを束ね、leaf skill を compose + 操作系チェックを回す | `pr-codex-ci` |
| **leaf skill** | 具体 | 単機能。上位を呼ばない。素のツールに**抽象を 1 枚足す**（文脈判定・正規化等） | `a2a-review` |
| **scripts / tools** | 最も具体 | skill が駆動する実体 | `scripts/internal/a2a-review.sh` / `server.py` |

例: フロー「PR を作ったら review+CI を回す」→ orchestrator は実行環境で 2 系統 (`pr-codex-ci` = box / `pr-ci` = host)「review=`/a2a-review` or `/codex-review`・CI check（stale/run-id 判定込み）・loop」→ leaf `a2a-review`「box から A2A 経由で cdx-pair に投げる」/ `codex-review`「host CLI を直接 exec」→ tool `internal/a2a-review.sh`「A2A で codex 起動」/ `codex` CLI 自体。各段で 1 つ抽象が剥がれて具体になる。

## 合成のルール

- **呼び出しは上→下のみ**（フロー層 → orchestrator → leaf → tools）。**循環禁止**（下は上を知らない）
- **skill→skill は orchestrator → leaf に限る**（leaf は他 skill を呼ばない or 最小限）。Claude Code は Skill ツールで skill→skill を実際にサポートする（`pr-codex-ci` が `/a2a-review` を呼ぶのが実例）。**呼び出し側 skill の `allowed-tools` で gate されない**ため、orchestrator の `allowed-tools` に被呼び出し leaf を列挙する必要はない
- **環境ディスパッチ例外（peer 呼び出し可）**: box / host で同一役割の skill が別実装になる場合（`codex-review` ↔ `a2a-review`、`pr-ci` ↔ `pr-codex-ci`）、実行環境を検出して対応 skill に委譲することを許可する。条件: **単方向**（被委譲 skill が呼び出し元を呼び戻さない）かつ**ループにならない**こと。この委譲は leaf→leaf / orchestrator→orchestrator になるが、フロー層で判断すべきことを skill 内 safety check として実装した形と解釈する。検出はフロー層（CLAUDE.md / invoke 直前の `printenv SANDBOX_VM_ID` 確認）が理想で skill 内は二重安全網
- **各 skill のレイヤーは本 rule の「現状マッピング」表を SoT とする**（skill ファイル側に重複宣言せず drift を防ぐ）。skill の description は `orchestrator` / `leaf` の語を**自分のレイヤーと矛盾する形で使わない**（例: leaf skill の説明に "orchestration" を使わない）
- **層は抽象として意味を持つこと**。素のツールへ素通りするだけ（pass-through）の leaf を作らない＝ tool-wrapper を無闇に増やさない。何も足さないなら skill にせず orchestrator から直接ツールを叩く
- **レイヤー数は必要最小**（現状フロー / orchestrator / leaf / tools の 4 つで十分。増やさない）

## 現状マッピング

| skill | レイヤー | 内容 |
|---|---|---|
| `a2a-review` | **leaf** | **box-native** codex review を 1 回依頼。box 内から cdx-`<NAME>` pair の codex に A2A 経由で投げ、文脈判定 (sandbox box 除外) と reviewer 到達性を足す。superpowers の `requesting-code-review` 相当 |
| `codex-review` | **leaf** | **host-native** codex review。host インストールの `codex` CLI を直接 exec して PR diff / ファイル / 自由指示の second opinion を取る。`/a2a-review` の host 対称 (transport が違うだけ、契約は同) |
| `comment-sweep` | **leaf** | pre-PR sweep。新規追加コメントを [rules/code-comments.md](code-comments.md) 規範で判定 → 違反テーブル提示 → ユーザー承認後 Edit で修正。default は `origin/HEAD...HEAD` diff、`--staged` / `--worktree` / `BASE_BRANCH` 引数あり |
| `co-evolve-check` | **leaf** | pre-PR sweep。retention bias（旧版残置 = `interface UserOld` + `User` 並走 / `getUserNew` wrapper 等）を検出。caller が全 touched + public marker なしで `Confidence: high`。non-blocking report-only |
| `extension-bloat-sweep` | **leaf** | pre-PR sweep。既存 file / 関数 / シグネチャへの無理な拡張（E1: 既存大型 file 末尾追加 / E2: param ≥ 4 or optional ≥ 3 / E6: 同一 file の複数回 modify）を検出。non-blocking report-only |
| `grilling` | **leaf** | 設計フェーズの前提固め。計画・設計についてユーザーを**質問攻め**（1 問ずつ・推奨案つき・codebase で分かることは自分で調べる・共有理解の確認まで実行しない）してストレステストする pure prompt skill。[mattpocock/skills](https://github.com/mattpocock/skills/blob/main/skills/productivity/grilling/SKILL.md)（MIT）からの verbatim port |
| `pr-codex-ci` | **orchestrator** | **box-native** post-PR フェーズ。**ローカル** codex review (`a2a-review` を compose) + **CI check** + **`pr-review-respond` を compose した remote gate** + 修正ループ |
| `pr-ci` | **orchestrator** | **host-native** post-PR フェーズ。`codex-review` (host codex CLI 直) を compose + **CI check** + **`pr-review-respond` を compose した remote gate** + 修正ループ。`pr-codex-ci` の host 対称 |
| `pr-review-respond` | **leaf** | **GitHub に post された** PR review（Copilot/qodo 等 bot + 人間）を fetch → 採否 → 修正/reply → resolve。`gh api` を直接駆動し sub-skill を呼ばない。caller orchestrator (`pr-codex-ci` / `pr-ci`) には structured result (`pushed_changes` / `resolved_count` / `final_unresolved` / `checks_terminal`) を返して終了する（**上位 orchestrator を呼び戻さず cycle を回避**）。orchestrator (codex 第二意見の呼び出し) とは独立した別行為で単独 invoke も可 |
| `host-ask` | **leaf** | box 内から host 側の事実 (他 compose project / 既存 container / port 占有者 / mount 外 host fs / host-local service) を必要としたとき、`.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` に構造化 ask を Write し user に escalate。`<box-name>` は `$SANDBOX_VM_ID` env から取得 (hook 非依存)。`/box-session-context` (host から box transcript) の逆方向 (box → host の能動 ask) で、両者は補完関係。`<topic>` で並列 ask 対応 (1 box 内で複数物理問題を同時に走らせられる) |
| `host-answer` | **leaf** | host 側で `/host-ask` が書いた ask file を読み、host 側調査 (docker / lsof / 他 compose 設定 read-only) を回して `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` に paste-ready answer (` ```host-ctx ``` ` fence) を Write し user に escalate。`host-ask` の counterpart |
| `host-fetch` | **leaf** | box egress が sbx policy で塞がれ 403/到達不能な URL を host に代理取得させる。`.claude/host-bridge/fetch-req-<box>-<topic>-<seq>.md` に url/method を allowlist 形式で Write → user escalate → Monitor で ans auto-pickup。`sbx policy allow` はせず box を絞ったまま単発取得する設計。`/host-ask` (事実調査) の action 版 (net fetch)。box 側 advisory 検証に `scripts/internal/host-fetch.js --validate-only` |
| `host-fetch-grant` | **leaf** | host 側で box の fetch-req を読み、url/method を **count-gate で抽出** (raw を context に入れない、`box-session-resume-grant` と同方式) → human 目視 → **SSRF-safe core `scripts/internal/host-fetch.js`** で取得 (解決 IP の private/loopback/link-local/ULA/IPv4-mapped 拒否・redirect 非追従・credential 非送信・GET/HEAD・TLS 検証) → ans (信頼しない外部本文 fence + meta、binary/大は artifact 参照) + done sentinel。`/host-fetch` の user-trigger SSRF/injection gate。`/host-answer` の fetch 版 |
| `box-session-context` | **leaf** | host から box 内 Claude session の transcript を取り出し**参照専用**で要約。`scripts/internal/box-session-context.sh` を駆動。box-primary の HOTL 監視 (statusLine の session id → host で確認) を埋める。`/box-session-resume` (継続) と pair |
| `box-session-resume` | **leaf** | box 内 session を host / 別 box に inject し `claude --resume` で**同一 session 実再開**。source 自動特定 → dest の project dir に元 UUID 名で置く。**環境ディスパッチ**: host 起動は `scripts/internal/box-session-resume.sh` を直接実行、box 起動は host-bridge に resume-req を書いて `/box-session-resume-grant` に委譲 (box→host の peer 委譲、`codex-review`↔`a2a-review` と同型)。旧 `box-session-handoff` を置換。`/box-session-context` (参照) と pair |
| `box-session-resume-grant` | **leaf** | host 側で box の resume-req (`/box-session-resume` box-delegate が書いた `.claude/host-bridge/resume-req-<box>-<seq>.md`) を読み、内容を表示 (injection gate) して `scripts/internal/box-session-resume.sh` を実行、`resume-ans-<box>-<seq>.md` + done sentinel を Write。`/host-answer` の resume 版だが**状態変更を実行**する点が異なる。`/box-session-resume` の box-delegate モードの host 側 counterpart |
| `observe-session` | **leaf** | US3 (`rules/box-personas.md`) の observe box セットアップを 1 コマンド化。`examples/observe/setup-role.sh` / `start-session.sh` / `scripts/dev.sh observe` を束ね、「どの AWS profile/account か」「どの stack/log group が調査対象か」の発見 (CloudFormation スタック列挙 → 稼働中タスク定義が指す log group の特定) という抽象を1枚足す。box に入っての実調査は行わず `examples/observe/runbook.md` に引き継ぐ |

## 操作系チェック（CI check 等）の位置づけ

CI check / dynamic verify 等の**操作系チェックも leaf レベルの capability** で、post-PR orchestrator が compose する具体化要素。フロー上は「PR 後 = review + CI check + ...」として組み込まれる（[CLAUDE.md](../CLAUDE.md)「開発フロー」step 4 / [rules/pr-followup.md](pr-followup.md)）。

- **CI check** は `pr-codex-ci` と `pr-ci` の両 orchestrator の手順 3（CI gate）に inline で実装されている。素の `gh pr checks` ではなく、push 直後の stale 判定・run-id 解決・対話 TUI hang 回避・一過性 0-checks と CI 未設定の区別といった抽象を持つ（[.claude/skills/pr-codex-ci/SKILL.md](../.claude/skills/pr-codex-ci/SKILL.md) / [.claude/skills/pr-ci/SKILL.md](../.claude/skills/pr-ci/SKILL.md)）。
- **現状は inline duplicate**。consumer が `pr-codex-ci` + `pr-ci` の 2 つになった時点で本来は leaf skill（`/ci-gate` 等）へ昇格する規範だが、`pr-ci` 追加時の暫定として両 orchestrator に inline duplicate のまま残してある。**leaf extract は follow-up PR で行う**（[https://github.com/kanka-jp/coding-agent-playbook/issues](https://github.com/kanka-jp/coding-agent-playbook/issues) に CI-gate extract issue を起こす）。判断軸は「抽象の有無」ではなく**独立再利用の有無**で、2 consumer 状態を理由に extract する判断は維持する（dotfiles で verify / deploy-watch が skill 化されているのと同型）。

## 今後の追加指針

- 新 skill は**フェーズ（プラクティス）単位**で、tool-wrapper を leaf として増やさない（superpowers は tool-wrapper を持たず、すべてフェーズ skill）
- orchestrator は leaf を compose、leaf は単機能に保つ。**フロー層（CLAUDE.md）に step として接続**する（orchestrator = フローの step）
- skill を足す前に「どのレイヤーか・1 段下に何を委譲するか・どんな抽象を足すか」を本 rule のマッピングに追記する
- **frontmatter は最小限（`name` / `description`）に絞る**。`allowed-tools` は Claude Code 標準フィールドだが、box が YOLO（`--dangerously-skip-permissions`）で permission をバイパスするため load-bearing でなく、書かない。`maturity` や description の `[EXPERIMENTAL]` prefix は**標準 Claude Code に無い** dotfiles 固有の記載なので使わない（project は dotfiles 非依存）

## 背景

obra/superpowers（[https://github.com/obra/superpowers](https://github.com/obra/superpowers)）は flat な fine-grained skill（フェーズ単位）を Basic Workflow で合成し自動トリガーする構成で、tool-wrapper を持たない。本 repo はこれと dotfiles の「CLAUDE.md = 規範 / rules = 詳細 / skills = 実行」を踏まえ、**抽象度のレイヤーで粒度を扱い、CLAUDE.md 開発フローを合成層（最も抽象）に据える**。skill を大きくまとめるのではなく、fine-grained skill をレイヤーで整理し、orchestrator が leaf を compose する。

# 講義運営者向け

## 運用モデル

- **branch / PR**: agent が実際に作業する単位。PR は実演ログとして残す
- **`stage/NN-<name>` ブランチ**: project が通過する各状態のスナップショット (main を base にした stacked 連鎖。project 本体は `app/` 配下 — [decisions/stage-stacked-branches.md](decisions/stage-stacked-branches.md))。各フェーズの**開始状態**を checkpoint に取り、フェーズの到達点が次フェーズの開始点になるよう**連鎖**で並べる (運用保守・バグ修正のみ健全な状態から「壊れた状態 / 直した状態」を別に分岐するため、checkpoint 数はフェーズ数より多くなる。下記「ステージ」参照)
- **checkpoint の開き方**: `git switch stage/NN` で即座に開く (3 分クッキング方式)。broken/fixed の並置比較など複数状態を同時に開きたい時だけ `git worktree` (`scripts/internal/setup-worktrees.sh`)

## 新しい stage を作る

```bash
bash scripts/internal/new-stage.sh 09-next                        # 連鎖末尾の stage から分岐
bash scripts/internal/new-stage.sh 09-next 08-server-500-broken   # base を明示
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/internal/new-stage.ps1 -Name 09-next
powershell -ExecutionPolicy Bypass -File scripts/internal/new-stage.ps1 -Name 09-next -Base 08-server-500-broken
```

main の基盤変更を全 stage に流すときは `bash scripts/internal/restack-stages.sh`（Windows: `.ps1`。main → 01 → … → 末尾の cascade merge を一時 worktree 内で実行）。stage の規約 (app/ 配下のみ編集 / 命名 / 基盤は main 経由 + restack) は [CLAUDE.md](../CLAUDE.md) 「stage ブランチの規約」参照。

## スライド

講義スライドは**フェーズ単位**で `slides/<NN-slug>.html` に置く (壁打ち / 設計 / 実装 / 仕上げ (並列 issue 処理) / 運用保守・バグ修正。加えて概要の導入デッキ 00 と環境構築デッキ 01。スライドは状態でなくフェーズに対応するので、stage の checkpoint 数とは一致しない)。reveal.js を CDN から読み込む単一の自己完結 HTML で、中身は markdown 箇条書き (`---` でスライド区切り)。スライドの中身は人間が書く。構成・命名・スタイル・検証の規範は [rules/slides.md](../rules/slides.md) 参照。

- **作る**: `slides/template.html` を `slides/<NN-slug>.html` にコピーし、`<textarea>` 内の markdown を箇条書きで埋める (HTML 雛形は触らない)。全デッキ (`00-intro` 〜 `06-operate`) は記入済み (フェーズデッキ 02–06 の本文は講師所有 — 以降の書き換えは講師判断で、agent への明示委任も可。[../rules/slides.md](../rules/slides.md)「中身の担当」)
- **見る**: HTML をブラウザで開くだけ (ローカルは `file://` で可、ビルド不要)。一覧は `slides/index.html`
- **配信**: `.github/workflows/pages.yml` が `slides/` の変更を `push` 検知して GitHub Pages に自動配信する (`workflow_dispatch` での手動 trigger も可。ただし deploy job は main ブランチ限定のガードがあり、main 以外の ref で手動実行すると deploy は skip される)。初回のみ repo owner が Settings > Pages で Source = "GitHub Actions" に設定する必要がある (private repo は Team/Enterprise plan 必須)。詳細は [.github/workflows/README.md](../.github/workflows/README.md) 参照。配信後は `https://<owner>.github.io/<repo>/`(一覧) と `.../<NN-slug>.html`(各デッキ) で開ける

## ステージ (checkpoint 連鎖)

講義は **壁打ち → 設計 → 実装 → 仕上げ (並列 issue 処理) → 運用保守・バグ修正** の 5 フェーズ。各フェーズの「開始状態」を checkpoint に取ってある (3 分クッキング方式)。**受講者の default は自分の到達点からの地続き進行**で、stage は追いつき用のセーブポイント (講師の実演は再現性優先で `git switch stage/<NN-slug>` 起点にしてよい。運用保守フェーズだけは仕込みバグが必要なため全員 stage 起点)。あるフェーズの到達点が次フェーズの開始点になるため、stage は project が通過する状態の**連鎖**として並ぶ。運用保守・バグ修正だけは複数 checkpoint を持つ: シナリオ A は修正前 / 修正後のペア (`06`/`07`)、シナリオ B は修正前のみ (`08`) の計 3 点。

各 stage を講義中に「開いて → claude に何を頼み → どこを見せるか」の**実演台本**（依頼プロンプト例つき）は [stage-playbook.md](stage-playbook.md)。本表は checkpoint の**設計意図**、stage-playbook はフェーズ進行の**手順**を担当する。

checkpoint は状態の連鎖として並ぶ (✅ = 整備済み):

| stage | 状態 | どのフェーズで開くか | |
|-------|------|----------------------|---|
| `stage/01-blank` | `app/` が空 (起点プロンプトは実演時に口頭で与える) | **壁打ち** の開始 → 実演で one-pager を作る | ✅ |
| `stage/02-onepager` | one-pager あり | 壁打ちの到達点 / **設計** の開始 → 実演で設計書を書く | ✅ |
| `stage/03-design` | `app/docs/design.md` あり (フルスタック + AWS/ECS 構成) | 設計の到達点 / **実装** の開始 → 実演で MVP を作る | ✅ |
| `stage/04-mvp` | 動く MVP (monorepo: web / api / mock / core / infra) | 実装の到達点 / **仕上げ (並列 issue 処理)** の開始 → 大量 issue を並列で潰す | ✅ |
| `stage/05-fixed` | issue を捌いて磨いた MVP (並列 issue 処理 後の健全な状態) | **仕上げ (並列 issue 処理)** の到達点 / **運用保守・バグ修正** の土台 | ✅ |
| `stage/06-readings-drift-broken` | readings 上流レスポンスの契約ドリフトで壊れた状態 | **運用保守・バグ修正** の開始 (ローカル observe box での調査シナリオ) → 実演で直す | ✅ |
| `stage/07-readings-drift-fixed` | readings adapter が新契約に追従済み | 運用保守・バグ修正の到達点 (答え合わせ) | ✅ |
| `stage/08-server-500-broken` | `/api/diagnose/summary` の null guard 漏れによる 500 | **運用保守・バグ修正** の別シナリオ (cloud 常駐の無人 SRE fixer pipeline デモ用。[docs/decisions/cloud-unattended-sre.md](decisions/cloud-unattended-sre.md)) の開始 | ✅ |

- スラッグは「その checkpoint がどんな**状態**か」を表す (講義名ではなく状態記述)。各 stage は前 stage を base に分岐する (`stage/01-blank` のみ main 直下)。
- **仕上げ (並列 issue 処理)** フェーズの実演手順 (手動ペタペタ / ultracode 並列) は [parallel.md](parallel.md)「大量 issue を並列で捌く」を参照。
- **運用保守・バグ修正** フェーズは 2 つのシナリオを持つ。`06`→`07` (readings drift) は健全な `05-fixed` にバグを仕込んだ broken/fixed の完結ペアで、[box-personas.md](../rules/box-personas.md) US3 の**local observe box 調査**を実演する。`08` (server 500) は `07-readings-drift-fixed` (readings drift 修正済みの状態) にさらに別バグを仕込んだ broken 単体で、**cloud 常駐の無人 fixer pipeline** ([docs/decisions/cloud-unattended-sre.md](decisions/cloud-unattended-sre.md)) が実際に fix PR を出すところまでを実演するためのもの。fix は frozen な `09-*` stage を作らず、生成された PR ([https://github.com/kanka-jp/coding-agent-playbook/pull/159](https://github.com/kanka-jp/coding-agent-playbook/pull/159)) を実演時にその場で見せる (checkpoint を増やさず、無人パイプラインの「PR は無人で開く／merge は人間」という決定 3 の挙動をそのまま教材にする)。
- 講義スライドは状態ではなく**フェーズ**に対応する。上記「スライド」参照。

**現状 (2026-07)**: `01`〜`08` の checkpoint がすべて整備済み。運用保守・バグ修正フェーズの local 調査シナリオ (`06`/`07`) と cloud 常駐 fixer シナリオ (`08` + [https://github.com/kanka-jp/coding-agent-playbook/pull/159](https://github.com/kanka-jp/coding-agent-playbook/pull/159)) の両方が揃っている。残るのは cloud 常駐 fixer の full 配線 (CloudWatch alarm 経由の trigger・Slack 承認通知。[docs/decisions/cloud-unattended-sre.md](decisions/cloud-unattended-sre.md)「残差・未決」参照)。

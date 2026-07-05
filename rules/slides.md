# Slides（講義スライドの構成・スタイル・検証規範）

`slides/` の reveal.js デッキを作る・直すときの規範。配置の全体像（フェーズ単位・stage checkpoint との関係・stage ブランチに入れない）は [CLAUDE.md](../CLAUDE.md)「スライド」、講義運営側の手順（作る / 見る / 配信）は [docs/instructor/README.md](../docs/instructor/README.md)「スライド」参照。

## 構成と命名

- **単一の自己完結 HTML**。reveal.js は CDN から**固定バージョン + SRI**（`integrity`）で読む。バージョンを上げる時は `integrity` ハッシュも再計算する（不一致だとブラウザがリソースをブロックして**無言で壊れる**）
- 中身は `<textarea data-template>` 内の markdown 箇条書き。`---` でスライドを区切る。新規デッキは `slides/template.html` をコピーして markdown だけ編集する（**HTML 雛形は触らない**）
- 命名は `NN-slug.html`: `00-intro`（導入）/ `01-brainstorm`（壁打ち）/ `02-setup`（環境構築）/ `03`–`06`（設計 → 実装 → 仕上げ → 運用保守・バグ修正）。フェーズは 壁打ち → 設計 → 実装 → 仕上げ → 運用保守・バグ修正 の 5 つだが、壁打ちのデモを見せてから環境構築に入る流れのため 壁打ち(`01`) を環境構築(`02`) の前に置く（フェーズデッキは `01` と `03`–`06` に分かれ、`02` だけ非フェーズの環境構築）
- **途中に番号を挿入する時は以降のデッキを `git mv` で繰り下げ、参照を同時更新する**。更新対象: 各デッキ末尾の nav リンク（次デッキへの chain）/ `slides/index.html` の一覧 / docs のスライド番号参照（[docs/instructor/README.md](../docs/instructor/README.md) / [docs/instructor/stage-playbook.md](../docs/instructor/stage-playbook.md) 等）。旧番号の grep で取りこぼしを確認する
- デッキ末尾は `title-slide` の「次のフェーズへ」リンクで次デッキに繋ぐ（最終デッキは一覧へ戻る）

## スタイル規範（シンプル優先）

- **タイトル扉は `# 見出し` 1 行だけ**。サブタイトル・フェーズ番号（`フェーズ N / 5` 等）・説明行を足さない
- 本文スライドは `## 見出し` + フラットな箇条書き。**1 スライド 5 行前後**を目安に、ネストや長文で溢れそうなら**スライドを分割する**（後述の fit-scale に頼らない）
- コマンド・ファイル名・フラグは backtick で書く（共有 CSS の `.reveal code` が chip 状に描画して地の文と視覚区別する）
- 強調は `**bold**`（accent 色になる）を要点だけに
- **デッキ枚数を docs にハードコードしない**（「5 枚」等はデッキ追加で falsify される。講義フェーズ数「5 フェーズ」のような構成上の事実は書いてよい）

## 図解（アーキテクチャ図等）

- 図は **Mermaid をテキストで埋め込む**（markdown 内に `<div class="mermaid">` を直接書く）。draw.io 等の外部エディタ製 SVG / PNG は使わない（テキストで diff できず、単一自己完結 HTML の規範から外れる）
- 使うデッキだけに mermaid の CDN `<script>`（**固定バージョン + SRI**、reveal.js と同じ扱い）を追加する。共有 JS が `window.mermaid` を検出して描画し、描画後に fit を再計算する（mermaid を読まないデッキでは no-op なので、共有 JS ブロックは全デッキ同一のまま保てる）
- flowchart は `htmlLabels: false` 前提（共有 JS の `mermaid.initialize` で設定済み）。HTML ラベルは幅測定のずれで**ラベル末尾が切れる**
- 図の SVG は共有 CSS でコンテンツ幅いっぱいに拡大される。**ノード・エッジ数は絞る**（導入レベルは 4–6 ノード目安。詰め込むならスライド分割）

## レイアウト機構（テンプレが保証すること）

- canvas は **1280×720 固定**・`center: false` で上寄せ。reveal が window に合わせて均一スケールする
- **枠 (720px) に収まらないスライドは fit-scale JS が中身を等倍縮小して全体を表示する**（`overflow: hidden` で隠さない）。ただし縮小されたら文字が小さくなっているサインなので、発動したら内容の分割を優先する
- `title-slide` class は flex で枠中央に配置
- **共有 CSS / fit-scale JS は全デッキ + `template.html` に複製されている**。変更する時は 1 ファイルだけ直さず**全ファイルへ一括適用**する（スクリプトで同一ブロックを置換し、置換漏れ 0 を確認する）

## 検証（PR 前に実描画で確認）

- スクリーンショットで実描画を確認する。確認観点:
  - 各スライドが枠に収まるか（fit-scale の `transform` 発動有無を DevTools で見る。発動していたら分割を検討）
  - nav chain に dead link が無いか（`00 → 01 → … → 最終 → index`）
  - `index.html` の一覧・リード文と実デッキ構成の整合
- **box 内で確認する場合**: box の egress は CDN (`cdn.jsdelivr.net`) が default-deny で塞がれており、そのまま開くと reveal が読めず `<textarea>` の生テキストが出る。npm registry は通るので `npm pack reveal.js@<version>` で取得し、CDN 参照をローカル vendor copy に差し替えた**検証用コピー**（scratchpad に置く。**commit しない**）で描画確認する。host ブラウザからは CDN に届くため、committed ファイルは無加工でよい

## 中身の担当

- **フェーズデッキ（`01-brainstorm` と `03`–`06`）の本文は講師（人間）が所有する**。agent が中身を書く・書き換えるのは**講師が明示的に指示したときだけ**（勝手に埋めない。起案時は [docs/instructor/stage-playbook.md](../docs/instructor/stage-playbook.md) 等の SoT と突き合わせる）。agent の常時担当は雛形（`template.html`）と共有 CSS / fit-scale JS の保守
- `00-intro`（導入）と `02-setup`（環境構築）は playbook 自身の説明なので、agent が repo 内容（README / docs/guide/setup.md 等）から起案してよい（記載が SoT と食い違わないことを必ず突き合わせる）

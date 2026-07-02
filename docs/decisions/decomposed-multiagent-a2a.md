# 決定記録: decomposed multi-agent（1 agent 1 box + native auth + A2A coordination）

**ステータス: Accepted（2026-06-19、実装は staged）** — 下記「検証ゲート (spike)」を実機で通過。[parallel-hotl-execution.md](parallel-hotl-execution.md) で採用した sbx microVM 基盤の上に、複数 agent を **「1 box 1 agent」に分解し A2A で協調させる**方向を決定する。若い spec + 非自明ビルドのため実装は Stage 1〜3 に分けて段階導入する。**本 ADR は execution topology（box 内 agent 配置）を evolve するもので、[parallel-hotl-execution.md](parallel-hotl-execution.md) の sbx 採用は不変。**現行の co-located（claude+codex 同居）モデルは Stage 1 が landing するまで current implementation として有効で、本 ADR の決定は target end-state を定義する。

## 背景

[parallel-hotl-execution.md](parallel-hotl-execution.md) は sbx を実行基盤に採用し、現行は **built-in claude agent の 1 box に claude+codex を同居**させ、claude が codex を shell out して相互レビューする構成（[../../sbx/README.md](../../sbx/README.md)）。これは「並列 HOTL を安全に」までは満たすが、次で詰まる:

- **拡張性**: gemini / grok 等の agent や、agent でない service（DB・検索・tool）を後から足すのが、1 box 同居モデルでは綺麗に伸びない。
- **codex 認証の摩擦**: 同居 box では codex のサブスク OAuth が proxy 注入されない（agent-gating: 注入は built-in agent 限定）。そのため `~/.codex/auth.json` を box ごとに host から転送する必要があり、複数 box 並列では refresh token rotation で 401 のリスクが残る（[../../sbx/README.md](../../sbx/README.md) のセキュリティ注記参照）。

オーナーの目的更新: **受講者が gemini/grok や非 agent サービスを後から足せる、拡張可能な multi-agent 開発アーキを教材として示す**こと。

## 判断軸: 拡張性は「関心の分解」を要求する

「agent / service を足す」を宣言的にしたいなら、**1 box 1 concern（microservices 哲学）+ 標準プロトコルで協調**が筋。業界も **A2A（agent ↔ agent）+ MCP（agent → tool）** に収斂しており、拡張が「Agent Card を publish / MCP server を登録」に落ちる。同居モノリスはこの伸びを構造的に持たない。

## 決定 (Accepted)

1. **1 agent 1 box に分解する**。各 box は built-in agent として native 認証する（claude = 経路 C anthropic OAuth secret / codex = openai OAuth secret / 以降の agent も各 native）。**auth.json 転送は廃する**。なお token-in-box の扱いは agent ごとに非対称: codex の openai OAuth secret は proxy 注入で **box にトークンが入らない**（spike #1）が、claude の経路 C は `~/.claude/.credentials.json` が box 内に provision される（[../../sbx/README.md](../../sbx/README.md) の認証節参照）。security トレードオフは下記「残差」参照。
2. **協調は A2A（agent ↔ agent）を target とする**。各 agent を A2A server に wrap する（Executor が CLI を shell out + Agent Card で capability を広告）。
3. **非 agent / tool の追加は MCP** を使う（A2A と層が違い排他でない）。現状の playbook が登録する MCP server は `chrome-devtools` のみ（`.mcp.json` 参照）で、Docker MCP Gateway は未導入。Stage 2 で非 agent service を追加する際に Docker MCP Gateway を導入候補とする。
4. **将来は host 側に Agent Gateway（egress 制御 + discovery の関所）を置く**（target end-state、Stage 3 で実装）。現行 sbx は default-deny + allowlist（anthropic / github / npm / docker 等）+ `gateway.docker.internal:3128` HTTP proxy で egress を制御している（[parallel-hotl-execution.md](parallel-hotl-execution.md) 「検証ゲート」末尾の egress 補足参照）。Stage 1〜2 は現行 allowlist に必要な穴を開けつつ host broker で協調し、mesh が育った Stage 3 で本物の Agent Gateway（agentgateway 等）が egress + discovery を一本化する形に移行する。
5. **実装は staged**（full-mesh を一度に建てない = YAGNI）:
   - **Stage 1**: 最小の本物 A2A slice。codex を A2A server 化（`code-review` capability）→ claude / host が A2A client として review task を投げ artifact を受け取る。Agent Card discovery + JSON-RPC task が 2 box 間で通ることを実証する。
   - **Stage 2**: gemini / grok box を各々 A2A server + Agent Card で足す。非 agent は MCP server を追加。「足す = Agent Card / MCP 登録」が動くことを示す。
   - **Stage 3**: mesh が育ったら本物の Agent Gateway（agentgateway 等）で egress + discovery を一本化する。

## なぜ A2A か（MCP / host-script との対比）

- **host-script broker**: 最小だが dynamic discovery / 異種 agent 拡張を持たない。PoC（proto-gateway、下記 spike #4）には使ったが target にはしない。
- **MCP only**: agent → tool の層。codex を claude の「道具」扱いになり対等な相互レビューには非対称。非 agent service 追加に併用する。
- **A2A**: peer agent の標準。拡張が宣言的（Agent Card）。教材として最前線を示せる。

## 残差・トレードオフ

- per-agent の A2A server wrapper を作るコスト（CLI は A2A-native でない）。
- box-to-box は host 経由 + egress policy で繋ぐ（隔離に governed hole を開ける）。
- A2A は young spec（churn リスク）。実装は staged にして影響を局所化する。
- サブスク並列の天井は plan の concurrent session cap（ChatGPT Pro は並列向け価格・ToS 内）。rotation は proxy 注入で box にトークンのコピーを持たないため構造的に回避されるが、持続 refresh の挙動は要観測（spike #2）。
- **claude 経路 C の token-in-box 残差**: 決定 #1 のとおり claude box には `~/.claude/.credentials.json` が provision されるため、claude box 侵害時に実トークンが exfil されうる（codex の openai OAuth secret は proxy 注入で box 外、こちらだけ非対称に消える）。緩和は claude 側を経路 A（API key proxy 注入）に切り替えれば token-not-in-box にできるが、サブスク維持時は箱内 token を accepted residual とする（[../../sbx/README.md](../../sbx/README.md) の security トレードオフ参照）。

## 検証ゲート (spike) — 結果（2026-06-19 実機検証で通過）

macOS arm64 / sbx v0.33.0 / 現行 `sbx/` カスタム image で確認。

1. ✅ **隔離 box で codex の native 認証（転送ゼロ）**: `sbx secret set -g openai --oauth`（global）+ `sbx create --name <box> codex -t coding-agent-playbook-sbx --clone .` で、作成時に `Using stored OpenAI OAuth credentials`、`codex exec` が `provider: sandboxd`（proxy 注入）で応答。**auth.json 転送なし・token は box に入らない**。同居 box の codex 認証摩擦が、codex-base box では解消することを確認。
2. ✅ **並列**: 2 つの codex-base box で同時に `codex exec` し両方成功（401 なし）。持続 refresh の rotation は未ストレステスト（proxy 注入は box にコピーを持たず構造的に回避される）。
3. ✅ **隔離 box でローカル環境が建つ**: codex-base box に node v22.x / npm 9.x / Docker 29.x（DinD）。dev server を box 内に立て `sbx ports <box> --publish` で host に公開できる（[parallel-hotl-execution.md](parallel-hotl-execution.md) spike #5 / 名前ルーティングは [../../tools/parallel-dev/box-routing/](../../tools/parallel-dev/box-routing/README.md)）。
4. ✅ **host 仲介の協調 PoC（A2A の proto 形）**: claude box（経路 C）が関数を生成 → host が `sbx cp` で claude box → host → codex box に中継 → codex box がレビューし実バグ 2 件検出。別 microVM の claude ↔ codex が **native auth のまま host 仲介で相互レビュー**できることを確認。Stage 1 はこの broker を A2A protocol + Agent Card で正式化する。

## Sources

- [https://github.com/a2aproject/A2A](https://github.com/a2aproject/A2A)
- [https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/](https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/)
- [https://github.com/a2aproject/a2a-python](https://github.com/a2aproject/a2a-python)
- [https://modelcontextprotocol.io/](https://modelcontextprotocol.io/)
- [https://www.docker.com/blog/docker-mcp-gateway-secure-infrastructure-for-agentic-ai/](https://www.docker.com/blog/docker-mcp-gateway-secure-infrastructure-for-agentic-ai/)
- [https://agentgateway.dev/](https://agentgateway.dev/)
- [https://arxiv.org/pdf/2505.07838](https://arxiv.org/pdf/2505.07838)
- [https://docs.docker.com/ai/sandboxes/security/credentials/](https://docs.docker.com/ai/sandboxes/security/credentials/)

# playbook 実行基盤 (Docker Sandboxes) 用カスタムイメージ。中立な shell-docker base に
# claude / codex を対等に install し、workshop 用ツール (fonts / headless Chromium +
# chrome-headless ラッパー + CDP 環境変数) を bake する。この image を `-t` で渡し
# built-in claude agent で起動する (`sbx run claude -t ... --kit ./sbx/playbook-kit`)。
# claude は API key を proxy 注入 (box 外) / サブスクは箱内 /login (box 内)、codex は auth.json
# 転送で認証する (詳細は sbx/README.md)。
# DinD は shell-docker (-docker 系統) の継承で得る (素の shell に手で docker を足しても付かない)。
FROM docker/sandbox-templates:shell-docker

USER root
# base は Ubuntu arm64 で apt の chromium は snap stub のみ（実体無し）。chromium 本体は
# Playwright 同梱版（distro 非依存の arm64 build）を使い、root では共有ライブラリだけ install-deps で入れる。
RUN apt-get update && apt-get install -y --no-install-recommends \
      fonts-liberation ca-certificates curl unzip \
  && mkdir -p /usr/local/share/npm-global/lib \
  && npx -y playwright@latest install-deps chromium \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# observe box (rules/box-personas.md) が read-only AWS 調査に使う aws CLI v2。base image に含まれないため明示 install。
# uname -m の出力 (x86_64 / aarch64) は AWS の zip 命名とそのまま一致するため変換テーブル不要
# (amd64 host での build を uname 固定で壊さないため build ホストの arch を都度検出する)。
RUN AWSCLI_ARCH="$(uname -m)" \
  && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/awscliv2.zip /tmp/aws

USER agent
RUN npx -y playwright@latest install chromium

USER root
# コンテナでは Chromium の sandbox 権限が無いため、--no-sandbox ラッパーから実体を直接 exec する
# （/usr/local/bin への書き込みは root 必須）。
RUN CHROME_BIN="$(find /home/agent/.cache/ms-playwright -type f -name chrome -path '*chromium-*/chrome-linux/chrome' | head -n1)" \
  && test -n "$CHROME_BIN" \
  && printf '#!/bin/sh\nexec %s --no-sandbox --disable-setuid-sandbox "$@"\n' "$CHROME_BIN" > /usr/local/bin/chrome-headless \
  && chmod +x /usr/local/bin/chrome-headless

# .mcp.json の chrome-devtools MCP にこのラッパーを渡す配線。未設定だと ${CDP_EXEC:-} が空になり
# MCP が Chromium を解決できず失敗する。
ENV CDP_HEADLESS=--headless \
    CDP_EXEC=--executable-path=/usr/local/bin/chrome-headless

USER agent
# pipefail: installer の curl 取得失敗で build を fail させる (パイプ右辺の bash/sh だけ見ると
# agent 不在の image が "成功" し runtime で entrypoint が壊れるため)。
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# 値を変えて build すると以降の install レイヤーだけ cache を捨てて再取得する。素の docker build は
# installer の RUN 文字列が不変なため cache hit し、上流で出た新 version を取らず古い版に固定するため。
ARG AGENT_CACHEBUST=unset
# claude / codex を対等に install する。claude は native installer (~/.local/bin、PATH 先頭)。
# AGENT_CACHEBUST を参照して以降のレイヤーの cache を破棄する (ARG を RUN で使わないと cache key に効かない)。
RUN echo "$AGENT_CACHEBUST" >/dev/null && curl -fsSL https://claude.ai/install.sh | bash
# box 内 claude の既定 model を Opus に。built-in claude agent は起動時に ~/.claude/settings.json を
# 自前で書き直し焼いた model field を落とす (実機確認済み) ため、settings でなく env に焼く。box には
# --model も他の ANTHROPIC_MODEL も渡らないので precedence 上この env が唯一の権威として効く。host 非影響 (box-only)。
ENV ANTHROPIC_MODEL=opus
# codex は OpenAI 公式推奨の standalone installer (Rust binary・Node 非依存、~/.local/bin)。
# CODEX_NON_INTERACTIVE=1 で post-install の "Start Codex now?" prompt を確実に skip する。
# codex の認証 (auth.json) は box 作成後に host から転送する (sbx/README.md「codex のサブスク認証」)。
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh

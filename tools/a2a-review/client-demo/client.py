"""A2A client: codex-a2a-server にレビュー指示を投げる。

コード片ではなく「どのファイル/diff をレビューするか」の指示文を送り、codex 側が
bind-mount された同一ソースを自分で読んでレビューする (server.py 参照)。
host から叩く場合は sbx ports で box を publish + server 側で A2A_ADVERTISE_URL に
host 到達 URL を指定して再起動する (README 参照)。

Agent Card を /.well-known/agent-card.json から discovery し、message/stream (SSE) で
codex の進捗 (WORKING ステータス) を逐次受信しながら最終 artifact (レビュー結果) を取り出す。
公式 a2a-samples/helloworld/test_client.py を基にする。
"""

from __future__ import annotations

import argparse
import asyncio
import os

import httpx
from a2a.client import A2ACardResolver, ClientConfig, create_client
from a2a.helpers import new_text_message
from a2a.types.a2a_pb2 import Role, SendMessageRequest


async def run(server_url: str, review: str) -> None:
    # read timeout はイベント間隔の上限 (total には効かない): server の idle timeout より長く取り、
    # 進捗が流れる限り数時間級でも待つ (固定 total timeout を持たない)
    timeout = httpx.Timeout(connect=10.0, read=360.0, write=10.0, pool=10.0)
    async with httpx.AsyncClient(timeout=timeout) as httpx_client:
        # Agent Card discovery (/.well-known/agent-card.json)
        resolver = A2ACardResolver(httpx_client=httpx_client, base_url=server_url)
        agent_card = await resolver.get_agent_card()

        print("== Agent Card ==")
        print(f"name: {agent_card.name}")
        print(f"version: {agent_card.version}")
        print(f"skills: {', '.join(s.id for s in agent_card.skills)}")
        print()

        # httpx_client を明示的に渡す: 渡さないと SDK がデフォルト httpx (read timeout 5s) を作り、
        # codex の作業中イベント間隔が 5s を超えた瞬間に ReadTimeout する。上の長い read timeout を効かせる
        config = ClientConfig(streaming=True, httpx_client=httpx_client)
        client = await create_client(agent=agent_card, client_config=config)

        message = new_text_message(review, role=Role.ROLE_USER)
        request = SendMessageRequest(message=message)

        print("== Streaming review (codex の進捗を WORKING で逐次受信) ==")
        # raw 出力に倒す: SDK バージョンで chunk 型が動くため、受講者が現物を読んで学べる形にする
        async for chunk in client.send_message(request):
            print(chunk)


def main() -> None:
    parser = argparse.ArgumentParser(description="A2A code-review client")
    parser.add_argument(
        "--server",
        required=True,
        help=(
            "codex-a2a-server の URL (例: http://127.0.0.1:49170, "
            "sbx ports --publish で出た host port)"
        ),
    )
    parser.add_argument(
        "--review",
        required=True,
        help='レビュー指示 (例: "tools/a2a-review/codex-a2a-server/server.py の edge case を見て")',
    )
    args = parser.parse_args()
    # box egress proxy の NO_PROXY は bracket IPv6 ("[::1]") を含み httpx が Invalid port で
    # クラッシュする (curl は平気)。非 bracket の "::1" が loopback 除外を担保するので除いてよい
    for var in ("NO_PROXY", "no_proxy"):
        val = os.environ.get(var)
        if val:
            kept = ",".join(e for e in val.split(",") if "[" not in e and "]" not in e)
            if kept:
                os.environ[var] = kept
            else:
                del os.environ[var]
    asyncio.run(run(args.server, args.review))


if __name__ == "__main__":
    main()

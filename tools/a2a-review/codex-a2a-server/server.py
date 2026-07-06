"""A2A server wrapping `codex exec` for code review (live-source 版).

codex box 内で起動し、Agent Card を /.well-known/agent-card.json で配信。
client が `code-review` skill に「どのファイル/diff をレビューするか」の指示を
投げると、codex を repo root を CWD にした read-only subprocess で起動し、
codex 自身が同一ソースツリーを読んでレビューした結果を artifact として返す
(コード片を message に貼らず、bind-mount した同じソースを直接参照する)。

設計の根拠は ../README.md と ../../docs/decisions/decomposed-multiagent-a2a.md。
公式 a2a-samples/helloworld を基に CLI subprocess wrapping に拡張。
"""

from __future__ import annotations

import asyncio
import errno
import json
import os
import socket
from collections.abc import Awaitable, Callable
from pathlib import Path

import uvicorn
from a2a.helpers import (
    get_message_text,
    new_task_from_user_message,
    new_text_message,
    new_text_part,
)
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill
from a2a.types.a2a_pb2 import TaskState
from starlette.applications import Starlette

LISTEN_HOST = "::"  # dual-stack bind 用。実際の socket option 設定は下記 _dual_stack_socket() 参照
PORT = 9999
# Agent Card に書く URL: client が到達可能な値。box 内 demo は localhost、
# sbx ports で host へ公開する運用なら A2A_ADVERTISE_URL=http://host:<ephemeral> で上書き
ADVERTISE_URL = os.environ.get("A2A_ADVERTISE_URL", "http://127.0.0.1:9999")


# 進捗が一定時間途切れたら hang とみなす idle timeout。固定の total timeout でなく idle ベース:
# 自律レビューは total 時間が読めず (数分〜数時間)、進捗が流れる限り待てるようにするため
CODEX_IDLE_TIMEOUT_SECONDS = 300.0
# StreamReader の 1 行上限。default 64 KiB (asyncio.StreamReader._DEFAULT_LIMIT) だと codex --json の
# 1 event が超過したとき readline() が ValueError を raise するため引き上げる。spawn の limit= と
# 超過時のエラーメッセージで同じ値を使うため定数に切り出す
CODEX_STREAM_LIMIT = 4 * 1024 * 1024
# 既定 CWD は本ファイルから導出した repo root (起動 CWD 継承だと repo root 相対の指示が解決できない)。
# parents[3]: codex-a2a-server/server.py -> codex-a2a-server -> a2a-review -> tools -> repo root
REVIEW_WORKDIR = os.environ.get("A2A_REVIEW_WORKDIR") or str(Path(__file__).resolve().parents[3])


async def _run_codex_review(
    instruction: str, emit: Callable[[str], Awaitable[None]]
) -> tuple[str, bool]:
    """codex --json を起動し JSONL イベントを逐次 emit しながらレビュー本文と成否を返す。

    codex は CWD (REVIEW_WORKDIR = bind-mount した同一ソース) を自分で読むため、
    呼び出し側はコード片を貼らずファイルパス/diff 等の指示だけ渡す。
    `codex exec --json` は thread/turn/item イベントを 1 行ずつ flush するため、reasoning や
    file-read 等の作業中イベントも逐次 emit でき (素の出力は block-buffer で完了まで沈黙する)、
    total timeout でなく idle timeout で hang を判定できる = 数時間級でも進捗が流れる限り待てる。
    戻り値は (agent_message を結合したレビュー本文, 成功か)。turn.failed / error / idle kill /
    非ゼロ exit / agent_message が 1 件も無い場合は False。
    """
    # 外部 fetch (CDN/SRI 実値照合等) で codex が idle stall するため、static review のみに絞らせる
    prompt = (
        "You are a code reviewer with read-only access to this repository "
        "(your current working directory). Carry out the review request below: "
        "open and read the referenced files/paths yourself instead of asking for "
        "code to be pasted. Do not fetch from the network; review only the local "
        "source tree files. Be brief: list concrete issues with file:line, or say LGTM.\n\n"
        f"Review request:\n{instruction}\n"
    )
    try:
        # 1 event が CODEX_STREAM_LIMIT を超過したときの readline() ValueError (下の while で捕捉)
        # を抑えるため limit を引き上げる。それでも超過し得るので捕捉は必須
        proc = await asyncio.create_subprocess_exec(
            "codex", "exec", "--json", "--skip-git-repo-check", "-s", "read-only",
            cwd=REVIEW_WORKDIR,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,  # 進捗とエラーを 1 ストリームに集約して中継する
            limit=CODEX_STREAM_LIMIT,
        )
    except OSError as exc:
        # codex 不在 / workdir 不在 (create) 等で spawn 自体が失敗。reap すべき子プロセスは無い
        return f"[codex launch failed: {exc}]", False
    review_parts: list[str] = []
    saw_error = False  # turn.failed / error は sticky: 後続の turn.completed で打ち消さない
    turn_completed = False
    # spawn 後は単一の try/finally で reap を保証する (stdin 書き込み phase の cancel / 例外も覆う)
    try:
        try:
            proc.stdin.write(prompt.encode("utf-8"))
            await proc.stdin.drain()
            proc.stdin.close()
        except OSError as exc:
            # spawn 後即死による stdin パイプ破損 (BrokenPipeError 等)。reap は finally に委ねる
            return f"[codex stdin failed: {exc}]", False
        while True:
            try:
                line = await asyncio.wait_for(
                    proc.stdout.readline(), timeout=CODEX_IDLE_TIMEOUT_SECONDS
                )
            except asyncio.TimeoutError:
                # kill / wait は finally に委ねる (idle も含め reap を 1 箇所に集約)
                partial = "\n\n".join(p for p in review_parts if p)
                return f"{partial}\n[codex idle > {CODEX_IDLE_TIMEOUT_SECONDS}s, killed]", False
            except ValueError as exc:
                # 1 event が CODEX_STREAM_LIMIT を超過すると readline() が ValueError を raise する。
                # 捕捉しないと executor を貫通し artifact も FAILED status も返せず落ちるため、ここまでの
                # partial を付けて明示的に failed review を返す (kill / wait は finally に委ねる)
                partial = "\n\n".join(p for p in review_parts if p)
                return f"{partial}\n[codex line exceeded {CODEX_STREAM_LIMIT} bytes: {exc}]", False
            if not line:
                break
            text = line.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            try:
                event = json.loads(text)
            except json.JSONDecodeError:
                await emit(text)  # 非 JSONL 行 (起動バナー等) はそのまま進捗に流す
                continue
            etype = event.get("type", "")
            if etype == "item.completed":
                item = event.get("item", {})
                itype = item.get("type", "")
                if itype == "agent_message":
                    review_parts.append(item.get("text", ""))
                detail = item.get("text") or item.get("command") or ""
                await emit(f"[{itype}] {detail}".strip()[:300])
            elif etype == "turn.completed":
                turn_completed = True
                await emit("[turn.completed]")
            elif etype in ("turn.failed", "error"):
                saw_error = True
                await emit(f"[{etype}] {text[:300]}")
            else:
                await emit(f"[{etype}]")
        await proc.wait()
    finally:
        # spawn 後の任意の早期 return / 例外 / cancel で走行中の codex を reap する。
        # 終了済みなら kill は Popen 側で no-op、wait は即時返る
        if proc.returncode is None:
            proc.kill()
            await proc.wait()
    ok = (
        turn_completed
        and not saw_error
        and proc.returncode == 0
        and bool(review_parts)
    )
    review = "\n\n".join(p for p in review_parts if p) or "(codex returned no agent_message)"
    return review, ok


class CodexReviewExecutor(AgentExecutor):
    """A2A AgentExecutor。`execute` で codex review subprocess を起動して artifact を返す。"""

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        if context.current_task:
            task = context.current_task
        else:
            task = new_task_from_user_message(context.message)
            await event_queue.enqueue_event(task)

        task_updater = TaskUpdater(
            event_queue=event_queue,
            task_id=task.id,
            context_id=task.context_id,
        )

        await task_updater.update_status(
            state=TaskState.TASK_STATE_WORKING,
            message=new_text_message("invoking codex..."),
        )

        instruction = (get_message_text(context.message) or "").strip()
        if not instruction:
            await task_updater.update_status(
                state=TaskState.TASK_STATE_FAILED,
                message=new_text_message("empty input"),
            )
            return

        async def emit(progress: str) -> None:
            # codex の進捗行を WORKING ステータスとして逐次 stream し、推論中をリアルタイムに伝える
            if progress:
                await task_updater.update_status(
                    state=TaskState.TASK_STATE_WORKING,
                    message=new_text_message(progress),
                )

        review, ok = await _run_codex_review(instruction, emit)
        await task_updater.add_artifact(
            parts=[new_text_part(text=review, media_type="text/plain")],
        )
        await task_updater.update_status(
            state=TaskState.TASK_STATE_COMPLETED if ok else TaskState.TASK_STATE_FAILED,
            message=new_text_message("review completed" if ok else "codex failed"),
        )

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        # PoC は長時間 streaming を持たないため cancel は no-op (return)。
        # subprocess が走り始めていれば run は完了まで進むが、本 PoC スコープでは受容
        return


def build_agent_card() -> AgentCard:
    """Agent Card (`/.well-known/agent-card.json` で配信される capability 広告)。"""
    skill = AgentSkill(
        id="code-review",
        name="code-review",
        description="リポジトリ内の指定ファイル/diff を codex が読んでレビューし、issue リストか LGTM を返す",
        input_modes=["text/plain"],
        output_modes=["text/plain"],
        tags=["code-review", "codex"],
        examples=["Review tools/a2a-review/codex-a2a-server/server.py for edge cases."],
    )
    return AgentCard(
        name="codex-code-review",
        description="OpenAI codex が同一ソースツリーを読んでコードレビューを返す A2A server",
        version="0.1.0",
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        capabilities=AgentCapabilities(streaming=True),
        supported_interfaces=[
            AgentInterface(
                protocol_binding="JSONRPC",
                url=ADVERTISE_URL,
            ),
        ],
        skills=[skill],
    )


def build_app() -> Starlette:
    agent_card = build_agent_card()
    handler = DefaultRequestHandler(
        agent_executor=CodexReviewExecutor(),
        task_store=InMemoryTaskStore(),
        agent_card=agent_card,
    )
    routes = []
    routes.extend(create_agent_card_routes(agent_card))
    routes.extend(create_jsonrpc_routes(handler, "/"))
    return Starlette(routes=routes)


def _ipv4_socket() -> socket.socket:
    """元の挙動の IPv4 (0.0.0.0) listen socket。dual-stack を確立できない platform 用の fallback。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT))
    sock.listen()
    sock.set_inheritable(True)
    return sock


def _listen_socket() -> socket.socket:
    """IPv4 と IPv6 の両方を 1 socket で受ける dual-stack listen socket を作る。

    sbx proxy は host.docker.internal を IPv6 [::1] で掴むことがあり、0.0.0.0 (IPv4 のみ) bind
    だと sbx の IPv6 port-forward が box 側で RST し proxy 経由が 500 になる (in-box の 127.0.0.1
    health check は IPv4 で通るため pair-serve は "ready" と誤検知する)。逆に uvicorn の host="::"
    任せだと box の bindv6only=1 環境で IPv6-only になり今度は in-box の IPv4 health check が落ちる。
    そこで AF_INET6 socket に IPV6_V6ONLY=0 を明示し、IPv4-mapped も accept する真の dual-stack に
    する (proxy がどちらの family を選んでも、in-box health check も、両方到達できる)。

    IPv6/dual-stack が「その platform で使えない」場合に限り IPv4 (0.0.0.0) socket に明示的に
    fallback する。黙って "::" の IPv6-only で listen すると in-box の IPv4 health check が落ちる
    (元の IPv4 listen からの regression) ため。逆に address-in-use (EADDRINUSE) や permission
    (EACCES) 等の運用エラーは IPv4 でも同じく失敗する / 握りつぶすと「壊れているのに healthy に
    見える」状態を生むので、fallback せず surface させる (unsupported errno のみ捕捉)。
    """
    # IPv6/dual-stack が platform 非対応とみなして IPv4 に倒してよい errno。それ以外の OSError は再 raise。
    unsupported = {errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT, errno.ENOPROTOOPT}
    sock = None
    try:
        sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # IPV6_V6ONLY=0 が dual-stack の要。設定不可なら下の except で IPv4 fallback に倒す
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        sock.bind(("::", PORT))
        sock.listen()
        sock.set_inheritable(True)
        return sock
    except AttributeError:
        # socket.AF_INET6 / IPV6_V6ONLY 属性が無い (古い / 制限された Python) = IPv6 非対応
        if sock is not None:
            sock.close()
        return _ipv4_socket()
    except OSError as exc:
        # 部分構築した IPv6 socket は同一 PORT を掴んでいるので閉じる
        if sock is not None:
            sock.close()
        if exc.errno in unsupported:
            return _ipv4_socket()   # IPv6/dual-stack が platform で使えない → IPv4 に倒す
        raise                       # EADDRINUSE / EACCES 等の運用エラーは隠さず surface


if __name__ == "__main__":
    config = uvicorn.Config(build_app(), host=LISTEN_HOST, port=PORT)
    server = uvicorn.Server(config)
    server.run(sockets=[_listen_socket()])

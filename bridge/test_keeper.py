# /// script
# requires-python = ">=3.11"
# dependencies = ["aiohttp>=3.9,<4", "pyte>=0.8", "pytest>=8", "pytest-asyncio>=0.23"]
# ///
"""sbkeeper tests on Linux (PosixPty stands in for ConPTY). Run: uv run --script test_keeper.py"""
import asyncio
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbkeeper  # noqa: E402


def test_key_bytes():
    assert sbkeeper.key_bytes("Enter") == "\r" and sbkeeper.key_bytes("C-c") == "\x03"
    assert sbkeeper.key_bytes("2") == "2" and sbkeeper.key_bytes("Up") == "\x1b[A"


def test_render_colours_and_history():
    import pyte
    s = pyte.HistoryScreen(20, 3, history=100, ratio=0.5)
    st = pyte.Stream(s)
    st.feed("plain\r\n\x1b[1;31mred\x1b[0m x\r\n\x1b[38;2;1;2;3mrgb\x1b[0m\r\nlast")
    assert len(s.history.top) == 1  # "plain" scrolled off the 3-line screen
    assert sbkeeper.render_line(s.history.top[0], 20, True) == "plain"
    assert sbkeeper.render_line(s.buffer[0], 20, True) == "\x1b[0;1;31mred\x1b[0m x"
    assert sbkeeper.render_line(s.buffer[1], 20, True) == "\x1b[0;38;2;1;2;3mrgb\x1b[0m"
    assert sbkeeper.render_line(s.buffer[0], 20, False) == "red x"


def test_wide_chars():
    import pyte
    s = pyte.Screen(10, 1)
    pyte.Stream(s).feed("日本ok")
    assert sbkeeper.render_line(s.buffer[0], 10, False) == "日本ok"


async def _wait(cond, t=5.0):
    for _ in range(int(t / 0.05)):
        if cond():
            return True
        await asyncio.sleep(0.05)
    return False


@pytest.mark.asyncio
async def test_keeper_end_to_end(tmp_path):
    from aiohttp import ClientSession
    from aiohttp.test_utils import TestServer
    keeper = sbkeeper.Keeper("k")
    srv = TestServer(sbkeeper.make_app(keeper))
    await srv.start_server()
    H = {"X-Keeper-Key": "k"}
    base = f"http://127.0.0.1:{srv.port}"
    try:
        async with ClientSession() as c:
            assert (await c.get(base + "/windows")).status == 403
            r = await (await c.post(base + "/windows", headers=H, json={
                "name": "t", "cwd": str(tmp_path), "cols": 40, "rows": 5,
                "argv": ["bash", "--norc", "--noprofile", "-i"], "env": {"PS1": "$ ", "X_TEST": "1"}})).json()
            pane = r["pane"]
            await c.post(base + f"/panes/{pane}/keys", headers=H,
                         json={"literal": "echo pane=$SWITCHBOARD_PANE; for i in $(seq 1 30); do echo line$i; done",
                               "keys": ["Enter"]})

            async def lines():
                return (await (await c.get(base + f"/panes/{pane}/lines", headers=H,
                                            params={"n": "100"})).json())["lines"]
            got = []
            for _ in range(100):
                got = await lines()
                if "line30" in got:
                    break
                await asyncio.sleep(0.05)
            assert f"pane={pane}" in got and "line1" in got and "line30" in got  # scrollback beyond 5 rows
            info = await (await c.get(base + f"/panes/{pane}/info", headers=H)).json()
            assert info["w"] == 40 and info["h"] == 5 and info["hist"] >= 26
            wins = await (await c.get(base + "/windows", headers=H)).json()
            assert wins[0]["pane"] == pane and wins[0]["pid"] > 0

            ws = await c.ws_connect(base + f"/panes/{pane}/attach", headers=H)
            first = await ws.receive_bytes(timeout=5)
            assert first.startswith(b"\x1b[0m\x1b[H\x1b[2J") and b"line30" in first
            await ws.send_bytes(b"echo via-ws\r")
            buf = b""
            while b"via-ws\r\n" not in buf:
                buf += await ws.receive_bytes(timeout=5)
            await ws.send_str('{"resize": [50, 8]}')
            assert await _wait(lambda: keeper.chat(pane).info()["w"] == 50)
            await ws.close()

            await c.post(base + f"/panes/{pane}/keys", headers=H, json={"literal": "exit", "keys": ["Enter"]})
            assert await _wait(lambda: not keeper.chats)  # the window goes away when its program ends
    finally:
        await srv.close()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))

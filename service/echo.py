"""Echo server."""

import asyncio
import collections
import datetime
import hashlib
import html
import itertools
import typing

from aiohttp import web


class _LoggedRequest(typing.NamedTuple):
    timestamp: float
    method: str
    path: str
    raw_path: str
    headers: list[tuple[str, str]]
    body: bytes


_requests: collections.deque[_LoggedRequest] = collections.deque()


def _hexdump(data: bytes) -> str:
    def line(batch: tuple[int, ...]) -> str:
        hex_values = " ".join(f"{byte:02x}" for byte in batch)
        ascii_values = "".join(chr(byte) if 32 <= byte <= 126 else "." for byte in batch)
        return f"{hex_values:<47}  {ascii_values}"

    return "\n".join(line(b) for b in itertools.batched(data, 16))


def _fmt_row(entry: _LoggedRequest) -> str:
    return (
        f"<tr><td>{entry.timestamp:.4f}</td>"
        f"<td>{html.escape(entry.method)}</td>"
        f"<td>{html.escape(entry.raw_path)}</td>"
        f"<td><details><summary>Headers</summary><pre>{html.escape('\n'.join(f'{k}: {v}' for k, v in entry.headers))}</pre></details>"
        f"<details><summary>Content</summary><pre>{html.escape(_hexdump(entry.body))}</pre></details></td></tr>"
    )


async def _logger(request: web.BaseRequest) -> web.Response:
    now = datetime.datetime.now(tz=datetime.UTC).timestamp()
    while _requests and _requests[0].timestamp < now - 20:
        _requests.popleft()

    if request.path.endswith(".logs"):
        path = request.path.removesuffix(".logs")
        return web.Response(
            text=f"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Logger</title>
<style>
    html{{font-family:Arial,sans-serif}}
    table{{border-collapse:collapse}}
    thead{{border-bottom:2px solid black}}
    th,td{{border:1px solid black;padding:4pt}}
</style>
</head>
<body>
<p>Recent requests to <code>{html.escape(path)}</code></p>
<table>
    <thead>
        <tr><th>UNIX Timestamp</th><th>Method</th><th>Path</th><th>&nbsp;</th></tr>
    </thead>
    <tbody>{"".join(_fmt_row(r) for r in _requests if r.path == path)}</tbody>
</table>
</body>
</html>
""".strip(),
            content_type="text/html",
        )

    _requests.append(
        _LoggedRequest(
            timestamp=now,
            method=request.method,
            path=request.path,
            raw_path=request.raw_path,
            headers=[
                (k, hashlib.sha224(v.encode()).hexdigest() if k == "x-api-key" else v)
                for k, v in request.headers.items()
                if k.lower() != "cookie"
            ],
            body=await request.read(),
        ),
    )

    return web.Response(
        text=f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Logger</title>
    <style>
        html{{font-family:Arial,sans-serif}}
    </style>
</head>
<body>
    <p>OK</p>
    <p><a href="{html.escape(request.path)}.logs">See logs</a></p>
</body>
</html>
""".strip(),
        content_type="text/html",
    )


async def _ok(_: web.BaseRequest) -> web.Response:
    return web.Response(
        text="""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OK</title>
    <style>
        html{font-family:Arial,sans-serif}
    </style>
</head>
<body>
    <p>OK</p>
</body>
</html>
""".strip(),
        content_type="text/html",
    )


async def _serve(server: asyncio.base_events.Server) -> None:
    async with server:
        await server.serve_forever()


async def _main() -> None:
    loop = asyncio.get_running_loop()
    oks = [await loop.create_server(web.Server(_ok), "0.0.0.0", port) for port in range(7770, 7777)]
    logger = await loop.create_server(web.Server(_logger), "0.0.0.0", 7778)
    await asyncio.gather(*(_serve(server) for server in [*oks, logger]))


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        print("\nShutting down server.")

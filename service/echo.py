"""Echo server."""

import asyncio
import collections
import datetime
import html
import itertools

from aiohttp import web

_requests: collections.deque[tuple[float, web.BaseRequest]] = collections.deque(maxlen=100)


def _hexdump(data: bytes) -> str:
    def line(batch: tuple[int, ...]) -> str:
        hex_values = " ".join(f"{byte:02x}" for byte in batch)
        ascii_values = "".join(chr(byte) if 32 <= byte <= 126 else "." for byte in batch)
        return f"{hex_values:<47}  {ascii_values}"

    return "\n".join(line(b) for b in itertools.batched(data, 16))


async def _fmt_row(timestamp: float, request: web.BaseRequest) -> str:
    return (
        f"<tr><td>{timestamp:.4f}</td>"
        f"<td>{html.escape(request.method)}</td>"
        f"<td>{html.escape(request.raw_path)}</td>"
        f"<td><pre>{html.escape(_hexdump(await request.read()))}</pre></td></tr>"
    )


async def _logger(request: web.BaseRequest) -> web.Response:
    _requests.append((datetime.datetime.now(tz=datetime.UTC).timestamp(), request))
    text = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Logger</title>
    <style>
        *{{box-sizing:border-box}}
        html{{font-family:Arial,sans-serif}}
        table{{border-collapse:collapse}}
        thead{{border-bottom:2px solid black}}
        th,td{{border:1px solid black;padding:4pt}}
    </style>
</head>
<body>
    <p>Recent requests</p>
    <table>
        <thead>
            <tr><th>UNIX Timestamp</th><th>Method</th><th>Path</th><th>Content</th></tr>
        </thead>
        <tbody>{"".join([await _fmt_row(*r) for r in _requests])}</tbody>
    </table>
</body>
</html>
""".strip()
    return web.Response(text=text, content_type="text/html")


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

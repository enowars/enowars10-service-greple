"""A http client wrapper."""

import logging
import re
from types import TracebackType
from typing import Self, cast

import httpx
from enochecker3 import MumbleException


class Client(httpx.AsyncClient):
    """A wrapped http client."""

    last_response: httpx.Response | None
    _logger: logging.LoggerAdapter

    async def send(
        self,
        request: httpx.Request,
        *,
        stream: bool = False,
        auth: httpx._types.AuthTypes | httpx._client.UseClientDefault | None = httpx.USE_CLIENT_DEFAULT,
        follow_redirects: bool | httpx._client.UseClientDefault = httpx.USE_CLIENT_DEFAULT,
    ) -> httpx.Response:
        """Send a request."""
        self.last_response = await super().send(
            request,
            stream=stream,
            auth=auth,
            follow_redirects=follow_redirects,
        )
        return self.last_response

    async def __aenter__(self: Self) -> Self:
        """Enter context."""
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None = None,
        exc_value: BaseException | None = None,
        traceback: TracebackType | None = None,
    ) -> None:
        """Exit context."""
        if exc_value is None or self.last_response is None:
            return
        self._logger.info(
            "Last request was %s %s",
            self.last_response.request.method,
            self.last_response.request.url,
        )
        self._logger.info(
            "Last response was %d %s %r",
            self.last_response.status_code,
            self.last_response.reason_phrase,
            self.last_response.text,
        )
        if (
            type(exc_value) is MumbleException
            and exc_value.message is not None
            and (m := re.match("/[a-z_]*/?", self.last_response.url.raw_path.decode()))
        ):
            exc_value.message += f" ({self.last_response.request.method} {m[0]})"

    @classmethod
    def wrap(cls, client: httpx.AsyncClient, logger: logging.LoggerAdapter) -> Self:
        """Wrap a http client."""
        client.__class__ = cls
        cast("Self", client).last_response = None
        cast("Self", client)._logger = logger
        return cast("Self", client)

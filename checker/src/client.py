"""A http client wrapper."""

import logging
from types import TracebackType
from typing import Self, Type, cast

import httpx
from enochecker3 import MumbleException


class Client(httpx.AsyncClient):
    """A wrapped http client."""

    last_request: httpx.Request | None
    _last_response: httpx.Response | None
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
        self.last_request = request
        self._last_response = await super().send(request, stream=stream, auth=auth, follow_redirects=follow_redirects)
        return self._last_response

    async def __aenter__(self: Self) -> Self:
        """Enter context."""
        return self

    async def __aexit__(
        self,
        exc_type: Type[BaseException] | None = None,
        exc_value: BaseException | None = None,
        traceback: TracebackType | None = None,
    ) -> None:
        """Exit context."""
        if exc_value is not None and self._last_response is not None:
            self._logger.info("Last response was %s", self._last_response.text)
        if type(exc_value) is MumbleException and exc_value.message is not None and self.last_request is not None:
            exc_value.message += f" ({self.last_request.method} {self.last_request.url.raw_path.decode()})"

    @classmethod
    def wrap(cls, client: httpx.AsyncClient, logger: logging.LoggerAdapter) -> Self:
        """Wrap a http client."""
        client.__class__ = cls
        cast("Self", client).last_request = None
        cast("Self", client)._last_response = None
        cast("Self", client)._logger = logger
        return cast("Self", client)

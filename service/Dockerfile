FROM alpine:3.23 AS builder
WORKDIR /greple
RUN apk add --no-cache zig
RUN mkdir src
RUN head -c64 /dev/urandom > src/secret.bin
COPY build.zig .
COPY build.zig.zon .
COPY src src
RUN --mount=type=cache,target=.zig-cache --mount=type=cache,target=/root/.cache/zig zig build -freference-trace=100

FROM alpine:3.23
RUN apk add --no-cache py3-aiohttp multirun
WORKDIR /data
COPY entrypoint.sh /entrypoint.sh
COPY echo.py /echo.py
COPY --from=builder /greple/zig-out/bin/greple /greple
COPY --from=builder /greple/zig-out/bin/cron /cron
ENTRYPOINT ["/entrypoint.sh"]
CMD ["multirun", "python /echo.py", "/greple", "/cron"]

FROM alpine:3.23
WORKDIR /greple
RUN apk add --no-cache zig
RUN mkdir src
RUN head -c64 /dev/urandom > src/secret.bin
COPY build.zig .
COPY build.zig.zon .
COPY src src
RUN --mount=type=cache,target=.zig-cache --mount=type=cache,target=/root/.cache/zig zig build -Doptimize=ReleaseSafe
WORKDIR /data
CMD ["/greple/zig-out/bin/greple"]

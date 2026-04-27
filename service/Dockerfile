FROM alpine:3.23
RUN apk add --no-cache zig
WORKDIR /src
COPY build.zig .
COPY build.zig.zon .
COPY src src
RUN zig test src/query.zig
RUN zig build

FROM scratch
COPY --from=0 /src/zig-out/bin/greple .
COPY --from=0 /lib/ld-musl-*.so.1 /lib/
CMD ["/greple"]

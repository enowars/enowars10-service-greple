FROM alpine:3.23
WORKDIR /greple
RUN apk add --no-cache zig
COPY build.zig .
COPY build.zig.zon .
COPY src src
RUN --mount=type=cache,target=.zig-cache --mount=type=cache,target=/root/.cache/zig zig build

FROM alpine:3.23
WORKDIR /data
RUN mkdir documents
RUN mkdir index
RUN mkdir urls
RUN mkdir users

FROM scratch
WORKDIR /data
COPY --from=0 /lib/ld-musl-*.so.1 /lib/
COPY --from=0 /bin/grep /bin/
COPY --from=1 /data /initial-data
COPY --from=0 /greple/zig-out/bin/entrypoint /
COPY --from=0 /greple/zig-out/bin/greple /
ENTRYPOINT ["/entrypoint"]
CMD ["/greple"]

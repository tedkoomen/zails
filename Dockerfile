ARG ZIG_VERSION=0.15.2
ARG DEBIAN_VERSION=bookworm

FROM debian:${DEBIAN_VERSION}-slim AS zig

ARG ZIG_VERSION
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) zig_arch="x86_64" ;; \
        arm64) zig_arch="aarch64" ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    /opt/zig/zig version

FROM debian:${DEBIAN_VERSION}-slim AS builder

COPY --from=zig /opt/zig /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
COPY . .

RUN zig build -Doptimize=ReleaseFast

FROM builder AS test
RUN zig build test

FROM debian:${DEBIAN_VERSION}-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/zig-out/bin/server /usr/local/bin/zails-server
COPY --from=builder /app/zig-out/bin/zails /usr/local/bin/zails
COPY --from=builder /app/config /app/config

EXPOSE 8080

ENTRYPOINT ["zails-server"]
CMD ["--ports", "8080"]

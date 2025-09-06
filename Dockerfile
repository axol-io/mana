# Production Multi-stage Dockerfile for Mana Ethereum
# Optimized for axol.io deployment (no docker-compose in production)

# ============================================================
# Stage 1: Rust Builder for Native Dependencies
# ============================================================
FROM rust:1.75-alpine AS rust-builder

# Install build dependencies
RUN apk add --no-cache \
    musl-dev \
    openssl-dev \
    openssl-libs-static

WORKDIR /build

# Copy Rust native code
COPY apps/ex_wire/native /native

# Build Rust NIFs
WORKDIR /native/bls_nif
RUN cargo build --release --target x86_64-unknown-linux-musl

WORKDIR /native/kzg_nif  
RUN cargo build --release --target x86_64-unknown-linux-musl

# ============================================================
# Stage 2: Elixir Dependencies
# ============================================================
FROM hexpm/elixir:1.18.4-erlang-26.2.4-alpine-3.19.1 AS deps

# Install build dependencies
RUN apk add --no-cache \
    git \
    gcc \
    g++ \
    make \
    libc-dev \
    openssl-dev \
    ncurses-dev \
    libsodium-dev

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
COPY apps/blockchain/mix.exs ./apps/blockchain/
COPY apps/cli/mix.exs ./apps/cli/
COPY apps/common/mix.exs ./apps/common/
COPY apps/evm/mix.exs ./apps/evm/
COPY apps/ex_wire/mix.exs ./apps/ex_wire/
COPY apps/exth/mix.exs ./apps/exth/
COPY apps/exth_crypto/mix.exs ./apps/exth_crypto/
COPY apps/jsonrpc2/mix.exs ./apps/jsonrpc2/
COPY apps/merkle_patricia_tree/mix.exs ./apps/merkle_patricia_tree/

# Fetch dependencies
ENV MIX_ENV=prod
RUN mix deps.get --only prod && \
    mix deps.compile

# ============================================================
# Stage 3: Application Build
# ============================================================
FROM hexpm/elixir:1.18.4-erlang-26.2.4-alpine-3.19.1 AS builder

# Install runtime build dependencies
RUN apk add --no-cache \
    git \
    gcc \
    g++ \
    make \
    libc-dev \
    openssl-dev \
    ncurses-dev \
    libsodium-dev

WORKDIR /app

# Copy dependencies from previous stage
COPY --from=deps /app/deps ./deps
COPY --from=deps /app/_build ./_build
COPY --from=deps /root/.mix /root/.mix

# Copy Rust artifacts
COPY --from=rust-builder /native/bls_nif/target/x86_64-unknown-linux-musl/release/libbls_nif.so \
     ./apps/ex_wire/priv/native/
COPY --from=rust-builder /native/kzg_nif/target/x86_64-unknown-linux-musl/release/libkzg_nif.so \
     ./apps/ex_wire/priv/native/

# Copy application source
COPY config ./config
COPY apps ./apps
COPY rel ./rel

# Set production environment
ENV MIX_ENV=prod
ENV RUSTLER_SKIP_COMPILE=1

# Compile application
RUN mix compile

# Build release
RUN mix release

# ============================================================
# Stage 4: Runtime Image
# ============================================================
FROM alpine:3.19.1 AS runtime

# Install runtime dependencies only
RUN apk add --no-cache \
    bash \
    openssl \
    ncurses \
    libstdc++ \
    libgcc \
    libsodium \
    ca-certificates \
    curl \
    jq \
    dumb-init

# Create non-root user
RUN addgroup -g 1000 mana && \
    adduser -u 1000 -G mana -s /bin/bash -D mana

# Create necessary directories
RUN mkdir -p /app /data /logs /tmp/app && \
    chown -R mana:mana /app /data /logs /tmp/app

WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=mana:mana /app/_build/prod/rel/mana ./

# Set up environment
ENV LANG=C.UTF-8 \
    HOME=/app \
    RELEASE_TMP=/tmp/app \
    RELEASE_NODE=mana@127.0.0.1 \
    RELEASE_COOKIE=changeme \
    REPLACE_OS_VARS=true \
    DATA_DIR=/data \
    LOG_DIR=/logs

# Switch to non-root user
USER mana:mana

# Expose ports
EXPOSE 4369 8545 8546 9568 30303/tcp 30303/udp

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:9568/health || exit 1

# Volume mount points
VOLUME ["/data", "/logs"]

# Use dumb-init to handle signals properly
ENTRYPOINT ["dumb-init", "--"]

# Start the release
CMD ["/app/bin/mana", "start"]

# ============================================================
# Stage 5: Development Image (optional, for local testing)
# ============================================================
FROM runtime AS development

USER root

# Install development tools
RUN apk add --no-cache \
    inotify-tools \
    vim \
    htop \
    net-tools \
    tcpdump \
    strace

# Install k9s for Kubernetes management
RUN curl -Lo /usr/local/bin/k9s https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64 && \
    chmod +x /usr/local/bin/k9s

USER mana:mana

# Development entrypoint with hot-reload support
CMD ["/app/bin/mana", "start_iex"]
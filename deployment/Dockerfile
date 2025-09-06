# Multi-stage Dockerfile for Mana Ethereum Client Ultra-Performance Mode

# Stage 1: Builder
FROM hexpm/elixir:1.15.7-erlang-26.1.2-ubuntu-jammy-20230126 AS builder

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Rust for native extensions
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Set work directory
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
COPY apps/*/mix.exs apps/*/
COPY config config

# Set environment for ultra-performance build
ENV MIX_ENV=prod
ENV MANA_ULTRA_PERFORMANCE=true
ENV VERKLE_SIMD_ENABLED=true
ENV EVM_SIMD_ENABLED=true
ENV LIBP2P_MESH_OPTIMIZATION=true
ENV RUSTFLAGS="-C target-cpu=native -C opt-level=3"

# Get dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy source code
COPY . .

# Build native extensions with optimizations
RUN cd apps/ex_wire/native/bls_nif && \
    cargo build --release
RUN cd apps/ex_wire/native/kzg_nif && \
    cargo build --release
RUN cd apps/merkle_patricia_tree/native/verkle_crypto && \
    cargo build --release

# Compile application
RUN mix compile

# Create release
RUN mix release

# Stage 2: Runtime
FROM ubuntu:jammy-20230126 AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    openssl \
    libssl3 \
    ca-certificates \
    curl \
    jq \
    htop \
    && rm -rf /var/lib/apt/lists/*

# Create app user
RUN groupadd -r mana && useradd -r -g mana mana

# Set work directory
WORKDIR /opt/mana

# Copy release from builder stage
COPY --from=builder --chown=mana:mana /app/_build/prod/rel/mana ./

# Create necessary directories
RUN mkdir -p /opt/mana/data /opt/mana/logs /opt/mana/config && \
    chown -R mana:mana /opt/mana

# Copy deployment scripts
COPY --chown=mana:mana deployment/scripts/ ./scripts/
RUN chmod +x ./scripts/*.sh

# Copy ultra-performance configuration
COPY --chown=mana:mana deployment/config/ultra_performance.config ./config/

# Health check script
COPY --chown=mana:mana deployment/healthcheck.sh ./
RUN chmod +x healthcheck.sh

# Expose ports
EXPOSE 8545 8546 30303 9090

# Switch to app user
USER mana

# Set environment variables
ENV RELEASE_DISTRIBUTION=name
ENV RELEASE_NODE=mana@localhost
ENV MANA_ULTRA_PERFORMANCE=true
ENV VERKLE_SIMD_ENABLED=true
ENV EVM_SIMD_ENABLED=true

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ./healthcheck.sh

# Start command
CMD ["./bin/mana", "start"]
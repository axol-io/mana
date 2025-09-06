# Installation

## Requirements

- Elixir 1.18.4+
- Erlang 27.2+
- AntidoteDB (for distributed features)

## Quick Install

```bash
# Clone repository
git clone --recurse-submodules https://github.com/axol-io/mana.git
cd mana

# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test --exclude network
```

## Docker Installation

```bash
# Pull official image
docker pull mana-ethereum:latest

# Run node
docker run -d \
  --name mana-node \
  -p 8545:8545 \
  -p 8546:8546 \
  -v mana-data:/opt/mana/data \
  mana-ethereum:latest
```

## Building from Source

### Prerequisites

Install Elixir and Erlang via your system package manager or asdf:

```bash
# Using asdf
asdf plugin-add erlang
asdf plugin-add elixir
asdf install erlang 27.2
asdf install elixir 1.18.4
```

### Build Process

```bash
# Get source code
git clone --recurse-submodules https://github.com/axol-io/mana.git
cd mana

# Install dependencies
mix deps.get

# Compile native extensions
mix compile

# Build release
mix release
```

### Verification

```bash
# Test compilation
mix test --exclude network --exclude skip_ci

# Check node startup
_build/dev/rel/mana/bin/mana run --no-discovery
```

## AntidoteDB Setup (Optional)

For distributed features, install AntidoteDB:

```bash
# Docker
docker run -d --name antidote -p 8087:8087 antidotedb/antidote

# From source
git clone https://github.com/AntidoteDB/antidote.git
cd antidote
make rel
_build/default/rel/antidote/bin/antidote start
```

## Troubleshooting

### Common Issues

**Compilation Errors**
- Ensure Elixir 1.18.4+ and Erlang 27.2+
- Run `mix clean` and recompile
- Check native extension dependencies

**Native Extension Build Failures**
- Install Rust toolchain: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- Ensure C compiler is available

**Memory Issues**
- Increase VM memory: `export ERL_MAX_HEAP_SIZE=4294967296`
- Use release build for production

### Platform-Specific Notes

**macOS**
```bash
# Install dependencies
brew install autoconf automake libtool

# For Apple Silicon
export CARGO_TARGET_DIR=target
```

**Ubuntu/Debian**
```bash
# Install dependencies
sudo apt-get install build-essential autoconf automake libtool
```

**CentOS/RHEL**
```bash
# Install dependencies
sudo yum groupinstall "Development Tools"
sudo yum install autoconf automake libtool
```

## Next Steps

- [Configuration](configuration.md) - Configure your node
- [Quick Start](quick-start.md) - Get your node running
- [Production Deployment](../deployment/production.md) - Deploy to production
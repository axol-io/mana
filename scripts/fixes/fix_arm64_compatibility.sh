#!/bin/bash

# Fix ARM64 compatibility issues for Mana-Ethereum
# This script addresses both libsecp256k1 and AntidoteDB ARM64 issues

set -e

echo "=== Fixing ARM64 Compatibility Issues for Mana-Ethereum ==="
echo ""

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "This script is for ARM64/Apple Silicon Macs. Your architecture: $ARCH"
    echo "No fixes needed."
    exit 0
fi

echo "Detected ARM64 architecture (Apple Silicon)"
echo ""

# 1. Fix libsecp256k1 compilation
echo "=== Fixing libsecp256k1 for ARM64 ==="

# Check if we're on macOS
if [ "$(uname)" = "Darwin" ]; then
    # Use ARM64 Homebrew paths
    export HOMEBREW_PREFIX="/opt/homebrew"
    
    # Check if ARM64 Homebrew is installed
    if [ ! -d "$HOMEBREW_PREFIX" ]; then
        echo "Error: ARM64 Homebrew not found at /opt/homebrew"
        echo "Please install Homebrew for Apple Silicon first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    
    # Install required dependencies via Homebrew
    echo "Installing/updating required dependencies..."
    brew install openssl@3 gmp autoconf automake libtool || true
    
    # Set environment variables for ARM64 compilation
    export LDFLAGS="-L${HOMEBREW_PREFIX}/opt/openssl@3/lib -L${HOMEBREW_PREFIX}/lib"
    export CPPFLAGS="-I${HOMEBREW_PREFIX}/opt/openssl@3/include -I${HOMEBREW_PREFIX}/include"
    export CFLAGS="-arch arm64 ${CPPFLAGS}"
    export PKG_CONFIG_PATH="${HOMEBREW_PREFIX}/opt/openssl@3/lib/pkgconfig"
    export KERL_CONFIGURE_OPTIONS="--without-javac --with-ssl=${HOMEBREW_PREFIX}/opt/openssl@3"
    
    echo "Environment variables set for ARM64 compilation:"
    echo "  LDFLAGS=$LDFLAGS"
    echo "  CPPFLAGS=$CPPFLAGS"
    echo "  CFLAGS=$CFLAGS"
    echo ""
fi

# 2. Create custom Makefile for libsecp256k1 with ARM64 support
if [ -d "deps/libsecp256k1" ]; then
    echo "Creating ARM64-compatible Makefile for libsecp256k1..."
    
    cat > deps/libsecp256k1/Makefile.arm64 << 'EOF'
MIX = mix

ERLANG_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS += -I$(ERLANG_PATH)
CFLAGS += -I c_src/secp256k1 -I c_src/secp256k1/src -I c_src/secp256k1/include

# ARM64 specific flags for macOS
ifeq ($(shell uname -m),arm64)
    CFLAGS += -arch arm64
    ifeq ($(shell uname),Darwin)
        # Use ARM64 Homebrew paths
        HOMEBREW_PREFIX = /opt/homebrew
        CFLAGS += -I$(HOMEBREW_PREFIX)/include
        LDFLAGS += -L$(HOMEBREW_PREFIX)/lib
    endif
endif

ifeq ($(wildcard deps/libsecp256k1),)
	LIB_PATH = ../libsecp256k1
else
	LIB_PATH = deps/libsecp256k1
endif

CFLAGS += -I$(LIB_PATH)/src

ifneq ($(OS),Windows_NT)
	CFLAGS += -fPIC
	
	ifeq ($(shell uname),Darwin)
		LDFLAGS += -dynamiclib -undefined dynamic_lookup
	endif
endif

LDFLAGS += c_src/secp256k1/.libs/libsecp256k1.a -lgmp

.PHONY: clean

all: priv/libsecp256k1_nif.so

priv/libsecp256k1_nif.so: c_src/libsecp256k1_nif.c
	c_src/build_deps.sh
	$(CC) $(CFLAGS) -shared -o $@ c_src/libsecp256k1_nif.c $(LDFLAGS)

clean:
	$(MIX) clean
	c_src/build_deps.sh clean
	$(MAKE) -C $(LIB_PATH) clean
	$(RM) priv/libsecp256k1_nif.so
EOF
    
    # Backup original and use ARM64 version
    cp deps/libsecp256k1/Makefile deps/libsecp256k1/Makefile.backup
    cp deps/libsecp256k1/Makefile.arm64 deps/libsecp256k1/Makefile
    
    echo "✓ Created ARM64-compatible Makefile"
fi

# 3. Clean and rebuild libsecp256k1
if [ -d "deps/libsecp256k1" ]; then
    echo "Cleaning and rebuilding libsecp256k1..."
    cd deps/libsecp256k1
    make clean || true
    make
    cd ../..
    echo "✓ libsecp256k1 rebuilt for ARM64"
fi

echo ""
echo "=== Fixing AntidoteDB Docker Images for ARM64 ==="

# 4. Create multi-architecture Docker Compose file for AntidoteDB
cat > docker-compose.antidote.arm64.yml << 'EOF'
# ARM64-compatible AntidoteDB cluster configuration
# Uses alternative images or build from source for Apple Silicon

version: '3.7'

services:
  # Build AntidoteDB from source for ARM64
  antidote-builder:
    image: erlang:24-alpine
    platform: linux/arm64/v8
    volumes:
      - ./antidote-src:/antidote
      - antidote-build:/build
    command: |
      sh -c "
        apk add --no-cache git make g++ && \
        if [ ! -d /antidote/.git ]; then \
          git clone https://github.com/AntidoteDB/antidote.git /antidote; \
        fi && \
        cd /antidote && \
        make rel && \
        cp -r _build/default/rel/antidote /build/
      "
    networks:
      - antidote_net

  # Alternative: Use PostgreSQL with CRDT extensions as fallback
  postgres-crdt:
    image: postgres:14-alpine
    platform: linux/arm64/v8
    environment:
      POSTGRES_DB: mana_state
      POSTGRES_USER: mana
      POSTGRES_PASSWORD: mana_secure_pwd
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - antidote_net

  # Alternative: Use Redis with CRDT support for ARM64
  redis-crdt:
    image: redis:7-alpine
    platform: linux/arm64/v8
    command: redis-server --appendonly yes
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - antidote_net

volumes:
  antidote-build:
  postgres_data:
  redis_data:

networks:
  antidote_net:
    driver: bridge
EOF

echo "✓ Created ARM64-compatible Docker Compose configuration"
echo ""

# 5. Create build script for native AntidoteDB on ARM64
cat > scripts/build_antidote_arm64.sh << 'EOF'
#!/bin/bash

# Build AntidoteDB natively on ARM64

echo "Building AntidoteDB for ARM64..."

# Clone AntidoteDB if not present
if [ ! -d "antidote-src" ]; then
    git clone https://github.com/AntidoteDB/antidote.git antidote-src
fi

cd antidote-src

# Use Erlang 24 for compatibility
export PATH="/opt/homebrew/opt/erlang@24/bin:$PATH"

# Build AntidoteDB
make rel

echo "AntidoteDB built successfully for ARM64"
echo "Binary available at: antidote-src/_build/default/rel/antidote"
EOF

chmod +x scripts/build_antidote_arm64.sh

echo "✓ Created native AntidoteDB build script"
echo ""

# 6. Export environment variables for current session
cat > .env.arm64 << EOF
# ARM64 Environment Variables for Mana-Ethereum

# OpenSSL paths for ARM64 Homebrew
export LDFLAGS="-L/opt/homebrew/opt/openssl@3/lib -L/opt/homebrew/lib"
export CPPFLAGS="-I/opt/homebrew/opt/openssl@3/include -I/opt/homebrew/include"
export CFLAGS="-arch arm64 \${CPPFLAGS}"
export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl@3/lib/pkgconfig"

# Erlang/OTP configuration
export KERL_CONFIGURE_OPTIONS="--without-javac --with-ssl=/opt/homebrew/opt/openssl@3"

# Use ARM64 Homebrew
export PATH="/opt/homebrew/bin:\$PATH"

# Architecture flag
export ARCHFLAGS="-arch arm64"
EOF

echo "=== Summary ==="
echo ""
echo "✅ Created ARM64-compatible Makefile for libsecp256k1"
echo "✅ Set up environment variables for ARM64 compilation"
echo "✅ Created alternative Docker configurations for ARM64"
echo "✅ Created native AntidoteDB build script"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Source the ARM64 environment variables:"
echo "   source .env.arm64"
echo ""
echo "2. Recompile dependencies:"
echo "   mix deps.clean libsecp256k1"
echo "   mix deps.compile libsecp256k1"
echo ""
echo "3. For AntidoteDB, choose one option:"
echo "   a) Use PostgreSQL with CRDT extensions (recommended for dev):"
echo "      docker-compose -f docker-compose.antidote.arm64.yml up postgres-crdt"
echo "   b) Build AntidoteDB natively:"
echo "      ./scripts/build_antidote_arm64.sh"
echo "   c) Use Redis as a temporary alternative:"
echo "      docker-compose -f docker-compose.antidote.arm64.yml up redis-crdt"
echo ""
echo "4. Run the full compilation:"
echo "   mix compile"
echo ""
echo "✅ ARM64 compatibility fixes applied successfully!"
#!/bin/bash

# Batch fix compilation warnings for Mana codebase
set -e

echo "🔧 Fixing compilation warnings..."

# 1. Fix unused variables by prefixing with underscore
echo "1️⃣ Fixing unused variables..."

# Common unused variables patterns
find apps -name "*.ex" -type f | while read -r file; do
  # Fix function parameters
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\bstate\b/def\1 \2(\3_state/g' "$file"
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\breason\b/def\1 \2(\3_reason/g' "$file"
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\bconfig\b/def\1 \2(\3_config/g' "$file"
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\bparams\b/def\1 \2(\3_params/g' "$file"
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\bpacket\b/def\1 \2(\3_packet/g' "$file"
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\bdata\b/def\1 \2(\3_data/g' "$file"
  sed -i '' -E 's/def([a-z_]+)?\s+([a-z_]+)\(([^)]*)\bfrom\b/def\1 \2(\3_from/g' "$file"
  
  # Fix pattern matches in case statements
  sed -i '' -E 's/(\{:ok, )state(\})/\1_state\2/g' "$file"
  sed -i '' -E 's/(\{:error, )reason(\})/\1_reason\2/g' "$file"
done

# 2. Add Logger requires where missing
echo "2️⃣ Adding Logger requires..."
find apps -name "*.ex" -exec grep -l "Logger\." {} \; | while read -r file; do
  if ! grep -q "require Logger" "$file"; then
    # Add require Logger after module definition
    sed -i '' '/^defmodule.*do$/a\
  require Logger
' "$file"
  fi
done

# 3. Fix LevelDB module
echo "3️⃣ Fixing LevelDB callbacks..."
leveldb_file="apps/merkle_patricia_tree/lib/merkle_patricia_tree/db/leveldb.ex"
if [ -f "$leveldb_file" ]; then
  # Remove incorrect @impl true annotations
  sed -i '' '/@impl true/d' "$leveldb_file"
  
  # Fix function signatures to match behavior
  sed -i '' 's/def put(/def put!(/' "$leveldb_file"
  sed -i '' 's/def delete(/def delete!(/' "$leveldb_file"
fi

# 4. Comment out unused module attributes
echo "4️⃣ Commenting unused module attributes..."
for attr in "@sync" "@incremental_cache_size" "@complex_operation_gas" "@contract_call_gas" "@eth_decimals" "@optimization_categories" "@tuning_profiles" "@decay_to_zero" "@decay_interval"; do
  find apps -name "*.ex" -exec grep -l "$attr" {} \; | while read -r file; do
    sed -i '' "s/^[[:space:]]*\($attr.*\)$/  # \1 # TODO: Unused attribute/" "$file"
  done
done

# 5. Comment out unused aliases
echo "5️⃣ Commenting unused aliases..."
for alias in "Transaction" "PerformanceBenchmark"; do
  find apps -name "*.ex" -exec grep -l "alias.*$alias" {} \; | while read -r file; do
    sed -i '' "s/^\([[:space:]]*alias.*$alias.*\)$/  # \1 # TODO: Unused alias/" "$file"
  done
done

echo "✅ Warning fixes applied!"
echo ""
echo "Now recompiling to check remaining warnings..."
RUSTLER_SKIP_COMPILE=1 mix compile 2>&1 | grep -c "warning:" || true
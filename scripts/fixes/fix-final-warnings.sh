#!/bin/bash

# Fix the remaining underscored variable warnings in HSM files

echo "Fixing remaining underscored variable warnings..."

# Fix all _state parameters in function definitions
find apps/exth_crypto/lib/exth_crypto/hsm -name "*.ex" -exec sed -i '' \
  -e 's/def \([a-z_]*\)(\(.*\), _from, _state)/def \1(\2, _from, state)/g' \
  -e 's/def \([a-z_]*\)(\(.*\), _state)/def \1(\2, state)/g' \
  -e 's/def \([a-z_]*\)(_state)/def \1(state)/g' \
  {} \;

# Fix all _config parameters in function definitions  
find apps/exth_crypto/lib/exth_crypto/hsm -name "*.ex" -exec sed -i '' \
  -e 's/def \([a-z_]*\)(_config)/def \1(config)/g' \
  -e 's/defp \([a-z_]*\)(_config)/defp \1(config)/g' \
  {} \;

# Fix all _reason parameters
find apps/exth_crypto/lib/exth_crypto/hsm -name "*.ex" -exec sed -i '' \
  -e 's/defp \([a-z_]*\)(\(.*\), _reason)/defp \1(\2, reason)/g' \
  -e 's/def \([a-z_]*\)(_reason, \(.*\))/def \1(reason, \2)/g' \
  {} \;

# Fix all _params parameters
find apps/exth_crypto/lib/exth_crypto/hsm -name "*.ex" -exec sed -i '' \
  -e 's/def \([a-z_]*\)(_params)/def \1(params)/g' \
  -e 's/defp \([a-z_]*\)(_params, \(.*\))/defp \1(params, \2)/g' \
  {} \;

echo "Done fixing underscored variables"

# Recompile and count warnings
echo "Recompiling..."
RUSTLER_SKIP_COMPILE=1 mix compile 2>&1 | grep -c "warning:" || echo "0 warnings"
#!/bin/bash

echo "🔧 Fixing compilation warnings..."

# Step 1: Get list of files with unused variable warnings
echo "1️⃣ Finding files with unused variables..."
FILES=$(RUSTLER_SKIP_COMPILE=1 mix compile 2>&1 | grep "warning:" | grep "is unused" | grep -oE "apps/[^:]+\.ex" | sort -u)

# Step 2: Fix unused variables by prefixing with underscore
echo "2️⃣ Fixing unused variables..."
for file in $FILES; do
    if [ -f "$file" ]; then
        echo "   Processing $file"
        
        # Fix unused function parameters
        sed -i '' -E 's/def([p]?) ([a-zA-Z_]+)\(([^_][a-z_]+)\)/def\1 \2(_\3)/g' "$file"
        sed -i '' -E 's/def([p]?) ([a-zA-Z_]+)\(([^,]+), ([^_][a-z_]+)\)/def\1 \2(\3, _\4)/g' "$file"
        sed -i '' -E 's/def([p]?) ([a-zA-Z_]+)\(([^_][a-z_]+), ([^,]+)\)/def\1 \2(_\3, \4)/g' "$file"
        
        # Fix unused pattern match variables in case statements
        sed -i '' -E 's/^([[:space:]]*)([a-z_]+) ->$/\1_\2 ->/g' "$file"
        
        # Fix unused variables in function heads
        sed -i '' -E 's/^([[:space:]]*)([a-z_]+) = /\1_\2 = /g' "$file"
    fi
done

# Step 3: Format code
echo "3️⃣ Formatting code..."
mix format

echo "✅ Warning fixes complete!"

# Step 4: Show remaining warnings count
echo "📊 Remaining warnings:"
RUSTLER_SKIP_COMPILE=1 mix compile 2>&1 | grep -c "warning:"
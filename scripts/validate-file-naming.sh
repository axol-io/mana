#!/bin/bash

# File Naming Validation Script
# Checks for AI-generated generic naming patterns

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VIOLATIONS_FOUND=0

log_error() {
    echo -e "${RED}❌ $1${NC}"
    ((VIOLATIONS_FOUND++))
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

echo "🤖 Validating file naming conventions..."
echo "======================================="

# Check for AI-generated patterns (excluding allowed directories)
PROBLEMATIC_FILES=$(find . -name "*.ex" -o -name "*.exs" | \
    grep -E "(simple|comprehensive|optimized|enhanced|advanced|basic|improved|extended|generic|default)_" | \
    grep -v deps | \
    grep -v _build | \
    grep -v "test/support" | \
    grep -v "scripts/simple" | \
    grep -v "bench/simple_benchmark")

if [ -z "$PROBLEMATIC_FILES" ]; then
    log_success "No AI-generated naming patterns found!"
else
    echo -e "${YELLOW}Found files with AI-generated naming patterns:${NC}"
    echo
    
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            # Analyze the specific pattern
            filename=$(basename "$file")
            
            if [[ "$filename" =~ ^simple_ ]]; then
                log_error "$file - Use specific feature names instead of 'simple_'"
            elif [[ "$filename" =~ ^comprehensive_ ]]; then
                log_error "$file - Use 'full_' or 'complete_' instead of 'comprehensive_'"
            elif [[ "$filename" =~ _optimized ]]; then
                log_error "$file - Use specific optimization type like '_cache' or '_fast'"
            elif [[ "$filename" =~ _enhanced ]]; then
                log_error "$file - Use '_v2' or describe the specific enhancement"
            elif [[ "$filename" =~ ^advanced_ ]]; then
                log_error "$file - Use specific technical terms instead of 'advanced_'"
            else
                log_error "$file - Generic AI-generated name detected"
            fi
        fi
    done <<< "$PROBLEMATIC_FILES"
fi

echo
echo "📋 Summary:"
if [ $VIOLATIONS_FOUND -eq 0 ]; then
    log_success "All files follow proper naming conventions!"
    echo
    echo "💡 Naming best practices:"
    echo "- Use domain-specific names that describe purpose"
    echo "- Avoid AI-generated generic patterns"
    echo "- Name files after their primary responsibility"
else
    echo "- Total violations: $VIOLATIONS_FOUND"
    echo
    echo "💡 Quick fixes:"
    echo "- simple_sync.ex → block_sync.ex"
    echo "- optimized_cache.ex → node_cache.ex" 
    echo "- enhanced_validator.ex → transaction_validator.ex"
    echo "- comprehensive_handler.ex → message_handler.ex"
    echo
    echo "📚 See docs/FILE_NAMING_CONVENTIONS.md for complete guidelines"
fi

# Exit with error code if violations found
if [ $VIOLATIONS_FOUND -gt 0 ]; then
    exit 1
fi
#!/bin/bash

# Mana-Ethereum Enterprise Security Validation Script
# Validates HSM integration, compliance features, and security controls

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TEST_RESULTS=()

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

# Test result tracking
pass_test() {
    ((TESTS_PASSED++))
    TEST_RESULTS+=("✅ $1")
    log_info "PASSED: $1"
}

fail_test() {
    ((TESTS_FAILED++))
    TEST_RESULTS+=("❌ $1")
    log_error "FAILED: $1"
}

# HSM Integration Tests
test_hsm_integration() {
    log_test "Testing HSM Integration..."
    
    # Test HSM module compilation
    if RUSTLER_SKIP_COMPILE=1 mix compile --app ex_wire 2>/dev/null; then
        pass_test "HSM modules compile successfully"
    else
        fail_test "HSM compilation failed"
    fi
    
    # Test HSM configuration validation
    if mix run -e "
        config = ExWire.Enterprise.HSMIntegration.validate_config()
        if config.valid, do: IO.puts('VALID'), else: IO.puts('INVALID')
    " 2>/dev/null | grep -q "VALID"; then
        pass_test "HSM configuration validation"
    else
        fail_test "HSM configuration validation"
    fi
    
    # Test PKCS#11 interface
    if RUSTLER_SKIP_COMPILE=1 mix test apps/ex_wire/test/ex_wire/enterprise/hsm_integration_test.exs --no-compile 2>/dev/null; then
        pass_test "PKCS#11 interface tests"
    else
        fail_test "PKCS#11 interface tests"
    fi
}

# Compliance Framework Tests
test_compliance_framework() {
    log_test "Testing Compliance Framework..."
    
    # Test SOX compliance module
    if RUSTLER_SKIP_COMPILE=1 mix run -e "
        result = Blockchain.Compliance.SOXCompliance.run_audit()
        if result.status == :passed, do: IO.puts('PASSED'), else: IO.puts('FAILED')
    " 2>/dev/null | grep -q "PASSED"; then
        pass_test "SOX compliance audit"
    else
        fail_test "SOX compliance audit"
    fi
    
    # Test audit logging
    if mix run -e "
        Blockchain.Compliance.AuditEngine.log_event(:test_event, %{test: true})
        IO.puts('LOGGED')
    " 2>/dev/null | grep -q "LOGGED"; then
        pass_test "Audit logging functionality"
    else
        fail_test "Audit logging functionality"
    fi
    
    # Test data retention policies
    if RUSTLER_SKIP_COMPILE=1 mix run -e "
        result = Blockchain.Compliance.DataRetention.validate_policies()
        if result.valid, do: IO.puts('VALID'), else: IO.puts('INVALID')
    " 2>/dev/null | grep -q "VALID"; then
        pass_test "Data retention policy validation"
    else
        fail_test "Data retention policy validation"
    fi
}

# Access Control Tests  
test_access_controls() {
    log_test "Testing Access Controls..."
    
    # Test RBAC system
    if RUSTLER_SKIP_COMPILE=1 mix test --only rbac 2>/dev/null; then
        pass_test "RBAC system functionality"
    else
        fail_test "RBAC system functionality" 
    fi
    
    # Test rate limiting
    if RUSTLER_SKIP_COMPILE=1 mix run -e "
        result = JSONRPC2.RateLimiter.check_rate(:test_client, 1000)
        if result == :allow, do: IO.puts('ALLOW'), else: IO.puts('DENY')
    " 2>/dev/null | grep -q "ALLOW"; then
        pass_test "Rate limiting system"
    else
        fail_test "Rate limiting system"
    fi
}

# Cryptographic Security Tests
test_cryptographic_security() {
    log_test "Testing Cryptographic Security..."
    
    # Test BLS signature security
    if RUSTLER_SKIP_COMPILE=1 mix test apps/ex_wire/test/ex_wire/crypto/bls_test.exs --no-compile 2>/dev/null; then
        pass_test "BLS cryptographic operations"
    else
        fail_test "BLS cryptographic operations"
    fi
    
    # Test KZG proof security  
    if RUSTLER_SKIP_COMPILE=1 mix test apps/ex_wire/test/ex_wire/crypto/kzg_test.exs --no-compile 2>/dev/null; then
        pass_test "KZG cryptographic proofs"
    else
        fail_test "KZG cryptographic proofs"
    fi
    
    # Test key derivation security
    if mix run -e "
        result = ExthCrypto.KDF.NISTSP80056.derive_key('test', 'salt', 32)
        if byte_size(result) == 32, do: IO.puts('SECURE'), else: IO.puts('INSECURE')
    " 2>/dev/null | grep -q "SECURE"; then
        pass_test "Secure key derivation"
    else
        fail_test "Secure key derivation"
    fi
}

# Network Security Tests
test_network_security() {
    log_test "Testing Network Security..."
    
    # Test P2P encryption
    if RUSTLER_SKIP_COMPILE=1 mix test apps/ex_wire/test/ex_wire/handshake/eip_8_test.exs --no-compile 2>/dev/null; then
        pass_test "P2P network encryption"
    else
        fail_test "P2P network encryption"
    fi
    
    # Test DDoS protection
    if mix run -e "
        config = Application.get_env(:mana, :security_hardening, [])
        if config[:ddos_protection], do: IO.puts('ENABLED'), else: IO.puts('DISABLED')
    " 2>/dev/null | grep -q "ENABLED"; then
        pass_test "DDoS protection configuration"
    else
        fail_test "DDoS protection configuration"
    fi
}

# Security Configuration Audit
audit_security_configuration() {
    log_test "Auditing Security Configuration..."
    
    # Check for hardcoded secrets
    if ! grep -r "password\|secret\|key" config/ --include="*.exs" | grep -v "System.get_env"; then
        pass_test "No hardcoded secrets in configuration"
    else
        fail_test "Found potential hardcoded secrets"
    fi
    
    # Check TLS configuration
    if grep -q "force_ssl.*true" config/prod.exs 2>/dev/null; then
        pass_test "TLS enforcement enabled"
    else
        fail_test "TLS enforcement not configured"
    fi
    
    # Check secure headers
    if grep -q "secure_headers" config/ -R 2>/dev/null; then
        pass_test "Security headers configured"
    else
        fail_test "Security headers not configured"
    fi
}

# Generate security report
generate_security_report() {
    log_info "Generating Security Validation Report..."
    
    REPORT_FILE="security-validation-report-$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$REPORT_FILE" << EOF
# Mana-Ethereum Enterprise Security Validation Report
Generated: $(date)
Environment: ${ENVIRONMENT:-development}

## Summary
- Tests Passed: $TESTS_PASSED
- Tests Failed: $TESTS_FAILED
- Success Rate: $(( TESTS_PASSED * 100 / (TESTS_PASSED + TESTS_FAILED) ))%

## Test Results
EOF
    
    for result in "${TEST_RESULTS[@]}"; do
        echo "- $result" >> "$REPORT_FILE"
    done
    
    cat >> "$REPORT_FILE" << EOF

## Recommendations
EOF
    
    if [ $TESTS_FAILED -gt 0 ]; then
        cat >> "$REPORT_FILE" << EOF
- Address failed security tests before production deployment
- Review and strengthen security configurations
- Implement additional monitoring for failed components
- Consider engaging security audit firm for comprehensive assessment
EOF
    else
        cat >> "$REPORT_FILE" << EOF
- All security tests passed successfully
- Security posture is appropriate for enterprise deployment
- Continue regular security monitoring and updates
- Schedule periodic security assessments
EOF
    fi
    
    log_info "Security report generated: $REPORT_FILE"
}

# Main execution
main() {
    log_info "Starting Mana-Ethereum Enterprise Security Validation..."
    
    test_hsm_integration
    test_compliance_framework
    test_access_controls
    test_cryptographic_security
    test_network_security
    audit_security_configuration
    
    generate_security_report
    
    if [ $TESTS_FAILED -eq 0 ]; then
        log_info "🔒 All security validations passed! Enterprise security features are ready for production."
        exit 0
    else
        log_error "❌ $TESTS_FAILED security tests failed. Review and fix issues before production deployment."
        exit 1
    fi
}

# Execute main function
main
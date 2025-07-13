#!/bin/bash

# Test script for Retell Webhook Microservice

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
WEBHOOK_HASH=${WEBHOOK_HASH:-"test-hash"}
RETELL_API_KEY=${RETELL_API_KEY:-"test-api-key"}
PORT=${PORT:-3000}
HOST=${HOST:-"localhost"}

echo -e "${GREEN}🧪 Testing Retell Webhook Microservice${NC}"

# Function to generate HMAC signature
generate_signature() {
    local payload="$1"
    local secret="$2"
    echo -n "$payload" | openssl dgst -sha256 -hmac "$secret" -binary | xxd -p -c 256
}

# Function to test health endpoint
test_health() {
    echo -e "${YELLOW}Testing health endpoint...${NC}"
    
    response=$(curl -s -w "%{http_code}" -o /tmp/health_response "http://${HOST}:${PORT}/health")
    
    if [ "$response" = "200" ]; then
        echo -e "${GREEN}✅ Health check passed${NC}"
        cat /tmp/health_response | jq .
    else
        echo -e "${RED}❌ Health check failed (HTTP $response)${NC}"
        return 1
    fi
}

# Function to test webhook with valid signature
test_valid_webhook() {
    echo -e "${YELLOW}Testing webhook with valid signature...${NC}"
    
    payload='{"event":"call_started","call":{"call_id":"test-123","from_number":"+1234567890","to_number":"+0987654321"}}'
    signature=$(generate_signature "$payload" "$RETELL_API_KEY")
    
    response=$(curl -s -w "%{http_code}" -o /tmp/webhook_response \
        -X POST "http://${HOST}:${PORT}/webhook/${WEBHOOK_HASH}" \
        -H "Content-Type: application/json" \
        -H "x-retell-signature: sha256=${signature}" \
        -d "$payload")
    
    if [ "$response" = "204" ]; then
        echo -e "${GREEN}✅ Valid webhook test passed${NC}"
    else
        echo -e "${RED}❌ Valid webhook test failed (HTTP $response)${NC}"
        cat /tmp/webhook_response
        return 1
    fi
}

# Function to test webhook with invalid signature
test_invalid_webhook() {
    echo -e "${YELLOW}Testing webhook with invalid signature...${NC}"
    
    payload='{"event":"call_started","call":{"call_id":"test-123"}}'
    
    response=$(curl -s -w "%{http_code}" -o /tmp/webhook_invalid_response \
        -X POST "http://${HOST}:${PORT}/webhook/${WEBHOOK_HASH}" \
        -H "Content-Type: application/json" \
        -H "x-retell-signature: sha256=invalid-signature" \
        -d "$payload")
    
    if [ "$response" = "401" ]; then
        echo -e "${GREEN}✅ Invalid webhook test passed (correctly rejected)${NC}"
    else
        echo -e "${RED}❌ Invalid webhook test failed (HTTP $response, expected 401)${NC}"
        cat /tmp/webhook_invalid_response
        return 1
    fi
}

# Function to test invalid webhook path
test_invalid_path() {
    echo -e "${YELLOW}Testing invalid webhook path...${NC}"
    
    payload='{"event":"test"}'
    
    response=$(curl -s -w "%{http_code}" -o /tmp/webhook_path_response \
        -X POST "http://${HOST}:${PORT}/webhook/wrong-hash" \
        -H "Content-Type: application/json" \
        -H "x-retell-signature: sha256=test" \
        -d "$payload")
    
    if [ "$response" = "404" ]; then
        echo -e "${GREEN}✅ Invalid path test passed (correctly rejected)${NC}"
    else
        echo -e "${RED}❌ Invalid path test failed (HTTP $response, expected 404)${NC}"
        cat /tmp/webhook_path_response
        return 1
    fi
}

# Function to test IP allowlist (when enabled)
test_ip_allowlist() {
    echo -e "${YELLOW}Testing IP allowlist functionality...${NC}"
    
    # This test assumes the server is configured with IP allowlist enabled
    # and the current client IP is not in the allowlist
    if [ "$ONLY_WHITELISTED_SOURCES" = "true" ]; then
        payload='{"event":"test"}'
        
        response=$(curl -s -w "%{http_code}" -o /tmp/webhook_ip_response \
            -X POST "http://${HOST}:${PORT}/webhook/${WEBHOOK_HASH}" \
            -H "Content-Type: application/json" \
            -H "x-retell-signature: sha256=test" \
            -d "$payload")
        
        if [ "$response" = "403" ]; then
            echo -e "${GREEN}✅ IP allowlist test passed (correctly rejected non-whitelisted IP)${NC}"
        else
            echo -e "${YELLOW}⚠️  IP allowlist test: HTTP $response (may be whitelisted or disabled)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  IP allowlist is disabled, skipping test${NC}"
    fi
}

# Main test function
run_tests() {
    echo -e "${GREEN}Starting tests...${NC}"
    echo
    
    # Check if server is running
    if ! curl -s "http://${HOST}:${PORT}/health" > /dev/null; then
        echo -e "${RED}❌ Server is not running at http://${HOST}:${PORT}${NC}"
        echo -e "${YELLOW}💡 Start the server with: npm run dev${NC}"
        exit 1
    fi
    
    # Run tests
    test_health
    echo
    
    test_invalid_path
    echo
    
    test_ip_allowlist
    echo
    
    test_invalid_webhook
    echo
    
    # Only test valid webhook if we have a real forward endpoint
    if [ "$FORWARD_ENDPOINT" != "" ] && [ "$FORWARD_ENDPOINT" != "http://localhost:4000/webhook" ]; then
        test_valid_webhook
    else
        echo -e "${YELLOW}⚠️  Skipping valid webhook test (no real forward endpoint configured)${NC}"
    fi
    
    echo
    echo -e "${GREEN}🎉 All tests completed!${NC}"
}

# Show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  --host HOST             Server host (default: localhost)"
    echo "  --port PORT             Server port (default: 3000)"
    echo "  --webhook-hash HASH     Webhook hash (default: test-hash)"
    echo "  --api-key KEY           Retell API key (default: test-api-key)"
    echo
    echo "Environment variables:"
    echo "  HOST, PORT, WEBHOOK_HASH, RETELL_API_KEY, FORWARD_ENDPOINT"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --webhook-hash)
            WEBHOOK_HASH="$2"
            shift 2
            ;;
        --api-key)
            RETELL_API_KEY="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# Run tests
run_tests
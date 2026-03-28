#!/bin/bash
# Setup script for GitLab Registry certificate configuration
# Usage: ./setup-registry-certificate.sh <registry-hostname> [runner-user]

set -e

REGISTRY_HOST="${1:-registry.gitlab.pri-os.de}"
RUNNER_USER="${2:-gitlab-runner}"
CERT_DIR="/etc/docker/certs.d/$REGISTRY_HOST"
CA_FILE="$CERT_DIR/ca.crt"

echo "=========================================="
echo "GitLab Registry Certificate Setup"
echo "=========================================="
echo ""
echo "Registry: $REGISTRY_HOST"
echo "Certificate directory: $CERT_DIR"
echo "Runner user: $RUNNER_USER"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

echo "Step 1: Extracting CA certificate from $REGISTRY_HOST..."
echo ""

# Create temporary file for certificate
TEMP_CERT=$(mktemp)
trap "rm -f $TEMP_CERT" EXIT

# Extract certificate
if ! echo | openssl s_client -showcerts -connect "$REGISTRY_HOST:443" 2>/dev/null | \
     openssl x509 -outform PEM > "$TEMP_CERT" 2>/dev/null; then
    echo -e "${RED}Error: Failed to extract certificate from $REGISTRY_HOST:443${NC}"
    echo "Make sure the registry is accessible and using HTTPS."
    exit 1
fi

# Verify certificate was extracted
if [ ! -s "$TEMP_CERT" ]; then
    echo -e "${RED}Error: Certificate file is empty${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Certificate extracted successfully${NC}"
echo ""

# Display certificate information
echo "Certificate Details:"
echo "---"
openssl x509 -in "$TEMP_CERT" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After"
echo "---"
echo ""

echo "Step 2: Creating certificate directory..."
if [ ! -d "$CERT_DIR" ]; then
    mkdir -p "$CERT_DIR"
    echo -e "${GREEN}✓ Created $CERT_DIR${NC}"
else
    echo -e "${YELLOW}⚠ Directory already exists: $CERT_DIR${NC}"
fi

echo ""
echo "Step 3: Installing certificate..."
cp "$TEMP_CERT" "$CA_FILE"
chmod 644 "$CA_FILE"
chown root:root "$CA_FILE"
echo -e "${GREEN}✓ Certificate installed to $CA_FILE${NC}"

echo ""
echo "Step 4: Verifying certificate installation..."
echo ""

# Test with Docker
if command -v docker &> /dev/null; then
    echo "Testing Docker connectivity to registry..."
    
    # Restart Docker to load new certificates
    if systemctl is-active --quiet docker; then
        echo "Restarting Docker daemon..."
        systemctl restart docker
        sleep 2
        echo -e "${GREEN}✓ Docker daemon restarted${NC}"
    fi
    
    # Test certificate
    echo ""
    echo "Testing connection to $REGISTRY_HOST..."
    if docker run --rm alpine:latest curl -s -I https://"$REGISTRY_HOST"/v2/ > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Docker can connect to registry${NC}"
    else
        echo -e "${YELLOW}⚠ Docker connection test failed (may need runner restart)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Docker not found, skipping connectivity test${NC}"
fi

echo ""
echo "Step 5: Updating GitLab Runner configuration..."
echo ""

RUNNER_CONFIG="/etc/gitlab-runner/config.toml"

if [ -f "$RUNNER_CONFIG" ]; then
    # Backup original config
    cp "$RUNNER_CONFIG" "$RUNNER_CONFIG.backup.$(date +%s)"
    echo -e "${GREEN}✓ Backup created: ${RUNNER_CONFIG}.backup.*${NC}"
    
    # Check if runner needs restart
    if systemctl is-active --quiet gitlab-runner; then
        echo "Restarting GitLab Runner..."
        systemctl restart gitlab-runner
        sleep 2
        echo -e "${GREEN}✓ GitLab Runner restarted${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Runner config not found at $RUNNER_CONFIG${NC}"
    echo "Note: Install GitLab Runner first or manually configure certificate path in config.toml"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}Setup Complete!${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Verify GitLab Runner is working:"
echo "   sudo gitlab-runner verify"
echo ""
echo "2. Update .gitlab-ci.yml to enable TLS verification:"
echo "   DOCKER_TLS_VERIFY: 1  (instead of 0)"
echo ""
echo "3. Test the pipeline by pushing a commit:"
echo "   git push gitlab"
echo ""
echo "Additional resources:"
echo "  - Configuration guide: GITLAB_RUNNER_CERTIFICATE_CONFIG.md"
echo "  - Runner config template: gitlab-runner-config.toml.template"
echo ""

#!/bin/bash
# Kubernetes setup script for GitLab Registry certificate handling
# Usage: ./setup-k8s-registry-certificate.sh <registry-hostname> <namespace> [config-name]

set -e

REGISTRY_HOST="${1:-registry.gitlab.pri-os.de}"
NAMESPACE="${2:-gitlab-runner}"
CONFIG_NAME="${3:-registry-ca}"
CERT_FILE="/tmp/registry-ca.crt"

echo "=========================================="
echo "Kubernetes Registry Certificate Setup"
echo "=========================================="
echo ""
echo "Registry: $REGISTRY_HOST"
echo "Namespace: $NAMESPACE"
echo "ConfigMap name: $CONFIG_NAME"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

# Check cluster connection
echo "Checking Kubernetes cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to cluster${NC}"
echo ""

# Check namespace exists
echo "Checking namespace: $NAMESPACE"
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}⚠ Namespace '$NAMESPACE' not found. Creating...${NC}"
    kubectl create namespace "$NAMESPACE"
    echo -e "${GREEN}✓ Namespace created${NC}"
else
    echo -e "${GREEN}✓ Namespace exists${NC}"
fi
echo ""

# Extract certificate
echo "Step 1: Extracting CA certificate from $REGISTRY_HOST..."
if ! echo | openssl s_client -showcerts -connect "$REGISTRY_HOST:443" 2>/dev/null | \
     openssl x509 -outform PEM > "$CERT_FILE" 2>/dev/null; then
    echo -e "${RED}Error: Failed to extract certificate${NC}"
    exit 1
fi

if [ ! -s "$CERT_FILE" ]; then
    echo -e "${RED}Error: Certificate file is empty${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Certificate extracted${NC}"
echo ""

# Display certificate info
echo "Certificate Details:"
echo "---"
openssl x509 -in "$CERT_FILE" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After"
echo "---"
echo ""

# Create ConfigMap for the certificate
echo "Step 2: Creating ConfigMap in namespace '$NAMESPACE'..."
if kubectl get configmap "$CONFIG_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}⚠ ConfigMap already exists, replacing...${NC}"
    kubectl delete configmap "$CONFIG_NAME" -n "$NAMESPACE"
fi

kubectl create configmap "$CONFIG_NAME" \
    --from-file="$REGISTRY_HOST"="$CERT_FILE" \
    -n "$NAMESPACE"

echo -e "${GREEN}✓ ConfigMap created${NC}"
echo ""

# Create Secret for Docker login
echo "Step 3: Creating Secret for Docker registry authentication..."
echo ""
echo "Enter your registry credentials:"
read -p "Username: " REGISTRY_USER
read -sp "Password: " REGISTRY_PASSWORD
echo ""

if kubectl get secret gitlab-registry -n "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}⚠ Secret already exists, replacing...${NC}"
    kubectl delete secret gitlab-registry -n "$NAMESPACE"
fi

kubectl create secret docker-registry gitlab-registry \
    --docker-server="$REGISTRY_HOST" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASSWORD" \
    -n "$NAMESPACE"

echo -e "${GREEN}✓ Secret created${NC}"
echo ""

# Patch service account
echo "Step 4: Patching GitLab Runner service account..."
if kubectl get serviceaccount gitlab-runner -n "$NAMESPACE" &> /dev/null; then
    # Add imagePullSecrets to service account
    kubectl patch serviceaccount gitlab-runner -n "$NAMESPACE" -p \
        '{"imagePullSecrets": [{"name": "gitlab-registry"}]}'
    echo -e "${GREEN}✓ Service account patched${NC}"
else
    echo -e "${YELLOW}⚠ gitlab-runner service account not found${NC}"
    echo "Create it manually or the pod will use default service account"
fi
echo ""

# Create example pod with mounted certificate
echo "Step 5: Creating example Pod spec for GitLab Runner..."
cat > /tmp/gitlab-runner-pod-spec.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: gitlab-runner-with-certs
  namespace: $NAMESPACE
spec:
  serviceAccountName: gitlab-runner
  imagePullSecrets:
  - name: gitlab-registry

  containers:
  - name: runner
    image: $REGISTRY_HOST/gitlab-org/gitlab-runner:latest
    
    volumeMounts:
    # Mount CA certificate
    - name: registry-ca
      mountPath: /etc/docker/certs.d/$REGISTRY_HOST
      readOnly: true
    
    # Mount Docker socket
    - name: docker-sock
      mountPath: /var/run/docker.sock
    
    env:
    - name: DOCKER_TLS_VERIFY
      value: "1"
    - name: CI_REGISTRY
      value: "$REGISTRY_HOST"
  
  volumes:
  # CA certificate from ConfigMap
  - name: registry-ca
    configMap:
      name: $CONFIG_NAME
      defaultMode: 0444
  
  # Docker socket from host
  - name: docker-sock
    hostPath:
      path: /var/run/docker.sock
      type: Socket
EOF

echo -e "${GREEN}✓ Pod spec created at /tmp/gitlab-runner-pod-spec.yaml${NC}"
echo ""

# Show verifications
echo "Step 6: Verification commands..."
echo ""
echo "Check ConfigMap:"
echo "  kubectl get configmap $CONFIG_NAME -n $NAMESPACE"
echo "  kubectl describe configmap $CONFIG_NAME -n $NAMESPACE"
echo ""
echo "Check Secret:"
echo "  kubectl get secrets -n $NAMESPACE | grep gitlab-registry"
echo ""
echo "View pod spec:"
echo "  cat /tmp/gitlab-runner-pod-spec.yaml"
echo ""

# Cleanup
rm "$CERT_FILE"

echo "=========================================="
echo -e "${GREEN}Setup Complete!${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Verify ConfigMap was created:"
echo "   kubectl get configmap -n $NAMESPACE"
echo ""
echo "2. Verify Secret was created:"
echo "   kubectl get secret -n $NAMESPACE"
echo ""
echo "3. Update your GitLab Runner Helm values:"
echo "   runners:"
echo "     docker:"
echo "       tls_verify: true"
echo "       tls_ca_file: /etc/docker/certs.d/$REGISTRY_HOST/ca.crt"
echo "       volumes:"
echo "       - name: registry-ca"
echo "         configMap:"
echo "           name: $CONFIG_NAME"
echo "         mountPath: /etc/docker/certs.d/$REGISTRY_HOST"
echo ""
echo "4. Deploy GitLab Runner:"
echo "   helm upgrade --install gitlab-runner gitlab/gitlab-runner \\"
echo "     -f values.yaml \\"
echo "     -n $NAMESPACE"
echo ""
echo "5. Test by submitting a new pipeline job"
echo ""
echo "Resources:"
echo "  - Pod spec: /tmp/gitlab-runner-pod-spec.yaml"
echo "  - Config guide: GITLAB_RUNNER_CERTIFICATE_CONFIG.md"
echo ""

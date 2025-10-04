#!/bin/bash
set -e

echo "=============================================="
echo "Dylan Taylor OKE Cluster - GitOps Bootstrap"
echo "=============================================="

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to wait for condition with progress
wait_for_condition() {
    local description="$1"
    local command="$2"
    local timeout="${3:-300}"
    
    echo -n "Waiting for $description"
    local count=0
    while ! eval "$command" >/dev/null 2>&1; do
        if [ $count -ge $timeout ]; then
            echo " [ERROR] Timeout!"
            return 1
        fi
        sleep 5
        count=$((count + 5))
        echo -n "."
    done
    echo " [OK]"
}

# ============================================
# PREREQUISITES CHECK
# ============================================
echo ""
echo "[CHECK] Checking prerequisites..."

if ! command_exists kubectl; then
    echo "[ERROR] kubectl is not installed"
    exit 1
fi
echo "[OK] kubectl"

if ! command_exists git; then
    echo "[ERROR] git is not installed"
    exit 1
fi
echo "[OK] git"

if ! command_exists flux; then
    echo "[INSTALL] Installing Flux CLI..."
    curl -s https://fluxcd.io/install.sh | sudo bash
    if ! command_exists flux; then
        echo "[ERROR] Failed to install Flux CLI"
        exit 1
    fi
fi
echo "[OK] flux"

# Check cluster connectivity
echo ""
echo "[CONNECT] Checking cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to Kubernetes cluster"
    echo "   Run: kubectl config use-context <your-context>"
    exit 1
fi
CLUSTER_NAME=$(kubectl config current-context)
echo "[OK] Connected to: $CLUSTER_NAME"

# ============================================
# FLUX BOOTSTRAP
# ============================================
echo ""
echo "[DEPLOY] Checking Flux installation..."

if kubectl get namespace flux-system >/dev/null 2>&1 && \
   kubectl get deployment source-controller -n flux-system >/dev/null 2>&1; then
    echo "[OK] Flux is already installed"
    FLUX_INSTALLED=true
else
    echo "[INSTALL] Flux not detected, bootstrapping..."
    FLUX_INSTALLED=false
    
    # Check for GitHub token
    if [ -z "$GITHUB_TOKEN" ]; then
        echo ""
        echo "[ERROR] GITHUB_TOKEN environment variable required"
        echo "   Create a GitHub personal access token with repo permissions:"
        echo "   https://github.com/settings/tokens"
        echo ""
        echo "   Then run:"
        echo "   export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx"
        echo "   ./bootstrap-oke.sh"
        exit 1
    fi
    
    echo ""
    echo "[CONFIG] Bootstrapping Flux GitOps..."
    flux bootstrap github \
        --owner=dylanmtaylor \
        --repository=dylanmtaylor-kubernetes \
        --branch=main \
        --path=clusters/production \
        --personal \
        --token-auth
    
    echo "[OK] Flux bootstrap complete"
    
    # Wait for Flux controllers
    wait_for_condition "Flux source-controller" \
        "kubectl get deployment source-controller -n flux-system"
    wait_for_condition "Flux kustomize-controller" \
        "kubectl get deployment kustomize-controller -n flux-system"
    wait_for_condition "Flux helm-controller" \
        "kubectl get deployment helm-controller -n flux-system"
fi

# ============================================
# OCI CREDENTIALS SECRET
# ============================================
echo ""
echo "[AUTH] Configuring OCI credentials..."

OCI_KEY_FILE="/var/home/dylan/.oci/oci_api_key.pem"
OCI_SECRET_TEMPLATE="manifests/apps/resume-builder/secret.yaml"

if [ -f "$OCI_KEY_FILE" ] && [ -f "$OCI_SECRET_TEMPLATE" ]; then
    echo "[PROCESS] Processing OCI API key..."
    
    # Create temporary file with actual private key
    TEMP_SECRET=$(mktemp)
    
    awk '
    /oci_api_key\.pem: \|/ {
        print $0
        # Skip placeholder lines
        getline; getline; getline
        # Insert actual private key
        while ((getline line < "'"$OCI_KEY_FILE"'") > 0) {
            print "    " line
        }
        close("'"$OCI_KEY_FILE"'")
        next
    }
    { print }
    ' "$OCI_SECRET_TEMPLATE" > "$TEMP_SECRET"
    
    # Apply secret
    kubectl apply -f "$TEMP_SECRET"
    rm -f "$TEMP_SECRET"
    
    echo "[OK] OCI credentials configured"
else
    echo "[WARN]  OCI API key not found"
    echo "   Resume builder will not work without OCI credentials"
    echo "   Place your key at: $OCI_KEY_FILE"
fi

# ============================================
# WAIT FOR INFRASTRUCTURE
# ============================================
echo ""
echo "[WAIT] Waiting for infrastructure deployment..."

wait_for_condition "cert-manager" \
    "kubectl get deployment cert-manager -n cert-manager" 600

wait_for_condition "ingress-nginx controller" \
    "kubectl get deployment ingress-nginx-controller -n ingress-nginx" 600

# ============================================
# WAIT FOR APPLICATIONS
# ============================================
echo ""
echo "[WAIT] Waiting for applications deployment..."

wait_for_condition "applications kustomization" \
    "flux get kustomization applications --no-header 2>/dev/null | grep -q 'True'" 300

# ============================================
# DEPLOYMENT COMPLETE
# ============================================
echo ""
echo "==========================================="
echo "[COMPLETE] GitOps Deployment Complete!"
echo "==========================================="
echo ""
echo "[STATUS] Cluster Status:"
flux get all --all-namespaces
echo ""
echo "[NETWORK] Applications:"
kubectl get deployments,cronjobs -n dylanmtaylor
echo ""
echo "[CONNECT] Ingress:"
kubectl get ingress -n dylanmtaylor
echo ""
echo "==========================================="
echo "[INFO] Useful Commands:"
echo "==========================================="
echo "  flux get all                        # Flux status"
echo "  kubectl get all -n dylanmtaylor    # Application status"
echo "  flux logs --level=error            # Error logs"
echo "  flux reconcile kustomization apps  # Force sync"
echo ""
echo "[SYNC] GitOps Workflow:"
echo "  1. Edit files in manifests/apps/"
echo "  2. git add . && git commit -m 'update'"
echo "  3. git push origin main"
echo "  4. Flux auto-deploys within 1 minute"
echo ""
echo "[DOCS] Documentation:"
echo "  cat README.md                      # Full documentation"
echo "==========================================="
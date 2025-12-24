#!/bin/bash
set -e

echo "======================================"
echo "Deploying Dylan Taylor Kubernetes Apps"
echo "======================================"

# Setup oke-admin service account
kubectl apply -f k8s/base/oke-admin-service-account.yaml

# yq is a pre-requisite
if ! command -v yq &>/dev/null; then
  ARCH=$(case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; esac)
  if [ -n "$ARCH" ]; then
    mkdir -p ./bin
    wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH -O bin/yq
    chmod +x ./bin/yq
    export PATH="$(pwd)/bin:$PATH"
  fi
fi

# Install Gateway API CRDs first (needed by cert-manager)
echo ""
echo "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# Check if cert-manager is already installed
echo ""
if kubectl get namespace cert-manager &>/dev/null && kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
    echo "cert-manager is already installed, checking Gateway API support..."
    if ! kubectl get deployment cert-manager -n cert-manager -o yaml | grep -q "enable-gateway-api"; then
        echo "Enabling Gateway API support in cert-manager..."
        kubectl patch deployment cert-manager -n cert-manager --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--enable-gateway-api"}]'
        kubectl rollout status deployment cert-manager -n cert-manager --timeout=300s
    fi
else
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml

    # Wait for cert-manager to be ready
    echo "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    
    # Enable Gateway API support
    echo "Enabling Gateway API support..."
    kubectl patch deployment cert-manager -n cert-manager --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--enable-gateway-api"}]'
    kubectl rollout status deployment cert-manager -n cert-manager --timeout=300s
fi

# Install OCI Native Ingress Controller
echo ""
echo "Checking if OCI Native Ingress Controller is already installed..."
if kubectl get deployment release-name-oci-native-ingress-controller -n native-ingress-controller-system 2>/dev/null | grep -q release-name-oci-native-ingress-controller; then
    echo "OCI Native Ingress Controller is already installed, skipping installation..."
else
    echo "Installing OCI Native Ingress Controller..."
    kubectl apply -f k8s/base/oci-native-ingress-controller.yaml
    # Wait for OCI Native Ingress Controller to be ready
    echo "Waiting for OCI Native Ingress Controller to be ready..."
    kubectl wait --for=condition=Available --timeout=300s deployment/release-name-oci-native-ingress-controller -n native-ingress-controller-system
fi

# Install Envoy Gateway
echo ""
echo "Installing Envoy Gateway..."
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.6.1 -n envoy-gateway-system --create-namespace

# Wait for Envoy Gateway to be ready
echo "Waiting for Envoy Gateway to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/envoy-gateway -n envoy-gateway-system

# Apply base resources
echo ""
echo "Applying base resources..."
kubectl apply -k k8s/base/

echo ""
echo "Deploying monitoring stack (Prometheus)..."
kubectl kustomize k8s/monitoring/ --enable-helm | kubectl apply --server-side=true -f -

echo ""
echo "Deploying apps..."
kubectl apply -k k8s/apps/

# Get NLB IP address from DNS and update EnvoyProxy configuration
echo ""
echo "Setting static IP for load balancer..."
NLB_IP=$(dig +short nlb.dylanmtaylor.com | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
if [ -z "$NLB_IP" ]; then
    echo "Error: Could not resolve nlb.dylanmtaylor.com to an IP address."
    exit 1
fi

# Update EnvoyProxy with dynamic IP
kubectl patch envoyproxy oci-loadbalancer -n dylanmtaylor --type='merge' -p="{\"spec\":{\"provider\":{\"kubernetes\":{\"envoyService\":{\"loadBalancerIP\":\"$NLB_IP\"}}}}}"

# Apply OCI credentials secret for resume-builder
echo ""
echo "Applying OCI credentials secret..."
if [ -f "/var/home/dylan/.oci/sessions/DEFAULT/oci_api_key.pem" ] && [ -f "k8s/apps/resume-builder/secret.yaml" ]; then
    # Create a temporary file with the private key substituted
    TEMP_SECRET=$(mktemp)
    
    # Read the secret file and replace the placeholder section
    awk '
    /oci_api_key\.pem: \|/ {
        print $0
        # Skip the placeholder lines
        getline; getline; getline
        # Insert the actual private key
        while ((getline line < "/var/home/dylan/.oci/sessions/DEFAULT/oci_api_key.pem") > 0) {
            print "    " line
        }
        close("/var/home/dylan/.oci/sessions/DEFAULT/oci_api_key.pem")
        next
    }
    { print }
    ' k8s/apps/resume-builder/secret.yaml > "$TEMP_SECRET"
    
    # Apply the secret and clean up
    kubectl apply -f "$TEMP_SECRET"
    rm -f "$TEMP_SECRET"
else
    echo "Warning: OCI API key or secret template not found, skipping OCI credentials secret..."
fi

# Apply all apps using kustomize
echo ""
echo "Deploying all services..."
kubectl apply -k k8s/apps/

echo ""
echo "Deployment complete!"
echo ""
echo "Check status with:"
echo "  kubectl get all -n dylanmtaylor"
echo "  kubectl get ingress -n dylanmtaylor"

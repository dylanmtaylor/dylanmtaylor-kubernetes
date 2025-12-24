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

# Check if cert-manager is already installed
echo ""
if kubectl get namespace cert-manager &>/dev/null && kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
    echo "cert-manager is already installed, skipping installation..."
else
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml

    # Wait for cert-manager to be ready
    echo "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
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

# Install Gateway API CRDs
echo ""
echo "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# Install Istio with ambient mode
echo ""
echo "Installing Istio..."
if ! command -v istioctl &>/dev/null; then
  echo "Downloading istioctl..."
  ISTIO_VERSION=1.28.2
  curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
  export PATH="$PWD/istio-$ISTIO_VERSION/bin:$PATH"
fi

if kubectl get namespace istio-system &>/dev/null; then
    echo "Istio is already installed, skipping installation..."
else
    istioctl install --set profile=ambient -y
fi

# Wait for Istio to be ready
echo "Waiting for Istio to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/istiod -n istio-system

# Apply base resources
echo ""
echo "Applying base resources..."
kubectl apply -k k8s/base/

echo ""
echo "Deploying apps..."
kubectl apply -k k8s/apps/

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
echo "  kubectl get gateway -n dylanmtaylor"

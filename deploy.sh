#!/bin/bash
set -e

echo "======================================"
echo "Deploying Dylan Taylor Kubernetes Apps"
echo "======================================"

# Detect if we're running on OKE
IS_OKE=false
if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "ocid1.instance"; then
    IS_OKE=true
    echo "Detected Oracle Kubernetes Engine (OKE) cluster"
else
    echo "Detected non-OKE cluster"
fi

# Setup OKE-specific service account
if [ "$IS_OKE" = true ]; then
    kubectl apply -f k8s/base/oke-admin-service-account.yaml
fi

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



# Install Envoy Gateway
echo ""
if helm list -n envoy-gateway-system | grep -q "^eg\s"; then
    echo "Envoy Gateway is already installed, upgrading..."
    helm upgrade eg oci://docker.io/envoyproxy/gateway-helm --version v1.6.1 -n envoy-gateway-system
else
    echo "Installing Envoy Gateway..."
    helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.6.1 -n envoy-gateway-system --create-namespace
fi

# Wait for Envoy Gateway to be ready
echo "Waiting for Envoy Gateway to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/envoy-gateway -n envoy-gateway-system

# Install external-secrets operator
echo ""
if helm list -n external-secrets-system | grep -q "^external-secrets\s"; then
    echo "external-secrets is already installed, upgrading..."
    helm upgrade external-secrets external-secrets/external-secrets -n external-secrets-system
else
    echo "Installing external-secrets operator..."
    helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1
    helm repo update >/dev/null 2>&1
    helm install external-secrets external-secrets/external-secrets -n external-secrets-system --create-namespace
fi

# Wait for external-secrets to be ready
echo "Waiting for external-secrets to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/external-secrets -n external-secrets-system

# Install metrics-server
echo ""
echo "Installing metrics-server in HA mode..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    echo "metrics-server is already installed, upgrading..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/high-availability-1.21+.yaml
else
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/high-availability-1.21+.yaml
fi
# Wait for metrics-server to be ready
echo "Waiting for metrics-server to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/metrics-server -n kube-system

# Apply base resources
echo ""
echo "Applying base resources..."
kubectl apply -k k8s/base/

echo ""
echo "Deploying monitoring stack (Prometheus)..."
# Add prometheus-community helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo update >/dev/null 2>&1

# Install kube-prometheus-stack with Helm
if ! helm list -n monitoring | grep -q kube-prometheus-stack; then
    echo "Installing kube-prometheus-stack..."
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --version 80.6.0 \
        --namespace monitoring \
        --create-namespace \
        --wait \
        --timeout 600s
else
    echo "kube-prometheus-stack already installed, upgrading..."
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --version 80.6.0 \
        --namespace monitoring \
        --wait \
        --timeout 600s
fi

echo ""
echo "Deploying apps..."
kubectl apply -k k8s/apps/

# OKE-specific: Set static IP for load balancer
if [ "$IS_OKE" = true ]; then
    echo ""
    echo "Setting static IP for load balancer..."
    NLB_IP=$(dig +short nlb.dylanmtaylor.com | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
    if [ -z "$NLB_IP" ]; then
        echo "Error: Could not resolve nlb.dylanmtaylor.com to an IP address."
        exit 1
    fi

    # Update EnvoyProxy with dynamic IP (only if it exists)
    if kubectl get envoyproxy oci-loadbalancer -n dylanmtaylor &>/dev/null; then
        CURRENT_IP=$(kubectl get envoyproxy oci-loadbalancer -n dylanmtaylor -o jsonpath='{.spec.provider.kubernetes.envoyService.loadBalancerIP}' 2>/dev/null || echo "")
        if [ "$CURRENT_IP" != "$NLB_IP" ]; then
            echo "Updating EnvoyProxy loadBalancerIP from '$CURRENT_IP' to '$NLB_IP'..."
            kubectl patch envoyproxy oci-loadbalancer -n dylanmtaylor --type='merge' -p="{\"spec\":{\"provider\":{\"kubernetes\":{\"envoyService\":{\"loadBalancerIP\":\"$NLB_IP\"}}}}}"
        else
            echo "EnvoyProxy loadBalancerIP is already set to $NLB_IP, skipping..."
        fi
    else
        echo "EnvoyProxy oci-loadbalancer not found, will be created by app deployment..."
    fi
fi

echo ""
echo "Deployment complete!"
echo ""
echo "Check status with:"
echo "  kubectl get all -n dylanmtaylor"
echo "  kubectl get ingress -n dylanmtaylor"

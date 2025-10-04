#!/bin/bash
set -e

echo "======================================"
echo "Deploying Dylan Taylor Kubernetes Apps"
echo "======================================"

# Check if cert-manager is already installed
echo ""
if kubectl get namespace cert-manager &>/dev/null && kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
    echo "cert-manager is already installed, skipping installation..."
else
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

    # Wait for cert-manager to be ready
    echo "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
fi

# Check if nginx ingress controller is already installed
echo ""
if kubectl get namespace ingress-nginx &>/dev/null && kubectl get deployment ingress-nginx-controller -n ingress-nginx &>/dev/null; then
    echo "nginx ingress controller is already installed, skipping installation..."
else
    echo "Installing nginx ingress controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml

    # Wait for nginx ingress controller to be ready
    echo "Waiting for nginx ingress controller to be ready..."
    kubectl wait --for=condition=Available --timeout=300s deployment/ingress-nginx-controller -n ingress-nginx
fi

# Configure nginx ingress to use OCI NLB with static IP
echo ""
echo "Configuring nginx ingress to use OCI Network Load Balancer with static IP..."
NLB_IP=$(dig +short nlb.dylanmtaylor.com | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
if [ -z "$NLB_IP" ]; then
    echo "Error: Could not resolve nlb.dylanmtaylor.com to an IP address."
    exit 1
fi
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p "{\"metadata\":{\"annotations\":{\"oci.oraclecloud.com/load-balancer-type\":\"nlb\"}},\"spec\":{\"loadBalancerIP\":\"$NLB_IP\"}}"

# Apply base resources using kustomize
echo ""
echo "Applying base resources..."
kubectl apply -k k8s/base/

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

# Apply OCI credentials secret for resume-builder
echo ""
echo "Applying OCI credentials secret..."
if [ -f "/var/home/dylan/.oci/oci_api_key.pem" ] && [ -f "k8s/apps/resume-builder/secret.yaml" ]; then
    # Read the private key and escape it for sed
    PRIVATE_KEY=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' /var/home/dylan/.oci/oci_api_key.pem)
    # Replace the placeholder with actual key content and apply
    sed "s|    -----BEGIN RSA PRIVATE KEY-----\n    <YOUR_PRIVATE_KEY_CONTENT_HERE>\n    -----END RSA PRIVATE KEY-----|${PRIVATE_KEY}|" k8s/apps/resume-builder/secret.yaml | kubectl apply -f -
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

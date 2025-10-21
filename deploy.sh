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

    # Download, patch, and apply the manifest for the nginx ingress controller
    # We do this all in memory to avoid creating an ALB by default before it is patched, which is not desired.
    curl -sSL https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml | \
    kubectl apply -f -

    # Wait for nginx ingress controller to be ready
    echo "Waiting for nginx ingress controller to be ready..."
    kubectl wait --for=condition=Available --timeout=300s deployment/ingress-nginx-controller -n ingress-nginx

    # Scale nginx ingress controller to 4 replicas for high availability
    echo "Scaling nginx ingress controller to 4 replicas..."
    kubectl scale deployment ingress-nginx-controller -n ingress-nginx --replicas=2
fi

# Apply base resources using kustomize
echo ""
echo "Applying base resources..."
kubectl apply -k k8s/base/

echo ""
echo "Deploying monitoring stack (Prometheus)..."
kubectl kustomize k8s/monitoring/ --enable-helm | kubectl apply --server-side=true -f -

# Apply OCI credentials secret for resume-builder
echo ""
echo "Applying OCI credentials secret..."
if [ -f "/var/home/dylan/.oci/oci_api_key.pem" ] && [ -f "k8s/apps/resume-builder/secret.yaml" ]; then
    # Create a temporary file with the private key substituted
    TEMP_SECRET=$(mktemp)
    
    # Read the secret file and replace the placeholder section
    awk '
    /oci_api_key\.pem: \|/ {
        print $0
        # Skip the placeholder lines
        getline; getline; getline
        # Insert the actual private key
        while ((getline line < "/var/home/dylan/.oci/oci_api_key.pem") > 0) {
            print "    " line
        }
        close("/var/home/dylan/.oci/oci_api_key.pem")
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

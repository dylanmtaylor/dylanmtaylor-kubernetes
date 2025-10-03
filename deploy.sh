#!/bin/bash
set -e

echo "======================================"
echo "Deploying Dylan Taylor Kubernetes Apps"
echo "======================================"

# Install cert-manager (required by OCI Native Ingress Controller)
echo ""
echo "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

# Wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager-cainjector -n cert-manager

# Install nginx ingress controller
echo ""
echo "Installing nginx ingress controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml

# Wait for nginx ingress controller to be ready
echo "Waiting for nginx ingress controller to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/ingress-nginx-controller -n ingress-nginx

# Configure nginx ingress to use OCI NLB with static IP
echo ""
echo "Configuring nginx ingress to use OCI Network Load Balancer with static IP..."
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"metadata":{"annotations":{"oci.oraclecloud.com/load-balancer-type":"nlb"}},"spec":{"loadBalancerIP":"129.80.142.204"}}'

# Apply base resources using kustomize
echo ""
echo "Applying base resources..."
kubectl apply -k k8s/base/

# Install OCI Native Ingress Controller
echo ""
echo "Installing OCI Native Ingress Controller..."
kubectl apply -f k8s/base/oci-native-ingress-controller.yaml

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

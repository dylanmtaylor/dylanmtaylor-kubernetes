# Dylan's Kubernetes Infrastructure

This repository contains all manifests and GitOps automation for running my websites and services on Oracle Kubernetes Engine (OKE).

## Overview

This cluster powers dylanmtaylor.com and all its subdomains using Flux GitOps for fully automated, declarative deployments.

## Architecture

### Infrastructure
- **Cluster**: Oracle Kubernetes Engine (OKE) on 4x ARM64 Ampere A1 instances (1 CPU, 4 GiB RAM each - "always free" tier)
- **GitOps**: Flux CD for declarative, Git-driven deployments
- **Ingress**: NGINX Ingress Controller with OCI Network Load Balancer (static IP)
- **SSL**: cert-manager for automatic Let's Encrypt certificates
- **Networking**: Flannel CNI for pod networking
- **Storage**: OCI Object Storage for persistent data
- **IaC**: Deployed via Terraform (see [terraform-dylanmtaylor-com](https://gitlab.com/dylanmtaylor/terraform-dylanmtaylor-com))

### Services Running

**Web Applications:**
- **www.dylanmtaylor.com** - Main portfolio site
- **blog.dylanmtaylor.com** - Personal blog
- **apps.dylanmtaylor.com** - Web applications
- **files.dylanmtaylor.com** - File hosting
- **git.dylanmtaylor.com** - Git interface
- **fwc.dylanmtaylor.com** - Fitness challenge tracker

**Automated Tasks:**
- Resume builder CronJob (runs every 15 minutes):
  - Clones repository from GitLab
  - Compiles LaTeX to PDF using XeLaTeX
  - Uploads to OCI Object Storage
  - Accessible at files.dylanmtaylor.com/resume.pdf

## Repository Structure

```
dylanmtaylor-kubernetes/
├── bootstrap-oke.sh              # Cluster bootstrap script
├── clusters/production/
│   ├── apps.yaml                 # Application deployments
│   └── infrastructure.yaml       # Infrastructure orchestration
├── infrastructure/
│   ├── cert-manager.yaml         # SSL certificate management
│   ├── oci-native-ingress.yaml   # OCI native ingress controller
│   ├── ingress-nginx.yaml        # NGINX ingress controller
│   ├── monitoring.yaml           # Prometheus + Grafana (optional)
│   ├── namespaces.yaml           # Infrastructure namespaces
│   └── kustomization.yaml        # Infrastructure index
└── manifests/apps/
    ├── namespace.yaml            # Application namespace
    ├── ingress.yaml              # Ingress routing rules
    ├── kustomization.yaml        # Application index
    ├── www-dylanmtaylor-com/     # Main site manifests
    ├── blog-dylanmtaylor-com/    # Blog manifests
    ├── apps-dylanmtaylor-com/    # Apps manifests
    ├── files-dylanmtaylor-com/   # Files manifests
    ├── git-dylanmtaylor-com/     # Git interface manifests
    ├── fwc-dylanmtaylor-com/     # Fitness tracker manifests
    └── resume-builder/           # Resume builder CronJob
```

## Getting Started

### Prerequisites

- kubectl configured for your OKE cluster
- git
- GitHub personal access token with repo permissions

### Initial Cluster Setup

```bash
# Set your GitHub token
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx

# Bootstrap the cluster (one-time operation)
./bootstrap-oke.sh
```

The bootstrap script will:
1. Install Flux CLI if not present
2. Bootstrap Flux GitOps to the cluster
3. Configure OCI credentials for resume builder
4. Deploy infrastructure (cert-manager, ingress-nginx)
5. Configure OCI Network Load Balancer with static IP
6. Deploy all applications
7. Validate deployment

### Daily Workflow

Once bootstrapped, all deployments happen automatically via Git:

```bash
# Make changes to any manifest
vim manifests/apps/www-dylanmtaylor-com/deployment.yaml

# Commit and push
git add .
git commit -m "feat: update main site"
git push origin main

# Flux automatically detects changes and deploys within 1 minute
```

### Monitoring

```bash
# Check Flux GitOps status
flux get all

# Check application status
kubectl get all -n dylanmtaylor

# View Flux error logs
flux logs --level=error

# Force immediate reconciliation
flux reconcile kustomization applications --with-source
```

## How It Works

### GitOps Workflow

Flux monitors this Git repository and automatically applies changes:

```
Git Push → Flux Detects Change → Validates Manifests → Deploys to Cluster → Health Checks
```

### Infrastructure as Code

- **Infrastructure Layer**: Helm releases manage cert-manager, ingress-nginx, and optional monitoring
- **Application Layer**: Kustomize manages all application manifests
- **Single Source of Truth**: Git is the authoritative source for all cluster state

### Production Features

- **High Availability**: Critical services (www, apps) run with 2 replicas
- **Resource Management**: ARM64-optimized CPU and memory limits for all services
- **Health Checks**: Flux validates deployments before marking them as ready
- **Automatic Rollbacks**: Git reverts trigger automatic rollbacks
- **SSL Automation**: cert-manager handles Let's Encrypt certificate lifecycle
- **Load Balancing**: OCI Network Load Balancer with static IP allocation

## Configuration

### Resource Allocation

Resource limits are configured in `clusters/production/apps.yaml`:

- **www & apps**: 2 replicas, 512Mi-1Gi memory, 500m-1000m CPU
- **Static sites**: 1 replica, 256Mi memory, 250m CPU
- **Resume builder**: CronJob, 1Gi memory, 1000m CPU

### Customization

To adjust deployment settings, edit `clusters/production/apps.yaml`:
- Replica counts
- Resource limits and requests
- Health check intervals
- Reconciliation frequency

### Choosing Ingress Controller

This cluster has both ingress controllers available:

**OCI Native Ingress Controller** (recommended):
- Native integration with OCI Load Balancers
- Automatic provisioning of OCI resources
- Better performance for OCI environments
- Use `ingressClassName: oci` in ingress resources

**NGINX Ingress Controller**:
- Traditional ingress option
- More features and customization
- Community-standard solution
- Use `ingressClassName: nginx` in ingress resources

To switch between controllers, update the `ingressClassName` field in `manifests/apps/ingress.yaml`. Both controllers can run simultaneously, allowing you to route different services through different ingress controllers.

## Troubleshooting

### Check Deployment Status

```bash
# View all Flux resources
flux get kustomizations

# Check specific application
flux get kustomization applications

# View reconciliation errors
flux logs --kind=Kustomization --name=applications
```

### Infrastructure Issues

```bash
# Check cert-manager status
kubectl get certificates -n dylanmtaylor
kubectl describe certificate dylanmtaylor-tls -n dylanmtaylor

# Check NGINX ingress status
kubectl describe ingress dylanmtaylor-ingress -n dylanmtaylor
kubectl get svc -n ingress-nginx
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Check OCI Native Ingress Controller status
kubectl get pods -n native-ingress-controller-system
kubectl logs -n native-ingress-controller-system deployment/oci-native-ingress-controller
kubectl get ingressclass
```

### Application Issues

```bash
# Check application pods
kubectl get pods -n dylanmtaylor

# View application logs
kubectl logs -n dylanmtaylor deployment/www-dylanmtaylor-com

# Check CronJob status
kubectl get cronjobs -n dylanmtaylor
kubectl get jobs -n dylanmtaylor
```

### Force Resynchronization

```bash
# Reconcile from Git immediately
flux reconcile kustomization applications --with-source

# Suspend and resume to force full refresh
flux suspend kustomization applications
flux resume kustomization applications
```

## Why GitOps?

This repository demonstrates production-grade GitOps practices for personal infrastructure:

**Declarative**: All cluster state is defined in Git, making it easy to understand and review changes.

**Automated**: Changes deploy automatically without manual intervention, reducing human error.

**Auditable**: Complete history of what changed, when, and by whom is preserved in Git.

**Recoverable**: Disaster recovery is as simple as running `flux bootstrap` against a new cluster.

**Scalable**: Adding new services or environments is straightforward and repeatable.

**Reliable**: Built-in health checks and automatic rollbacks ensure stability.

Running on Oracle Cloud's "always free" tier proves that enterprise-grade infrastructure practices work at any scale, from hobby projects to production workloads.

## License

This repository is provided as-is for reference and educational purposes.

---

Built by Dylan Taylor

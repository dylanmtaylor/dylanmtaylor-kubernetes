# Dylan's Kubernetes Infrastructure

This repository contains all the manifests and automation I use to run my websites and services on Oracle Kubernetes Engine (OKE). 

## What's Running Here?

This cluster powers the entirety of dylanmtaylor.com, all orchestrated with the power of Kubernetes:

## Architecture
- **Cluster**: Oracle Kubernetes Engine (OKE) running on 4x 1 CPU, 4 GiB RAM ARM64 Ampere "always free" instances 
- **Ingress**: Envoy Gateway using an OCI native Network Load Balancer (static IP allocation)
- **Networking**: Pod networking is handled with flannel
- **Storage**: OCI Object Storage for persistent data (files served from files.dylanmtaylor.com)
- **Automation**: Everything deployed with a single script, and Kustomize is used for configuration management
- **Infrastructure**: Deployed via Terraform, see https://gitlab.com/dylanmtaylor/terraform-dylanmtaylor-com

### Web Services
Running on pods using Nginx OCI images fronted by Envoy Gateway, with automation to pull static site contents from GitLab and serve it.

### Resume Generation Pipeline
A CronJob that:
- Clones my resume repo from GitLab
- Compiles the raw LaTeX files to a PDF
- Uploads that to OCI Object Storage using credentials stored in a Kubernetes secret
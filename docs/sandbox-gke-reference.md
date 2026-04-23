# `sandbox-gke` — OpenTofu Reference Guide

**v1.1** — April 2026

> An educational reference guide to building a push-button GKE cluster with OpenTofu,
> structured around the official OpenTofu documentation.

---

## Table of Contents

1. [What We're Building](#what-were-building)
2. [Directory Structure](#directory-structure)
3. [Implementation Steps](#implementation-steps)
4. [Reference: Layer by Layer](#reference-layer-by-layer)
   - [Layer 0: Manual Bootstrap](#layer-0-manual-bootstrap-the-irreducible-exception)
   - [Layer 1: GCP Project Configuration](#layer-1-gcp-project-configuration)
   - [Layer 2: Networking](#layer-2-networking)
   - [Layer 3: GKE Cluster + Node Pool](#layer-3-gke-cluster-and-node-pool)
   - [Layer 4: Workload Identity](#layer-4-workload-identity)
   - [Layer 5: ArgoCD Bootstrap](#layer-5-argocd-bootstrap)
5. [Backend Configuration](#backend-configuration)
6. [Variables and Outputs](#variables-and-outputs)
7. [Module Variables Reference](#module-variables-reference)
8. [IAM Audit](#iam-audit)
9. [Cost and Spend Management](#cost-and-spend-management)
10. [Interacting with the Cluster](#interacting-with-the-cluster)
11. [OpenTofu Core Concepts](#opentofu-core-concepts)
12. [Learning Objectives](#learning-objectives)
13. [Provider and Registry References](#provider-and-registry-references)
14. [Appendix: Pulumi/Python Alternative](#appendix-pulumipython-alternative)
15. [Changelog](#changelog)
16. [Troubleshooting](./troubleshooting.md)

---

## What We're Building

A **repeatable, push-button GKE cluster** on GCP, managed end-to-end by OpenTofu wherever
possible. The cluster bootstraps itself into a GitOps-ready state — ArgoCD installed via
Helm, pointed at this repo's `gitops/` directory — without any manual `kubectl` intervention
after `tofu apply`.

| Property | Value |
|---|---|
| GCP project | `terraform-sandbox` (recycled — IAM audit required) |
| Region | `us-east1` |
| Zone | `us-east1-b` (zonal cluster — cheaper than regional) |
| State bucket | `gs://sandbox-gke-tofu-state` |
| HCL location | `provisioning/opentofu/` (in this repo — not yet created) |
| GitOps config | `gitops/` (in this repo — already exists) |

---

## Directory Structure

This is the full file tree you are building. Everything under `provisioning/opentofu/` is new.
The `gitops/` directory already exists and is what ArgoCD will sync after the cluster is up.

```
sandbox-gke/
├── provisioning/
│   └── opentofu/                  ← run all tofu commands from here
│       ├── backend.tf             # GCS remote state backend + required_providers
│       ├── providers.tf           # ALL provider blocks live here (root module only)
│       ├── variables.tf           # root module input variables
│       ├── outputs.tf             # root module outputs
│       ├── main.tf                # API enablement + the three module calls
│       ├── terraform.tfvars       # your values — gitignore this file
│       └── modules/
│           ├── vpc/
│           │   ├── main.tf        # google_compute_network + google_compute_subnetwork
│           │   ├── variables.tf
│           │   └── outputs.tf     # exports: network_id, subnetwork_id
│           ├── gke/
│           │   ├── main.tf        # cluster, node pool, node SA + IAM, workload identity
│           │   ├── variables.tf
│           │   └── outputs.tf     # exports: endpoint, ca_certificate, node_sa_email
│           └── bootstrap/
│               ├── main.tf        # helm_release argocd + kubernetes_manifest root Application
│               ├── variables.tf
│               └── outputs.tf
└── gitops/                        ← ArgoCD manages everything in here after apply
    ├── bootstrap/
    │   └── root-app.yaml          # reference copy of what OpenTofu deploys into the cluster
    ├── cluster/                   # root app points here — three ApplicationSets
    │   ├── kustomization.yaml
    │   ├── infra-set.yaml         # sync-wave 0: cert-manager
    │   ├── platform-set.yaml      # sync-wave 1: prometheus, loki, tempo, alloy
    │   └── apps-set.yaml          # sync-wave 2: otel-demo
    ├── infra/
    ├── platform/
    └── apps/
```

> **Why three modules?** VPC, GKE, and Bootstrap map to three distinct concerns that
> provision and destroy independently. Separating them also lets OpenTofu plan and sequence
> them in the correct order.

> **Why is `providers.tf` root-only?** The `kubernetes` and `helm` providers need the GKE
> cluster's endpoint and CA certificate — values that don't exist until after the cluster is
> provisioned. OpenTofu requires all provider blocks to live in the root module so it can
> manage this dependency. See [Layer 5](#layer-5-argocd-bootstrap) for the
> full explanation.

---

## Implementation Steps

Work through these in order. Each step links to the detailed reference section below.

---

### Pre-flight

- [ ] **Run the [IAM audit](#iam-audit)** before writing any HCL. Confirm your identity has
  the minimum required roles on `terraform-sandbox`.
- [ ] **Set billing alerts.** GCP Console → Billing → Budgets & Alerts. Set at $50 and $100.
  The cluster costs ~$0.12/hr; a forgotten long weekend = ~$7.

---

### Step 0 — Manual Bootstrap (one-time)

These two things cannot be managed by OpenTofu because they are prerequisites for OpenTofu
to operate at all. Do them once, then never touch them again.

- [ ] **Create the GCS state bucket** — see [Layer 0](#layer-0-manual-bootstrap-the-irreducible-exception)
- [ ] **Configure Application Default Credentials:**

```bash
gcloud auth application-default login
```

---

### Step 1 — Create the File Scaffold

Create the directory tree and empty stub files before writing any HCL. OpenTofu expects the
files to exist when you run `tofu init`.

```bash
# Run from the repo root
mkdir -p provisioning/opentofu/modules/vpc
mkdir -p provisioning/opentofu/modules/gke
mkdir -p provisioning/opentofu/modules/bootstrap

touch provisioning/opentofu/{backend.tf,providers.tf,variables.tf,outputs.tf,main.tf}
touch provisioning/opentofu/modules/vpc/{main.tf,variables.tf,outputs.tf}
touch provisioning/opentofu/modules/gke/{main.tf,variables.tf,outputs.tf}
touch provisioning/opentofu/modules/bootstrap/{main.tf,variables.tf,outputs.tf}

# terraform.tfvars will contain your GCP project ID — never commit it
echo "provisioning/opentofu/terraform.tfvars" >> .gitignore
```

---

### Step 2 — Backend and Providers

Write these two files first — they are the foundation everything else depends on.

- [ ] Write `backend.tf` → see [Backend Configuration](#backend-configuration)
- [ ] Write `providers.tf` → see [The Provider Chaining Problem](#the-provider-chaining-problem)

Read the Provider Chaining section carefully before writing `providers.tf`. The way the
`kubernetes` and `helm` providers reference `module.gke.*` outputs is the most non-obvious
part of this entire project.

---

### Step 3 — Variables

- [ ] Write `variables.tf` → see [Variables and Outputs](#variables-and-outputs)
- [ ] Write `terraform.tfvars` with your actual values (this file is gitignored):

```hcl
# provisioning/opentofu/terraform.tfvars  ← DO NOT COMMIT
project_id      = "terraform-sandbox"
gitops_repo_url = "https://github.com/<your-username>/sandbox-gke"
```

---

### Step 4 — VPC Module

- [ ] Write `modules/vpc/variables.tf` → see [Layer 2](#layer-2-networking) for the complete file
- [ ] Write `modules/vpc/main.tf` → see [Layer 2](#layer-2-networking)
- [ ] Write `modules/vpc/outputs.tf` — must export `network_id` and `subnetwork_id`

---

### Step 5 — GKE Module

This module contains three conceptual layers (service account, cluster + node pool, workload
identity) but they all live in one `main.tf` because they're all tightly coupled GKE
resources.

- [ ] Write `modules/gke/variables.tf` → see [Layer 3](#layer-3-gke-cluster-and-node-pool) for the complete file
- [ ] Write `modules/gke/main.tf`:
  - Node SA + IAM bindings → [Layer 1b](#1b-service-account-for-the-gke-node-pool)
  - Cluster + node pool → [Layer 3](#layer-3-gke-cluster-and-node-pool)
  - Workload Identity → [Layer 4](#layer-4-workload-identity)
- [ ] Write `modules/gke/outputs.tf` — must export `endpoint`, `ca_certificate`, and
  `node_sa_email`; mark the first two `sensitive = true`

---

### Step 6 — Bootstrap Module

- [ ] Write `modules/bootstrap/variables.tf` → see [Layer 5](#layer-5-argocd-bootstrap) for the complete file
- [ ] Write `modules/bootstrap/main.tf` → see [Layer 5](#layer-5-argocd-bootstrap)
- [ ] Write `modules/bootstrap/outputs.tf`

---

### Step 7 — Root Module Wiring

- [ ] Write `main.tf` — the `google_project_service` resources and the three module calls →
  see [Root Module Calls](#root-module-calls)
- [ ] Write `outputs.tf` → see [Variables and Outputs](#variables-and-outputs)

---

### Step 8 — Init and Validate

```bash
cd provisioning/opentofu

# Downloads providers (google, kubernetes, helm), installs modules,
# and connects to the GCS backend to verify state access.
# Run this again any time you add or change a provider or module.
tofu init

# Syntax-checks all HCL without touching any APIs.
# Catches typos and structural errors cheaply.
tofu validate

# Auto-formats all HCL to canonical style. The -recursive flag covers modules too.
tofu fmt -recursive
```

If `tofu init` fails, the most common causes are: ADC not configured, the GCS state bucket
does not exist yet, or a typo in `backend.tf`.

---

### Step 9 — Plan and Apply

```bash
# Previews exactly what OpenTofu will create, change, or destroy.
# No infrastructure is touched. Read this carefully before applying.
tofu plan

# Executes the plan. Type "yes" when prompted.
# Takes approximately 8–10 minutes; the GKE control plane is the slow part.
tofu apply
```

OpenTofu will sequence the work automatically based on the dependency graph:

```
APIs → VPC → GKE service account + IAM → GKE cluster → node pool → ArgoCD (Helm) → ArgoCD Application CRD
```

When `tofu apply` finishes, ArgoCD begins syncing `gitops/cluster/` automatically. The
three ApplicationSets deploy in sync-wave order: infra → platform → apps.

---

### Step 10 — Verify

[`gcloud container clusters get-credentials` reference](https://docs.cloud.google.com/sdk/gcloud/reference/container/clusters/get-credentials)

```bash
# Configure kubectl to talk to the new cluster
gcloud container clusters get-credentials sandbox-gke \
  --zone us-east1-b \
  --project terraform-sandbox

# Confirm nodes are Ready
kubectl get nodes

# Confirm ArgoCD pods are running
kubectl get pods -n argocd

# Port-forward the ArgoCD UI to http://localhost:8080
kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

The initial ArgoCD admin password is stored as a Kubernetes secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

---

### Step 11 — Teardown

```bash
# Destroy all managed infrastructure. Takes ~5 minutes.
# Run this whenever you are done for the day — the cluster costs money while running.
tofu destroy
```

The GCS state bucket and its contents survive `tofu destroy`. That is intentional — the
state records what was destroyed and the bucket costs essentially nothing to keep.

---

## Reference: Layer by Layer

Detailed reference for each layer. Every code block is labeled with its destination file.

---

### Layer 0: Manual Bootstrap (the irreducible exception)

These two things must be done once by hand. They are prerequisites for OpenTofu to run at
all, so OpenTofu cannot manage them.

#### The GCS State Bucket

OpenTofu cannot manage the bucket that holds its own state — the bucket must exist before
`tofu init` can connect to the backend. Create it once and leave it alone.

[`gcloud storage buckets create` reference](https://docs.cloud.google.com/sdk/gcloud/reference/storage/buckets/create) | [`gcloud storage buckets update` reference](https://docs.cloud.google.com/sdk/gcloud/reference/storage/buckets/update)

```bash
# Create the state bucket
gcloud storage buckets create gs://sandbox-gke-tofu-state \
  --project=terraform-sandbox \
  --location=us-east1 \
  --uniform-bucket-level-access

# Enable versioning — allows rolling back to a previous state file if something goes wrong
gcloud storage buckets update gs://sandbox-gke-tofu-state \
  --versioning
```

GCS supports state locking natively via object metadata — no DynamoDB table required
(that is an S3/AWS-specific requirement).

#### Application Default Credentials (ADC)

OpenTofu uses ADC to authenticate with GCP. The Google provider and the GCS backend both
pick it up automatically from `~/.config/gcloud/`.

[How Application Default Credentials works](https://docs.cloud.google.com/docs/authentication/application-default-credentials) | [`gcloud auth application-default login` reference](https://docs.cloud.google.com/sdk/gcloud/reference/auth/application-default/login)

```bash
gcloud auth application-default login
```

This opens a browser for OAuth login. The resulting token is what OpenTofu uses to deploy
resources. The service account created in Layer 1 is a separate thing — that is what the
cluster nodes use at runtime.

---

### Layer 1: GCP Project Configuration

#### 1a. Enable Required GCP APIs

GCP APIs must be explicitly enabled before any resource that depends on them can be
provisioned. `for_each` iterates over a set of values and creates one resource instance per
value — this is more maintainable than five separate resource blocks.

[`for_each` docs](https://opentofu.org/docs/language/meta-arguments/for_each/)

**`provisioning/opentofu/main.tf`**
```hcl
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",            # GKE
    "compute.googleapis.com",              # VPC, subnets
    "iam.googleapis.com",                  # IAM
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",              # GCS
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false  # Don't disable APIs on tofu destroy — other things in the project may depend on them
}
```

#### 1b. Service Account for the GKE Node Pool

The default Compute Engine service account that GKE nodes would otherwise use has far too
many permissions. This creates a purpose-built, minimal service account.

These three roles are the minimum a GKE node pool service account needs:

| Role | Purpose |
|---|---|
| `roles/logging.logWriter` | Write container logs to Cloud Logging |
| `roles/monitoring.metricWriter` | Write metrics to Cloud Monitoring |
| `roles/artifactregistry.reader` | Pull container images from Artifact Registry |

**`provisioning/opentofu/modules/gke/main.tf`**
```hcl
resource "google_service_account" "gke_nodes" {
  account_id   = "sandbox-gke-nodes"
  display_name = "sandbox-gke node pool SA"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_nodes_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}
```

---

### Layer 2: Networking

Never use the GCP default VPC — it uses auto-mode subnets that do not give you control over
IP ranges. OpenTofu manages a dedicated VPC and subnet with explicit CIDR ranges.

GKE requires **secondary IP ranges** on the subnet when using VPC-native (alias IP)
networking — one range for pod IPs and one for service IPs. These ranges are declared on
the subnet here in Layer 2, and referenced by name in the cluster config in Layer 3.

**`provisioning/opentofu/modules/vpc/main.tf`**
```hcl
resource "google_compute_network" "vpc" {
  name                    = "sandbox-gke-vpc"
  auto_create_subnetworks = false  # No auto-mode — create subnets explicitly
  project                 = var.project_id
}

resource "google_compute_subnetwork" "primary" {
  name          = "sandbox-gke-subnet"
  ip_cidr_range = "10.10.0.0/24"   # node IPs — up to 254 nodes
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"   # up to 65,536 pod IPs
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/16"   # up to 65,536 service IPs
  }
}
```

**`provisioning/opentofu/modules/vpc/outputs.tf`**
```hcl
output "network_id" {
  value = google_compute_network.vpc.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.primary.id
}
```

**`provisioning/opentofu/modules/vpc/variables.tf`**
```hcl
variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region"
}
```

---

### Layer 3: GKE Cluster and Node Pool

[Google provider registry](https://search.opentofu.org/provider/opentofu/google/)

#### The Cluster

**`provisioning/opentofu/modules/gke/main.tf`** (cluster block)
```hcl
resource "google_container_cluster" "primary" {
  name     = "sandbox-gke"
  location = var.zone   # zonal cluster — one control plane, cheaper than regional (3 control planes)
  project  = var.project_id

  # Remove the default node pool immediately after cluster creation.
  # We manage the node pool as a separate resource for more explicit control.
  remove_default_node_pool = true
  initial_node_count       = 1   # required even when removing the default pool

  network    = var.network_id
  subnetwork = var.subnetwork_id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"      # references the secondary range name from the subnet
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"   # enables Workload Identity on the cluster
  }

  lifecycle {
    prevent_destroy = false
  }
}
```

[`lifecycle` and `prevent_destroy` docs](https://opentofu.org/docs/language/resources/behavior/)

#### The Node Pool

**`provisioning/opentofu/modules/gke/main.tf`** (node pool block)
```hcl
resource "google_container_node_pool" "primary" {
  name     = "sandbox-gke-nodes"
  location = var.zone
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-standard-2"
    spot         = true  # preemptible VMs — ~70% cost reduction; GKE restarts pods if a node is reclaimed

    service_account = google_service_account.gke_nodes.email   # direct reference — both resources live in this module
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"] # Best practice: broad scope here, limit via IAM on the SA

    workload_metadata_config {
      mode = "GKE_METADATA"  # required for Workload Identity — prevents pods from reaching the node metadata server directly
    }
  }
}
```

> **Note on self-reference:** `service_account` references `google_service_account.gke_nodes.email`
> directly rather than via an input variable. Both resources live in this module, so a direct
> reference is correct and simpler. A `var.node_sa_email` input would be circular — the root would
> have to read the SA email output and immediately pass it back as an input to the same module.

[`depends_on` docs](https://opentofu.org/docs/language/meta-arguments/depends_on/)

#### GKE Module Outputs

**`provisioning/opentofu/modules/gke/outputs.tf`**
```hcl
output "endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true   # contains a routable IP — not printed in plain text during tofu apply
}

output "ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "node_sa_email" {
  value = google_service_account.gke_nodes.email
}
```

**`provisioning/opentofu/modules/gke/variables.tf`**
```hcl
variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "zone" {
  type        = string
  description = "GCP zone for the GKE cluster"
}

variable "network_id" {
  type        = string
  description = "VPC network ID"
}

variable "subnetwork_id" {
  type        = string
  description = "Subnetwork ID"
}

variable "k8s_namespace" {
  type        = string
  description = "Kubernetes namespace for the workload identity binding"
  default     = "default"
}

variable "k8s_sa_name" {
  type        = string
  description = "Kubernetes service account name for the workload identity binding"
  default     = "default"
}
```

---

### Layer 4: Workload Identity

[Authenticate to Google Cloud APIs from GKE workloads](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)

Workload Identity is how GKE pods authenticate to GCP APIs without key files. The mechanism:
a Kubernetes service account (KSA) is annotated with a GCP service account (GSA) email, and
an IAM binding allows the KSA to impersonate the GSA. OpenTofu manages the GCP side.

ArgoCD itself does not need GCP API access, but this wires up the pattern for future
workloads that do (e.g. External Secrets Operator reading from GCP Secret Manager).

**`provisioning/opentofu/modules/gke/main.tf`** (workload identity block)
```hcl
resource "google_service_account" "workload" {
  account_id   = "sandbox-gke-workload"
  display_name = "Example workload SA"
  project      = var.project_id
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_sa_name}]"
}
```

The `member` string is the Workload Identity federation format:
`serviceAccount:<project>.svc.id.goog[<namespace>/<kubernetes-service-account>]`

The corresponding annotation on the Kubernetes side (managed in `gitops/`, deployed by
ArgoCD — not by OpenTofu):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    iam.gke.io/gcp-service-account: sandbox-gke-workload@terraform-sandbox.iam.gserviceaccount.com
```

---

### Layer 5: ArgoCD Bootstrap

#### The Provider Chaining Problem

The `kubernetes` and `helm` providers need the GKE cluster's endpoint and CA certificate.
Those values do not exist until the cluster is provisioned. This creates a sequencing
problem that OpenTofu solves through **provider chaining**.

[Provider configuration docs](https://opentofu.org/docs/language/modules/develop/providers/) | [Cluster Access & Auth Plugins](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl)

Key rule from the docs: **provider configurations can be defined only in the root module.**
Child modules cannot contain `provider` blocks — if they did, the module would be
incompatible with `for_each`, `count`, and `depends_on` meta-arguments.

The `module.gke.endpoint` reference in the provider block creates an **implicit dependency**
— OpenTofu knows it must complete the `gke` module before it can configure the `kubernetes`
and `helm` providers.

**`provisioning/opentofu/providers.tf`**
```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}

# Data source: fetches a short-lived OAuth access token for the current ADC identity.
# Data sources are read-only — they look things up, they don't create anything.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  }
}
```

[Data sources docs](https://opentofu.org/docs/language/data-sources/)

`google_client_config` is a data source that reads (but does not create) the current OAuth
access token from your ADC credentials.

#### ArgoCD via Helm

[artifacthub.io — argo-cd chart](https://artifacthub.io/packages/helm/argo-cd-charts/argo-cd)

Pinned to `9.5.4` (Argo CD v3.x, stable as of April 2026). Check artifacthub.io for the
latest release before a fresh apply — this version string is the first thing to go stale.

The three `set` blocks configure common sandbox concerns:
- **`server.service.type = ClusterIP`** — no external LoadBalancer; access the UI via `kubectl port-forward`
- **`controller.enableApplicationSet = true`** — explicit opt-in; v3+ enables this by default but being explicit prevents drift
- **`server.extraArgs = {--insecure}`** — disables TLS on the server; avoids certificate warnings when port-forwarding

**`provisioning/opentofu/modules/bootstrap/main.tf`**
```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.5.4"   # Argo CD v3.x — check artifacthub.io before applying
  namespace        = "argocd"
  create_namespace = true

  # No external LoadBalancer — use kubectl port-forward in a sandbox
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Argo CD v3+ enables ApplicationSets by default, but explicit is better than implicit
  set {
    name  = "controller.enableApplicationSet"
    value = "true"
  }

  # Disable TLS to avoid certificate warnings when port-forwarding
  set {
    name  = "server.extraArgs"
    value = "{--insecure}"
  }
}
```

#### Initial ArgoCD Application (root-app)

This is the single Kubernetes manifest OpenTofu creates in the cluster. It points ArgoCD
at `gitops/cluster/` in this repo. From there, ArgoCD takes over and self-assembles the
rest of the cluster via ApplicationSets.

The content matches `gitops/bootstrap/root-app.yaml` (which exists in this repo as a
reference copy of what this resource deploys). The only templated value is `repoURL`.

**`provisioning/opentofu/modules/bootstrap/main.tf`** (continued)
```hcl
resource "kubernetes_manifest" "argocd_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "cluster-root"
      namespace = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]   # cascade-delete: removing this Application also removes everything it manages
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "HEAD"
        path           = "gitops/cluster"   # the kustomization + three ApplicationSets
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]   # ArgoCD CRDs must exist before an Application CRD can be created
}
```

**`provisioning/opentofu/modules/bootstrap/variables.tf`**
```hcl
variable "gitops_repo_url" {
  type        = string
  description = "URL of the GitOps repo — ArgoCD points at gitops/cluster/ after bootstrap"
}
```

---

### Root Module Calls

This wires the three modules together. The root module passes outputs from one module as
inputs to another — this is called flat composition.

[Module composition docs](https://opentofu.org/docs/language/modules/develop/composition/)

**`provisioning/opentofu/main.tf`**
```hcl
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "vpc" {
  source     = "./modules/vpc"
  project_id = var.project_id
  region     = var.region
}

module "gke" {
  source        = "./modules/gke"
  project_id    = var.project_id
  zone          = var.zone
  network_id    = module.vpc.network_id
  subnetwork_id = module.vpc.subnetwork_id

  depends_on = [google_project_service.apis]   # APIs must be enabled before GKE can be created
}

module "bootstrap" {
  source          = "./modules/bootstrap"
  gitops_repo_url = var.gitops_repo_url

  depends_on = [module.gke]   # wait for the full gke module (including node pool Ready) before Helm installs ArgoCD
}
```

When `depends_on` is applied to a module block, it affects the ordering of **all** resources
within that module.

[Module syntax docs](https://opentofu.org/docs/language/modules/syntax/)

---

## Backend Configuration

[Backend configuration docs](https://opentofu.org/docs/language/settings/backends/configuration/)  
[GCS backend docs](https://opentofu.org/docs/language/settings/backends/gcs/)  
[`required_providers` docs](https://opentofu.org/docs/language/providers/requirements/)

`backend.tf` does double duty: it configures the GCS remote state backend **and** pins provider
versions via `required_providers`. Pinning prevents surprise breakage when a provider ships a
new major version. The `~>` constraint allows patch and minor upgrades but not major ones —
`~> 6.0` means `>= 6.0, < 7.0`.

**`provisioning/opentofu/backend.tf`**
```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  backend "gcs" {
    bucket = "sandbox-gke-tofu-state"
    prefix = "sandbox-gke/opentofu"
  }
}
```

The state file will live at:
`gs://sandbox-gke-tofu-state/sandbox-gke/opentofu/default.tfstate`

**State locking:** GCS locks state natively via object metadata. This prevents two concurrent
`tofu apply` runs from corrupting the state file. No separate DynamoDB table is needed
(that is an S3/AWS requirement).

**Authentication:** With ADC configured locally, no additional credential configuration is
needed in `backend.tf` — the GCS backend picks up ADC automatically.

**Workspaces:** GCS supports OpenTofu workspaces, but the docs are explicit that workspaces
are **not** the right tool for managing fundamentally different environments with different
credentials. For this sandbox, a single workspace is correct.

[Workspaces docs](https://opentofu.org/docs/language/state/workspaces/)

---

## Variables and Outputs

[Variables docs](https://opentofu.org/docs/language/values/variables/)  
[Outputs docs](https://opentofu.org/docs/language/values/outputs/)

**`provisioning/opentofu/variables.tf`**
```hcl
variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region"
  default     = "us-east1"
}

variable "zone" {
  type        = string
  description = "GCP zone for the zonal GKE cluster"
  default     = "us-east1-b"
}

variable "gitops_repo_url" {
  type        = string
  description = "URL of this repo — ArgoCD points at gitops/cluster/ after bootstrap"
}
```

**`provisioning/opentofu/terraform.tfvars`** (gitignored — never commit this file)
```hcl
project_id      = "terraform-sandbox"
gitops_repo_url = "https://github.com/<your-username>/sandbox-gke"
```

Values can also be passed as environment variables (`TF_VAR_project_id`, etc.) if you prefer
not to use a `.tfvars` file.

**`provisioning/opentofu/outputs.tf`**
```hcl
output "cluster_endpoint" {
  value     = module.gke.endpoint
  sensitive = true   # marked sensitive — not printed in plain text during tofu apply
}

output "cluster_ca_certificate" {
  value     = module.gke.ca_certificate
  sensitive = true
}

# Run: tofu output get_credentials_command — then paste the result into your terminal
output "get_credentials_command" {
  value = "gcloud container clusters get-credentials sandbox-gke --zone ${var.zone} --project ${var.project_id}"
}
```

---

## Module Variables Reference

Each child module declares its own input variables. They're documented inline in their
respective Layer sections — this table is a quick cross-reference for when you need to
know which module accepts which inputs at a glance.

| Module | Variable | Type | Default | Where it flows |
|---|---|---|---|---|
| `vpc` | `project_id` | `string` | — | `google_compute_network`, `google_compute_subnetwork` |
| `vpc` | `region` | `string` | — | `google_compute_subnetwork.region` |
| `gke` | `project_id` | `string` | — | cluster, node pool, service accounts |
| `gke` | `zone` | `string` | — | cluster and node pool `location` |
| `gke` | `network_id` | `string` | — | `google_container_cluster.network` |
| `gke` | `subnetwork_id` | `string` | — | `google_container_cluster.subnetwork` |
| `gke` | `k8s_namespace` | `string` | `"default"` | workload identity IAM binding member string |
| `gke` | `k8s_sa_name` | `string` | `"default"` | workload identity IAM binding member string |
| `bootstrap` | `gitops_repo_url` | `string` | — | ArgoCD root Application `repoURL` |

All values flow from the root module's `main.tf` module blocks. `k8s_namespace` and
`k8s_sa_name` default to `"default"` as placeholders — update them when you add a real
workload that needs Workload Identity access to GCP APIs.

---

## IAM Audit

Do this before writing any HCL. The recycled `terraform-sandbox` account may have
accumulated broad roles.

[`gcloud projects get-iam-policy` reference](https://docs.cloud.google.com/sdk/gcloud/reference/projects/get-iam-policy) | [`gcloud auth list` reference](https://docs.cloud.google.com/sdk/gcloud/reference/auth/list)

```bash
# Check what roles your ADC identity has on the project
# (find your ADC email with: gcloud auth list)
gcloud projects get-iam-policy terraform-sandbox \
  --flatten="bindings[].members" \
  --format="table(bindings.role)" \
  --filter="bindings.members:<YOUR_EMAIL>"
```

Minimum roles required for OpenTofu to run this configuration:

| Role | Purpose |
|---|---|
| `roles/container.admin` | GKE cluster and node pool |
| `roles/compute.networkAdmin` | VPC, subnets |
| `roles/iam.serviceAccountAdmin` | Create and manage service accounts |
| `roles/iam.serviceAccountUser` | Bind service accounts to resources |
| `roles/resourcemanager.projectIamAdmin` | Manage IAM bindings |
| `roles/serviceusage.serviceUsageAdmin` | Enable APIs |
| `roles/storage.admin` | GCS state bucket |

[IAM predefined roles reference](https://docs.cloud.google.com/iam/docs/understanding-roles)

> **If your identity has `roles/editor` or `roles/owner`: downscope it.** A broad role on
> `terraform-sandbox` — even protected only by a gitignored `.tfvars` file — is a liability.

---

## Cost and Spend Management

| Resource | Cost |
|---|---|
| GKE Standard control plane | $0.10/hr (~$73/mo) |
| e2-standard-2 spot node (1 node minimum) | ~$0.02/hr (~$14/mo) |
| **Total at minimum scale** | **~$0.12/hr** |

- Set GCP billing alerts at $50 and $100 (Console → Billing → Budgets & Alerts)
- **Run `tofu destroy` when done for the day**
- `tofu apply` from scratch: ~8–10 minutes. `tofu destroy`: ~5 minutes.
- The GCS state bucket costs essentially nothing and should be kept between sessions.

With $310 in credits and disciplined teardown, this project effectively never runs out.

---

## Interacting with the Cluster

Everything here runs from the command line. After `tofu apply` completes, the cluster is up
and ArgoCD is syncing. Here's how to get in and poke around.

---

### Get Credentials

OpenTofu printed the exact command as part of its output:

```bash
tofu output get_credentials_command
```

Or run it directly:

```bash
gcloud container clusters get-credentials sandbox-gke \
  --zone us-east1-b \
  --project terraform-sandbox-430820
```

This writes a new context into `~/.kube/config` and makes it the current context. Confirm
it worked:

```bash
kubectl config current-context
kubectl get nodes
```

You should see your `e2-standard-2` spot nodes in `Ready` state.

---

### Basic Cluster Inspection

```bash
# Nodes and their status
kubectl get nodes -o wide

# Everything running across all namespaces — good first-look command
kubectl get pods -A

# What's in the ArgoCD namespace
kubectl get all -n argocd

# Infra/platform namespaces — populated after ArgoCD sync-waves complete
kubectl get pods -n cert-manager
kubectl get pods -n monitoring
kubectl get pods -n logging
kubectl get pods -n tracing
```

---

### ArgoCD

#### Get the Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

The `&& echo` adds a newline so your prompt doesn't run into the password.

#### Port-Forward the UI

```bash
kubectl port-forward svc/argocd-server 8080:80 -n argocd
```

Then open http://localhost:8080. Username: `admin`, password from the secret above.

> The chart is deployed with `--insecure` and `service.type=ClusterIP` — port-forward is
> the intended access method. No ingress, no LoadBalancer, no TLS headaches.

#### ArgoCD CLI

Install once:

```bash
brew install argocd
```

Log in (requires the port-forward above to be running):

```bash
argocd login localhost:8080 --username admin --insecure
```

Useful commands:

```bash
# List all Applications and their sync/health status
argocd app list

# Detailed view of a specific Application (shows sync errors, resource tree)
argocd app get cluster-root

# Manually trigger a sync — useful when testing gitops changes
argocd app sync cluster-root

# Watch sync status live
argocd app get cluster-root --watch
```

---

### Watching the Sync-Wave Progression After Apply

ArgoCD begins syncing `gitops/cluster/` automatically once the root Application is
created. The three ApplicationSets fire in sync-wave order. Watch it happen:

```bash
# Watch Applications appear and reach Synced/Healthy
kubectl get applications -n argocd -w

# Or with the argocd CLI (more readable output)
watch argocd app list
```

Expected progression:

1. `cluster-root` syncs → creates three ApplicationSets
2. ApplicationSets create per-wave Applications
3. Wave 0: `cert-manager` (infra-set)
4. Wave 1: `kube-prometheus-stack`, `loki`, `tempo`, `alloy` (platform-set)
5. Wave 2: `otel-demo` (apps-set)

Waves 1 and 2 each take a few minutes. Full convergence from a fresh `tofu apply` to
everything `Healthy` is typically 10–15 minutes after the apply completes.

---

### Logs and Debugging

```bash
# Tail logs from a deployment
kubectl logs -n argocd deploy/argocd-server -f

# Describe a resource to see events — useful when a pod is stuck Pending or CrashLooping
kubectl describe pod -n argocd <pod-name>

# Get events for a namespace sorted by time
kubectl get events -n argocd --sort-by='.lastTimestamp'

# Show what ArgoCD thinks the sync error is
argocd app get <app-name>

# Exec into a running container for interactive debugging
kubectl exec -it -n argocd deploy/argocd-server -- /bin/sh
```

---

### Managing Contexts

If you tear down and recreate the cluster, `gcloud container clusters get-credentials`
creates a new context. List and switch contexts:

```bash
# List all contexts
kubectl config get-contexts

# Switch to a specific context
kubectl config use-context <context-name>

# Delete a stale context after tofu destroy
# Context name format: gke_<project>_<zone>_<cluster-name>
kubectl config delete-context gke_terraform-sandbox-430820_us-east1-b_sandbox-gke
```

---

## OpenTofu Core Concepts

Quick reference to the official docs for every concept this project exercises.

### The Core Workflow

[Core workflow docs](https://opentofu.org/docs/intro/core-workflow/)

Write → Plan → Apply. Every `tofu` operation follows this loop.

| Command | What it does |
|---|---|
| `tofu init` | Initializes the working directory. Downloads providers, installs modules, connects to the GCS backend. Run this first, and again whenever you add or change a provider or module. |
| `tofu validate` | Syntax-checks all HCL without touching any APIs. Run this after every edit. |
| `tofu fmt` | Auto-formats HCL to canonical style. Use `-recursive` to cover all modules. |
| `tofu plan` | Generates and previews an execution plan. No infrastructure is created or changed. |
| `tofu apply` | Executes the plan. Prompts for confirmation. |
| `tofu destroy` | Tears down all managed infrastructure. |
| `tofu output` | Prints output values from the root module. |
| `tofu state` | Inspect and manipulate state (advanced). |

[CLI reference](https://opentofu.org/docs/cli/commands/)

### The Language Reference

[Language reference](https://opentofu.org/docs/language/)

Every construct used in this project — `resource`, `variable`, `output`, `locals`, `module`,
`data`, `provider` — is documented here. Keep this open in a tab while writing HCL.

---

## Learning Objectives

Ordered by the concepts this project exercises, with doc references.

1. **HCL language fundamentals** — resources, variables, locals, outputs, expressions, `for_each`  
   [https://opentofu.org/docs/language/](https://opentofu.org/docs/language/)

2. **Provider configuration and chaining** — providers are root-module-only; child modules
   inherit them or receive them via the `providers` meta-argument  
   [https://opentofu.org/docs/language/modules/develop/providers/](https://opentofu.org/docs/language/modules/develop/providers/)

3. **Module structure and composition** — flat composition: root module wires child modules
   together by passing outputs as inputs  
   [https://opentofu.org/docs/language/modules/develop/composition/](https://opentofu.org/docs/language/modules/develop/composition/)

4. **`depends_on` — when and why** — for hidden dependencies OpenTofu cannot infer; at the
   module level it affects the ordering of all resources in that module  
   [https://opentofu.org/docs/language/meta-arguments/depends_on/](https://opentofu.org/docs/language/meta-arguments/depends_on/)

5. **Remote state with GCS backend** — state locking, versioning, the bootstrap exception  
   [https://opentofu.org/docs/language/settings/backends/gcs/](https://opentofu.org/docs/language/settings/backends/gcs/)

6. **Resource lifecycle** — `prevent_destroy`, `create_before_destroy`, `ignore_changes`  
   [https://opentofu.org/docs/language/resources/behavior/](https://opentofu.org/docs/language/resources/behavior/)

7. **Data sources** — `google_client_config.default` is a data source; reads the current OAuth
   token for use in the `kubernetes` and `helm` providers  
   [https://opentofu.org/docs/language/data-sources/](https://opentofu.org/docs/language/data-sources/)

8. **Workload Identity** — IAM binding pattern with the
   `serviceAccount:PROJECT.svc.id.goog[NS/KSA]` member format

---

## Provider and Registry References

| Provider | Registry |
|---|---|
| `hashicorp/google` | [https://search.opentofu.org/provider/opentofu/google/](https://search.opentofu.org/provider/opentofu/google/) |
| `hashicorp/kubernetes` | [https://search.opentofu.org/provider/opentofu/kubernetes/](https://search.opentofu.org/provider/opentofu/kubernetes/) |
| `hashicorp/helm` | [https://search.opentofu.org/provider/opentofu/helm/](https://search.opentofu.org/provider/opentofu/helm/) |

OpenTofu Registry: [https://search.opentofu.org](https://search.opentofu.org)

---

## Appendix: Pulumi/Python Alternative

The same infrastructure expressed in Pulumi/Python eliminates the provider chaining problem:
GKE cluster outputs are Python variables that resolve asynchronously via `pulumi.Output[T]`.
No `depends_on` gymnastics required. The tradeoff is a different mental model (async output
graph vs declarative HCL).

Deferred until the OpenTofu version is working. Stack would live in `provisioning/pulumi/`
alongside the OpenTofu configuration, pointing at the same GCS bucket with a different prefix.

---

## Changelog

### v1.2 — April 2026

Fix applied during first `tofu plan` run. See [troubleshooting.md](./troubleshooting.md) for full details.

- **`backend.tf`** — Added `gavinbunney/kubectl ~> 1.14` to `required_providers`.
- **`providers.tf`** — Added `kubectl` provider block (same cluster credentials as `helm`;
  `load_config_file = false` to prevent fallback to local kubeconfig).
- **`modules/bootstrap/main.tf`** — Replaced `kubernetes_manifest` (hashicorp/kubernetes)
  with `kubectl_manifest` (gavinbunney/kubectl). `kubernetes_manifest` contacts the live
  API server during `tofu plan` to fetch CRD schemas, which fails when the cluster doesn't
  exist yet. `kubectl_manifest` treats the manifest as a YAML string and only connects at
  apply time. Also added a `terraform { required_providers }` block to the module so
  OpenTofu resolves `kubectl` to `gavinbunney/kubectl` instead of the nonexistent
  `hashicorp/kubectl`.

### v1.1 — April 2026

Corrections and additions found during initial `tofu validate` and first apply attempt.

- **`backend.tf`** — Added `required_providers` block pinning `google ~> 6.0`,
  `kubernetes ~> 2.0`, `helm ~> 2.0`. The original guide noted this was needed but
  omitted the actual block from the code sample.
- **`modules/gke/main.tf`** — Fixed node pool `service_account`: was incorrectly using
  `var.node_sa_email`, a variable that was never declared and would have been circular.
  Corrected to `google_service_account.gke_nodes.email` — a direct reference within
  the same module.
- **`modules/bootstrap/main.tf`** — Replaced placeholder `version = "7.x.x"` with
  `9.5.4` (Argo CD v3.x, stable April 2026). Added `controller.enableApplicationSet`
  and `server.extraArgs = {--insecure}` set blocks.
- **All three module `variables.tf` files** — Were scaffolded as empty stubs in the
  original guide. Now contain the variable declarations required by each module's `main.tf`.

### v1.0 — initial

Original guide generated for project setup.

# `sandbox-gke` — OpenTofu Reference Guide

> An educational reference guide to building a push-button GKE cluster with OpenTofu,
> structured around the official OpenTofu documentation.

---

## What We're Building

A **repeatable, push-button GKE cluster** on GCP, managed end-to-end by OpenTofu
wherever possible. The cluster bootstraps itself into a GitOps-ready state — ArgoCD
installed via Helm, pointed at the existing `sandbox-gitops` repo — without any
manual `kubectl` intervention after `tofu apply`.

**GCP project:** recycled `terraform-sandbox` (IAM audit required — see below).
**Region:** `us-east1` (GCP syntax; no hyphen before the digit, unlike AWS `us-east-1`).
**Repo location:** `provisioning/opentofu/` subdirectory of `sandbox-gitops`.

---

## OpenTofu Core Concepts (with doc references)

Before writing a line of HCL, ground yourself in the following pages of the
official OpenTofu docs. These are the specific concepts this project exercises.

### The Core Workflow
https://opentofu.org/docs/intro/core-workflow/

Write -> Plan -> Apply. Every `tofu` operation you run in this project follows this
loop. The docs describe a solo workflow (which is what we're doing) and a team
workflow (which adds CI and remote state locking -- both of which we configure here,
even for solo use, as good discipline).

### The Language Reference
https://opentofu.org/docs/language/

The primary reference for HCL syntax. Every construct used below (`resource`,
`variable`, `output`, `locals`, `module`, `data`, `provider`, `terraform`) is
documented here. Keep this open in a tab.

### CLI Reference
https://opentofu.org/docs/cli/commands/

The commands you'll use constantly:

| Command | Purpose |
|---|---|
| `tofu init` | Initialise working directory, install providers and modules |
| `tofu validate` | Syntax-check your config without hitting any APIs |
| `tofu plan` | Generate and preview an execution plan |
| `tofu apply` | Execute the plan |
| `tofu destroy` | Tear everything down |
| `tofu fmt` | Auto-format HCL to canonical style |
| `tofu output` | Print output values from the root module |
| `tofu state` | Inspect and manipulate state (advanced) |

`tofu plan` docs: https://opentofu.org/docs/cli/commands/plan/

---

## What OpenTofu Will Manage

This project pushes as much as possible into OpenTofu. Here is the full inventory,
ordered by provisioning sequence.

### Layer 0: Manual Bootstrap (the irreducible exception)

These two things cannot be managed by OpenTofu because they are prerequisites for
OpenTofu to operate at all. They must be done once by hand.

**1. The GCS state bucket**

OpenTofu cannot manage the bucket that stores its own state. This is a universal
bootstrapping problem in IaC. The standard answer is: create it manually once,
then leave it alone forever.

```bash
# Create the state bucket
gcloud storage buckets create gs://sandbox-gke-tofu-state \
  --project=terraform-sandbox \
  --location=us-east1 \
  --uniform-bucket-level-access

# Enable versioning -- lets you roll back corrupted state
gcloud storage buckets update gs://sandbox-gke-tofu-state \
  --versioning
```

**2. Application Default Credentials (ADC)**

OpenTofu needs credentials to authenticate with GCP before it can provision
anything. For local use, `gcloud auth application-default login` is correct.
The service account work below (which is managed by OpenTofu) is about what
credentials the cluster uses at runtime, not what credentials OpenTofu uses
to run.

```bash
gcloud auth application-default login
```

---

### Layer 1: GCP Project Configuration (OpenTofu `google` provider)

Everything from here down is managed by OpenTofu.

#### 1a. Enable Required GCP APIs

GCP APIs must be explicitly enabled before any resource that uses them can be
provisioned. OpenTofu manages these with `google_project_service` and `for_each`.

`for_each` docs: https://opentofu.org/docs/language/meta-arguments/for_each/

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
  disable_on_destroy = false  # Don't disable APIs on tofu destroy
}
```

`disable_on_destroy = false` is deliberate: disabling APIs on destroy can break
other things in the project that depend on them.

#### 1b. Service Account for the GKE Node Pool

Instead of giving node VMs the default Compute Engine service account (which has
wildly excessive permissions), we create a minimal service account via OpenTofu.

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

These three roles are the minimum a GKE node pool SA needs: write logs, write
metrics, and pull images from Artifact Registry.

---

### Layer 2: Networking (`modules/vpc/`)

Never use the GCP default VPC. OpenTofu manages a dedicated VPC and subnet.

```hcl
resource "google_compute_network" "vpc" {
  name                    = "sandbox-gke-vpc"
  auto_create_subnetworks = false  # We create subnets explicitly
  project                 = var.project_id
}

resource "google_compute_subnetwork" "primary" {
  name          = "sandbox-gke-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/16"
  }
}
```

GKE requires secondary ranges for pods and services when using VPC-native
(alias IP) networking. These are declared here and referenced by the cluster
config in Layer 3.

---

### Layer 3: GKE Cluster + Node Pool (`modules/gke/`)

Provider registry for all `google_*` resources:
https://search.opentofu.org/provider/opentofu/google/

#### The Cluster

```hcl
resource "google_container_cluster" "primary" {
  name     = "sandbox-gke"
  location = var.zone   # zonal cluster; cheaper than regional
  project  = var.project_id

  # We manage the node pool separately; remove the default one
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_id
  subnetwork = var.subnetwork_id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  lifecycle {
    prevent_destroy = false  # flip to true once you're happy with it
  }
}
```

`lifecycle` and `prevent_destroy` docs:
https://opentofu.org/docs/language/resources/behavior/

#### The Node Pool

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
    spot         = true  # preemptible; ~70% cost reduction

    service_account = var.node_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"  # required for Workload Identity
    }
  }

  depends_on = [google_container_cluster.primary]
}
```

`depends_on` docs:
https://opentofu.org/docs/language/meta-arguments/depends_on/

The `depends_on` meta-argument handles hidden dependencies that OpenTofu cannot
automatically infer. The docs note it should be used as a last resort because it
causes more conservative plans. Here it's justified: the node pool resource doesn't
directly reference enough cluster attributes for OpenTofu to infer the ordering
reliably across all plan scenarios.

---

### Layer 4: Workload Identity (`modules/gke/`)

Workload Identity is how GKE pods authenticate to GCP APIs without key files.
The mechanism: a Kubernetes service account (KSA) is annotated with a GCP
service account (GSA) email, and an IAM binding allows the KSA to impersonate
the GSA. OpenTofu manages both sides.

For ArgoCD itself, no GCP API access is needed. But the pattern is worth wiring
up for any future workload that does need it (e.g. External Secrets Operator
talking to GCP Secret Manager):

```hcl
resource "google_service_account" "workload" {
  account_id   = "sandbox-gke-workload"
  display_name = "Example workload SA"
  project      = var.project_id
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_sa_name}]"
}
```

The corresponding annotation on the KSA (managed in `sandbox-gitops`, not here):
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    iam.gke.io/gcp-service-account: sandbox-gke-workload@terraform-sandbox.iam.gserviceaccount.com
```

---

### Layer 5: ArgoCD Bootstrap (`modules/bootstrap/`)

This is where provider chaining becomes the central HCL concept.

#### The Provider Chaining Problem

The `kubernetes` and `helm` providers need the GKE cluster's endpoint and CA
certificate -- values that don't exist until the cluster is provisioned. This
creates a sequencing problem.

Provider configuration docs:
https://opentofu.org/docs/language/modules/develop/providers/

Key rule from the docs: provider configurations can be **defined only in the
root module**. Child modules cannot contain provider blocks if they are to be
compatible with `for_each`, `count`, and `depends_on` meta-arguments.

The pattern in `providers.tf`:

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}

# data source: gets a short-lived OAuth token for the current ADC identity
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

The `module.gke.endpoint` reference creates an implicit dependency -- OpenTofu
knows it must run the `gke` module before configuring the `kubernetes` and `helm`
providers. You will also need an explicit `depends_on` on the `bootstrap` module
to guarantee the node pool is Ready (not just the control plane) before Helm tries
to install ArgoCD:

```hcl
module "bootstrap" {
  source          = "./modules/bootstrap"
  gitops_repo_url = var.gitops_repo_url

  depends_on = [module.gke]  # wait for the full gke module, including node pool
}
```

When `depends_on` is applied to a module block, it affects the ordering of **all**
resources within that module.
Docs: https://opentofu.org/docs/language/modules/syntax/

#### ArgoCD via Helm

```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.x.x"   # pin this
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"  # no external LoadBalancer for a sandbox
  }
}
```

#### Initial ArgoCD Application pointing at `sandbox-gitops`

```hcl
resource "kubernetes_manifest" "argocd_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "sandbox-gitops"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "main"
        path           = "."
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
      }
    }
  }

  depends_on = [helm_release.argocd]
}
```

From this point, ArgoCD takes over. The cluster self-assembles from
`sandbox-gitops` -- cloud edition.

---

## Backend Configuration

Backend configuration docs:
https://opentofu.org/docs/language/settings/backends/configuration/

GCS backend docs:
https://opentofu.org/docs/language/settings/backends/gcs/

```hcl
# backend.tf
terraform {
  backend "gcs" {
    bucket = "sandbox-gke-tofu-state"
    prefix = "sandbox-gke/opentofu"
  }
}
```

The docs recommend using environment variables for credentials, not hardcoding
them. With ADC configured locally, no additional credential configuration is
needed for the GCS backend -- it picks up ADC automatically.

GCS supports state locking natively via GCS object metadata. No separate
DynamoDB table required (unlike S3). Locking prevents concurrent `tofu apply`
runs from corrupting state.

GCS backend supports OpenTofu workspaces:
https://opentofu.org/docs/language/state/workspaces/

The docs are explicit: workspaces are **not** appropriate for managing
fundamentally different environments with different credentials. For that, use
separate root modules with separate backends. For this sandbox, a single
workspace is correct.

---

## Module Structure

Standard module structure docs:
https://opentofu.org/docs/language/modules/develop/structure/

Module blocks docs:
https://opentofu.org/docs/language/modules/syntax/

```
provisioning/opentofu/
├── backend.tf          # GCS backend config
├── providers.tf        # all provider blocks (root module only)
├── variables.tf        # root module input variables
├── outputs.tf          # root module outputs
├── main.tf             # module calls and top-level resources (API enablement, etc.)
└── modules/
    ├── vpc/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── gke/
    │   ├── main.tf      # cluster, node pool, service account, IAM
    │   ├── variables.tf
    │   └── outputs.tf   # endpoint, ca_certificate, node_sa_email
    └── bootstrap/
        ├── main.tf      # helm_release argocd, kubernetes_manifest argocd app
        ├── variables.tf
        └── outputs.tf
```

Per the docs, `main.tf`, `variables.tf`, `outputs.tf` are the recommended
filenames for a minimal module, even if they're empty.

Key rule: provider configurations can be **defined only in the root module**.
https://opentofu.org/docs/language/modules/develop/providers/

Module calls in `main.tf`:

```hcl
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

  depends_on = [google_project_service.apis]
}

module "bootstrap" {
  source          = "./modules/bootstrap"
  gitops_repo_url = var.gitops_repo_url

  depends_on = [module.gke]
}
```

Module composition pattern docs:
https://opentofu.org/docs/language/modules/develop/composition/

The root module wires child modules together by passing outputs from one as inputs
to another. This is called "flat composition" -- preferred over deeply nested
module trees.

---

## Variables and Outputs

Variables docs: https://opentofu.org/docs/language/values/variables/
Outputs docs: https://opentofu.org/docs/language/values/outputs/

Root `variables.tf`:

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
  description = "GCP zone for zonal GKE cluster"
  default     = "us-east1-b"
}

variable "gitops_repo_url" {
  type        = string
  description = "URL of the sandbox-gitops Git repository"
}
```

Supply values via a `terraform.tfvars` file (gitignored) or environment variables
(`TF_VAR_project_id`, etc.):

```hcl
# terraform.tfvars  <-- add to .gitignore
project_id      = "terraform-sandbox"
gitops_repo_url = "https://github.com/yourname/sandbox-gitops"
```

Root `outputs.tf`:

```hcl
output "cluster_endpoint" {
  value     = module.gke.endpoint
  sensitive = true  # contains a routable IP; mark sensitive
}

output "cluster_ca_certificate" {
  value     = module.gke.ca_certificate
  sensitive = true
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials sandbox-gke --zone ${var.zone} --project ${var.project_id}"
}
```

---

## IAM Audit (Do This Before Writing HCL)

The recycled `terraform-sandbox` service account may have accumulated broad roles.

```bash
gcloud projects get-iam-policy terraform-sandbox \
  --flatten="bindings[].members" \
  --format="table(bindings.role)" \
  --filter="bindings.members:<SA_EMAIL>"
```

Minimum roles required for OpenTofu to run this configuration:

| Role | Purpose |
|---|---|
| `roles/container.admin` | GKE cluster and node pool |
| `roles/compute.networkAdmin` | VPC, subnets |
| `roles/iam.serviceAccountAdmin` | Create and manage service accounts |
| `roles/iam.serviceAccountUser` | Bind SAs to resources |
| `roles/resourcemanager.projectIamAdmin` | Manage IAM bindings |
| `roles/serviceusage.serviceUsageAdmin` | Enable APIs |
| `roles/storage.admin` | GCS state bucket |

If the SA has `roles/editor` or `roles/owner`: downscope it. A service account
with Owner sitting in a `.tfvars` file -- even gitignored -- is a liability.

---

## Cost and Spend Management

GKE Standard control plane: **$0.10/hour** (~$73/month) regardless of nodes.
Node pool (e2-standard-2, spot, 1 node minimum): **~$0.02/hour** (~$14/month).
Total running cost: **~$0.12/hour** at minimum scale.

With $310 in credits and disciplined teardown, this effectively never runs out.

- Set GCP billing alerts at $50 and $100 in the console
- **`tofu destroy` when done**
- A `tofu apply` from scratch takes ~8-10 minutes. `tofu destroy` takes ~5.

---

## Learning Objectives

Ordered by the concepts this project exercises, with doc references:

1. **HCL language fundamentals** -- resources, variables, locals, outputs, expressions, `for_each`
   https://opentofu.org/docs/language/

2. **Provider configuration and chaining** -- providers are root-module-only; child
   modules inherit them or receive them via the `providers` meta-argument
   https://opentofu.org/docs/language/modules/develop/providers/

3. **Module structure and composition** -- flat composition: root module wires child
   modules together by passing outputs as inputs
   https://opentofu.org/docs/language/modules/develop/composition/

4. **`depends_on` -- when and why** -- for hidden dependencies OpenTofu can't infer;
   at the module level it affects ordering of all resources in that module
   https://opentofu.org/docs/language/meta-arguments/depends_on/

5. **Remote state with GCS backend** -- state locking, versioning, the bootstrap exception
   https://opentofu.org/docs/language/settings/backends/gcs/

6. **Resource lifecycle** -- `prevent_destroy`, `create_before_destroy`, `ignore_changes`
   https://opentofu.org/docs/language/resources/behavior/

7. **Data sources** -- `google_client_config.default` is a data source; read-only
   lookup of the current OAuth token, used to authenticate kubernetes/helm providers
   https://opentofu.org/docs/language/data-sources/

8. **Workload Identity** -- the IAM binding pattern with the
   `serviceAccount:PROJECT.svc.id.goog[NS/KSA]` member format

---

## Provider and Registry References

| Provider | Registry |
|---|---|
| `hashicorp/google` | https://search.opentofu.org/provider/opentofu/google/ |
| `hashicorp/kubernetes` | https://search.opentofu.org/provider/opentofu/kubernetes/ |
| `hashicorp/helm` | https://search.opentofu.org/provider/opentofu/helm/ |

OpenTofu Registry: https://search.opentofu.org

---

## Appendix: Pulumi/Python Alternative

The same infrastructure expressed in Pulumi/Python eliminates the provider chaining
problem: GKE cluster outputs are Python variables that resolve asynchronously via
`pulumi.Output[T]`. No `depends_on` gymnastics required. The tradeoff is a different
mental model (async output graph vs declarative HCL).

Deferred until the OpenTofu version is working and you feel like it. Stack would
live in `provisioning/pulumi/` alongside the OpenTofu configuration, pointing at
the same GCS bucket with a different prefix.

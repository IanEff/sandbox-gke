# `sandbox-gke` — Troubleshooting & Gotchas

**Last updated:** April 2026

Lessons learned the hard way during initial provisioning. Consult this before you go
poking around trying to figure out why `tofu plan` is melting down.

---

## Table of Contents

1. [`kubernetes_manifest` crashes `tofu plan` with "cannot create REST client"](#kubernetes_manifest-crashes-tofu-plan-with-cannot-create-rest-client)

---

## `kubernetes_manifest` crashes `tofu plan` with "cannot create REST client"

### Symptom

`tofu plan` runs fine through the GCP resource plan — APIs, VPC, GKE cluster, node pool,
IAM — and then explodes at the very end:

```
╷
│ Error: Failed to construct REST client
│
│   with module.bootstrap.kubernetes_manifest.argocd_app,
│   on modules/bootstrap/main.tf line 29, in resource "kubernetes_manifest" "argocd_app":
│   29: resource "kubernetes_manifest" "argocd_app" {
│
│ cannot create REST client: no client config
╵
```

Everything up to that point is correct. The GKE cluster just hasn't been created yet —
that's the whole point of running `plan`.

### Root Cause

`kubernetes_manifest` (from `hashicorp/kubernetes`) is fundamentally different from every
other resource type in this stack. During `plan`, before creating anything, it reaches out
to the **live Kubernetes API server** to fetch the CRD schema for whatever `apiVersion`
and `kind` you've specified. In this case that's `argoproj.io/v1alpha1 / Application`.

It does this because it validates the manifest structure against the live schema, which is
a nice feature when the cluster already exists. When the cluster *doesn't exist yet* —
which is always the case on a first apply — there is no API server to talk to, and the
provider cannot construct its REST client. Plan fails.

The `depends_on = [module.gke]` in `main.tf` does not help here. `depends_on` controls
*apply order*, not plan-time behavior. The provider attempts the connection unconditionally
during plan regardless of what it depends on.

This is a long-standing known issue with `kubernetes_manifest`. See:
- https://github.com/hashicorp/terraform-provider-kubernetes/issues/1391

### Fix

Replace `kubernetes_manifest` with `kubectl_manifest` from the
[`gavinbunney/kubectl`](https://registry.terraform.io/providers/gavinbunney/kubectl/latest)
community provider. It accepts the manifest as a raw YAML string and does **not** contact
the API server during plan. Connection happens at apply time only, after the cluster is up.

#### 1. Add the provider to `backend.tf` `required_providers`

```hcl
# provisioning/opentofu/backend.tf
terraform {
  required_providers {
    # ... existing providers ...
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
```

#### 2. Add a provider block to `providers.tf`

Same credentials pattern as the `kubernetes` and `helm` providers — it needs the cluster
endpoint and CA certificate once the cluster exists:

```hcl
# provisioning/opentofu/providers.tf
provider "kubectl" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  load_config_file       = false
}
```

`load_config_file = false` prevents the provider from accidentally falling back to your
local `~/.kube/config` during plan. Without it you might get subtly wrong behavior on
machines where a kubeconfig happens to exist.

#### 3. Declare the provider in the bootstrap module

Child modules don't inherit `required_providers` from the root. Because `gavinbunney/kubectl`
is a community provider (not `hashicorp/*`), OpenTofu cannot infer the source automatically —
it will try `hashicorp/kubectl`, fail to find it in the registry, and die.

Add a `terraform` block at the top of `modules/bootstrap/main.tf`:

```hcl
terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }
}
```

You don't need to pin versions in child modules — the root module's version constraints
already govern what gets installed.

#### 4. Replace the resource

Before (broken):

```hcl
resource "kubernetes_manifest" "argocd_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    # ...HCL object...
  }
}
```

After (works):

```hcl
resource "kubectl_manifest" "argocd_app" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: cluster-root
      namespace: argocd
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: ${var.gitops_repo_url}
        targetRevision: HEAD
        path: gitops/cluster
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  YAML

  depends_on = [helm_release.argocd]
}
```

#### 5. Re-run `tofu init`

The new provider needs to be downloaded:

```bash
cd provisioning/opentofu
tofu init
```

You should see `gavinbunney/kubectl` appear in the init output and `.terraform.lock.hcl`
will be updated. Commit the updated lockfile.

### Why not just use `helm_release` for ArgoCD Applications too?

You could — the ArgoCD Helm chart can deploy an initial Application via its `values.yaml`.
But that couples your bootstrap Application config to the ArgoCD chart version and makes
it harder to see what's being created. `kubectl_manifest` keeps the Application as an
explicit, auditable resource in the OpenTofu state.

### Why is `gavinbunney/kubectl` not in the official registry under `hashicorp/`?

It's a community provider. HashiCorp maintains the `hashicorp/kubernetes` provider;
`gavinbunney/kubectl` is separately maintained and solves a specific gap that
`hashicorp/kubernetes` has never addressed. It's widely used and stable — `v1.19.0` is
the current release as of April 2026.

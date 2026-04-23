resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.5.4" # Latest stable as of April 2026 (Argo CD v3.x)
  namespace        = "argocd"
  create_namespace = true

  # Recommended for sandboxes to prevent "out of sync" due to defaulted fields
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Argo CD v3+ enables ApplicationSets by default, but it's good to be explicit
  set {
    name  = "controller.enableApplicationSet"
    value = "true"
  }

  # Skip TLS for the UI to avoid 'insecure' warnings when port-forwarding
  set {
    name  = "server.extraArgs"
    value = "{--insecure}"
  }
}

# Create the cluster
resource "kubernetes_manifest" "argocd_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "cluster-root"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"] # cascade-delete: removing this Application also removes everything it manages
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "HEAD"
        path           = "gitops/cluster" # the kustomization + three ApplicationSets
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

  depends_on = [helm_release.argocd] # ArgoCD CRDs must exist before an Application CRD can be created
}

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

# Create the cluster root Application — uses gavinbunney/kubectl so no live cluster is needed at plan time
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

  depends_on = [helm_release.argocd] # ArgoCD CRDs must exist before an Application CRD can be created
}

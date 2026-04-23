variable "gitops_repo_url" {
  type        = string
  description = "URL of the GitOps repo — ArgoCD points at gitops/cluster/ after bootstrap"
}

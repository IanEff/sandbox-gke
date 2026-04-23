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

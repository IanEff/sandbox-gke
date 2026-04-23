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

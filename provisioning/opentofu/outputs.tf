output "cluster_endpoint" {
  value     = module.gke.endpoint
  sensitive = true # marked sensitive — not printed in plain text during tofu apply
}

output "cluster_ca_certificate" {
  value     = module.gke.ca_certificate
  sensitive = true
}

# Run: tofu output get_credentials_command — then paste the result into your terminal
output "get_credentials_command" {
  value = "gcloud container clusters get-credentials sandbox-gke --zone ${var.zone} --project ${var.project_id}"
}

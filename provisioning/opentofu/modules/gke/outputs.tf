output "endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true # contains a routable IP — not printed in plain text during tofu apply
}

output "ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "node_sa_email" {
  value = google_service_account.gke_nodes.email
}

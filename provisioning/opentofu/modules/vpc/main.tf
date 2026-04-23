resource "google_compute_network" "vpc" {
  name                    = "sandbox-gke-vpc"
  auto_create_subnetworks = false # No auto-mode — create subnets explicitly
  project                 = var.project_id
}

resource "google_compute_subnetwork" "primary" {
  name          = "sandbox-gke-subnet"
  ip_cidr_range = "10.10.0.0/24" # node IPs — up to 254 nodes
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16" # up to 65,536 pod IPs
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/16" # up to 65,536 service IPs
  }
}

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

# Cluster block
resource "google_container_cluster" "primary" {
  name     = "sandbox-gke"
  location = var.zone # zonal cluster — one control plane, cheaper than regional (3 control planes)
  project  = var.project_id

  # Remove the default node pool immediately after cluster creation.
  # We manage the node pool as a separate resource for more explicit control.
  remove_default_node_pool = true
  initial_node_count       = 1 # required even when removing the default pool

  network    = var.network_id
  subnetwork = var.subnetwork_id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods" # references the secondary range name from the subnet
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog" # enables Workload Identity on the cluster
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Node pool block
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
    spot         = true # preemptible VMs — ~70% cost reduction; GKE restarts pods if a node is reclaimed

    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"] # Best practice: broad scope here, limit via IAM on the SA

    workload_metadata_config {
      mode = "GKE_METADATA" # required for Workload Identity — prevents pods from reaching the node metadata server directly
    }
  }
}

# Workload identity block
resource "google_service_account" "workload" {
  account_id   = "sandbox-gke-workload"
  display_name = "Example workload SA"
  project      = var.project_id
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_sa_name}]"
}

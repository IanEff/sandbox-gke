resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "vpc" {
  source     = "./modules/vpc"
  project_id = var.project_id
  region     = var.region
}

module "gke" {
  source        = "./modules/gke"
  project_id    = var.project_id
  zone          = var.zone
  network_id    = module.vpc.network_id
  subnetwork_id = module.vpc.subnetwork_id

  depends_on = [google_project_service.apis] # APIs must be enabled before GKE can be created
}

module "bootstrap" {
  source          = "./modules/bootstrap"
  gitops_repo_url = var.gitops_repo_url

  depends_on = [module.gke] # wait for the full gke module (including node pool Ready) before Helm installs ArgoCD
}

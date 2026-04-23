
terraform {
  backend "gcs" {
    bucket = "sandbox-gke-tofu-state"
    prefix = "sandbox-gke/opentofu"
  }
}

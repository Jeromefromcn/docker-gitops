resource "google_compute_network" "main" {
  name                    = "vps-gcp-vpc"
  auto_create_subnetworks = false # custom-mode VPC: full control over the subnet
  depends_on              = [google_project_service.compute]
}

resource "google_compute_subnetwork" "main" {
  name          = "vps-gcp-subnet"
  network       = google_compute_network.main.id
  region        = "us-west1"
  ip_cidr_range = "10.0.0.0/24"
  depends_on    = [google_project_service.compute]
}

# FREE-TIER BOUNDARY — every value below is a hardcoded literal on purpose,
# NOT a variable. Changing machine_type / region / disk size can produce real
# billing. See README "免费层边界" before touching anything here.
resource "google_compute_instance" "vps" {
  name         = "vps-gcp"
  machine_type = "e2-micro" # free only in us-west1/us-central1/us-east1
  zone         = "us-west1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30 # 30 GB is the free-tier standard-PD total
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      # ephemeral public IP — free tier allows 1 GB egress/month (excl. CN/AU)
    }
  }
}

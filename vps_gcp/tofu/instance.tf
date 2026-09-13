# FREE-TIER BOUNDARY — every value below is a hardcoded literal on purpose,
# NOT a variable. Changing machine_type / region / disk size can produce real
# billing. See README "免费层边界" before touching anything here.
#
# Aligned to the previous live instance (instance-20260317-150306, us-central1-a)
# after the delete-and-recreate exercise: same free-tier region, same Ubuntu 24.04
# image, same http-server/https-server tags. ssh-keys metadata is OPTIONAL — when
# `ssh_public_key` is set it installs a key that survives destroy→apply; empty
# (default) falls back to Console browser SSH like the old instance.
resource "google_compute_instance" "vps" {
  name         = "vps-gcp"
  machine_type = "e2-micro" # free only in us-west1/us-central1/us-east1
  zone         = "us-central1-a"
  tags         = ["http-server", "https-server"]
  depends_on   = [google_project_service.compute]

  metadata = var.ssh_public_key == "" ? {} : {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64" # family; resolves to the current noble image
      size  = 30                                      # 30 GB is the free-tier standard-PD total
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

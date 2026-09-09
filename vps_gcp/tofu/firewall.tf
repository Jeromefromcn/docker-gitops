# Only SSH ingress by default. The instance carries http-server/https-server
# tags (matched to the previous live instance), so the custom VPC also opens
# 80/443 to those tags — mirroring the default-VPC allow-http/allow-https rules
# the old instance relied on.
resource "google_compute_firewall" "ssh" {
  name       = "allow-ssh"
  network    = google_compute_network.main.name
  depends_on = [google_project_service.compute]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "http" {
  name       = "allow-http"
  network    = google_compute_network.main.name
  depends_on = [google_project_service.compute]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_tags   = ["http-server"]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "https" {
  name       = "allow-https"
  network    = google_compute_network.main.name
  depends_on = [google_project_service.compute]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_tags   = ["https-server"]
  source_ranges = ["0.0.0.0/0"]
}

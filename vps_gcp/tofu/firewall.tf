# Only SSH ingress from the public internet. Services on this instance are reached
# over the oracle<->gcp Tailscale mesh instead (see vps_gcp/compose/plans/), which
# needs no inbound firewall rule of its own — it connects out (direct, or via DERP
# relay when direct fails) rather than listening for inbound connections. The
# previous allow-http/allow-https rules were removed 2026-09-13 once the verify
# service moved to a tailscale-only bind; the instance still carries the
# http-server/https-server tags from the old default-VPC setup, they're just
# unmatched by any rule now.
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

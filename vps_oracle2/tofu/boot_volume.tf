# Managed separately from oci_core_instance so it can be resized online
# without touching the instance itself. Started at the image default (47GB,
# VPU=10) because instance.tf's source_details.boot_volume_size_in_gbs was
# missing on first create; resized here to match the old instance (200GB),
# staying on Balanced (VPU=10) — Always Free only covers this performance
# tier, Ultra High Performance (up to VPU=120) is billed per VPU/GB and was
# deliberately not used.
resource "oci_core_boot_volume" "main" {
  compartment_id      = var.compartment_id
  availability_domain = "ZDhe:AP-SINGAPORE-1-AD-1"
  display_name         = "vps-oracle2 (Boot Volume)"
  size_in_gbs           = "200"
  vpus_per_gb           = "10"
}
import {
  to = oci_core_boot_volume.main
  id = oci_core_instance.main.boot_volume_id
}

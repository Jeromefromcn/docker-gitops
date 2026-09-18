# Fresh creation, not imported. Replaces the previous instance
# (instance-20260918-1902, destroyed) which was launched without a public IP
# and was therefore unreachable. Same shape/image/subnet, this time with
# assign_public_ip = true. Shape stays at 2 OCPU/12GB — OCI halved the
# Always-Free Ampere A1.Flex tenancy-wide pool from 4/24 to 2/12 on
# 2026-06-15, so this is already the full free allotment.
resource "oci_core_instance" "main" {
  compartment_id      = var.compartment_id
  availability_domain = "ZDhe:AP-SINGAPORE-1-AD-1"
  shape               = "VM.Standard.A1.Flex"
  display_name        = "vps-oracle2"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type             = "image"
    source_id               = "ocid1.image.oc1.ap-singapore-1.aaaaaaaahgloulxkh22e6cm2ovke5ntoxcnc4e544lr7irepakec75xjlkcq"
    boot_volume_size_in_gbs = "200"
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "vps-oracle2"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }

  lifecycle {
    # metadata is only meaningful at create time — a future apply with
    # ssh_public_key unset/different must not silently change the live key
    # (same guard as vps_gcp/tofu/instance.tf's ssh_public_key handling).
    ignore_changes = [metadata]
  }
}

output "public_ip" {
  value = oci_core_instance.main.public_ip
}

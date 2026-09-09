# InstancePrincipal — this very instance is the identity. Zero long-lived
# credentials on disk, auto-rotated by OCI. Requires a Dynamic Group matching
# this instance's OCID + a policy granting `manage virtual-network-family`
# ONLY (the IAM hard wall — see spec "IAM 硬墙"). The `region` comes from
# .auto.tfvars; the tenancy home region is discoverable in the console.
provider "oci" {
  auth   = "InstancePrincipal"
  region = var.region
}

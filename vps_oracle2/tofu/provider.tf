# ApiKey auth — unlike vps_oracle/tofu (InstancePrincipal, works because tofu
# runs ON that same instance/tenancy), this tenancy is different from the one
# this repo's host lives in, so there is no instance-metadata identity to lean
# on. Needs a dedicated API signing key generated in the vps_oracle2 tenancy's
# own console (Profile -> My profile -> API keys), private key kept OUTSIDE
# this repo (e.g. ~/.oci/vps_oracle2_api_key.pem, chmod 600).
provider "oci" {
  auth             = "ApiKey"
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

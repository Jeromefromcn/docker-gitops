variable "region" {
  description = "Tenancy home region (e.g. ap-tokyo-1); console tenant page."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (console: Profile -> Tenancy)."
  type        = string
}

variable "user_ocid" {
  description = "User OCID of the API key's owner (console: Profile -> My profile)."
  type        = string
}

variable "fingerprint" {
  description = "API signing key fingerprint (shown after adding the key in My profile -> API keys)."
  type        = string
}

variable "private_key_path" {
  description = "Absolute path to the API signing key's private key PEM, kept outside this repo."
  type        = string
}

variable "compartment_id" {
  description = "Compartment holding the resources; usually the root compartment = tenancy_ocid."
  type        = string
}

# Discovered OCIDs — filled during the probe step, stored gitignored.
variable "vcn_ocid" { type = string }
variable "subnet_ocid" { type = string }
variable "internet_gateway_ocid" { type = string }
variable "route_table_ocid" { type = string }
variable "security_list_ocid" { type = string }

variable "ssh_public_key" {
  description = "Public SSH key installed as instance metadata's ssh_authorized_keys. Public key only, not a secret."
  type        = string
}

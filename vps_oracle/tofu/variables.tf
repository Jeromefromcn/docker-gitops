variable "region" {
  description = "Tenancy home region (e.g. ap-tokyo-1); console tenant page."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (console: Profile → Tenancy)."
  type        = string
}

variable "compartment_id" {
  description = "Compartment holding the resources; usually the root compartment = tenancy_ocid."
  type        = string
}

# Discovered OCIDs — filled during the probe (Task 9), stored gitignored.
variable "vcn_ocid" { type = string }
variable "subnet_ocid" { type = string }
variable "internet_gateway_ocid" { type = string }
variable "route_table_ocid" { type = string }
variable "security_list_ocid" { type = string }

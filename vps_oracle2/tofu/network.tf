# OCI network resources imported from the live tenancy ("brownfield" half of
# this root module — the compute instance in instance.tf is the "greenfield"
# half, freshly created).
#
# Factsheet (probed 2026-09-18):
#   - VCN "vcn-20260918-1902"           10.0.0.0/16
#   - subnet "subnet-20260918-1902"     10.0.0.0/24
#   - IGW attached to the VCN
#   - default RT: 1 rule 0.0.0.0/0 -> IGW
#   - default SL: ingress 22/TCP + ICMP (OCI's stock default, unmodified)

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "vcn-20260918-1902"
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "subnet-20260918-1902"
  route_table_id    = oci_core_default_route_table.rt.id
  security_list_ids = [oci_core_default_security_list.sl.id]
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "Internet Gateway vcn-20260918-1902"
}

resource "oci_core_default_route_table" "rt" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "Default Route Table for vcn-20260918-1902"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_default_security_list" "sl" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "Default Security List for vcn-20260918-1902"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6" # TCP 22 (SSH)
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
  ingress_security_rules {
    protocol = "1" # ICMP type 3 code 4 (path MTU discovery)
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }
  ingress_security_rules {
    protocol = "1" # ICMP type 3 (10.0.0.0/16)
    source   = "10.0.0.0/16"
    icmp_options {
      type = 3
      code = -1
    }
  }
}

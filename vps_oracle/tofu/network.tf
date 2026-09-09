# OCI network resources imported from the live tenancy ("brownfield").
# The route table and security list below are the VCN's DEFAULTS — they are
# managed via `oci_core_default_*` resources, which let us adopt the
# auto-created ones instead of recreating them.
#
# Factsheet (Task 9 probe, 2026-09-10):
#   - VCN "Claude code"          10.0.0.0/16
#   - public subnet "public subnet-Claude code"  10.0.0.0/24  (this host lives here)
#   - IGW "Internet gateway-Claude code"
#   - default RT: 1 rule 0.0.0.0/0 -> IGW
#   - default SL: ingress 22/443/39876/80 + ICMP; egress all

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "Claude code"
  dns_label      = "claudecode"
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "public subnet-Claude code"
  route_table_id    = oci_core_default_route_table.rt.id
  security_list_ids = [oci_core_default_security_list.sl.id]
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "Internet gateway-Claude code"
}

resource "oci_core_default_route_table" "rt" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  display_name               = "default route table for Claude code"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_default_security_list" "sl" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  display_name               = "Default Security List for Claude code"

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
    protocol = "1" # ICMP type 3 code 4
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
  ingress_security_rules {
    protocol = "6" # TCP 443
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  ingress_security_rules {
    description = "vless 端口"
    protocol    = "6" # TCP 39876 (vless)
    source      = "0.0.0.0/0"
    tcp_options {
      min = 39876
      max = 39876
    }
  }
  ingress_security_rules {
    protocol = "6" # TCP 80
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
}

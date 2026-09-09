# Declarative import — the `id`s come from .auto.tfvars (gitignored), so no
# OCID literal enters git. The route table / security list are the VCN's
# DEFAULTS (managed alongside the VCN), hence the `oci_core_default_*` types.
import {
  to = oci_core_vcn.main
  id = var.vcn_ocid
}
import {
  to = oci_core_subnet.public
  id = var.subnet_ocid
}
import {
  to = oci_core_internet_gateway.igw
  id = var.internet_gateway_ocid
}
import {
  to = oci_core_default_route_table.rt
  id = var.route_table_ocid
}
import {
  to = oci_core_default_security_list.sl
  id = var.security_list_ocid
}

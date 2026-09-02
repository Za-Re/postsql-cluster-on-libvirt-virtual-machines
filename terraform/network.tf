# Schema note: this provider version (0.9.x) uses typed nested attributes
# (forward/dns/domain/ips as objects), not the classic HCL blocks shown in
# older docs. Confirmed via `terraform providers schema -json`.

resource "libvirt_network" "pg_cluster" {
  name = var.network_name

  forward = {
    mode = "nat"
  }

  domain = {
    name = "pgcluster.internal"
  }

  dns = {
    enable = "yes"
  }

  ips = [
    {
      address = local.network_gateway_ip
      prefix  = local.network_prefix
      dhcp = {
        hosts = [
          for name in var.node_names : {
            ip   = local.node_ips[name]
            mac  = local.node_macs[name]
            name = name
          }
        ]
      }
    }
  ]
}

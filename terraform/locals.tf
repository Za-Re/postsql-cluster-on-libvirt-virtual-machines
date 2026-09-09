locals {
  network_prefix     = tonumber(split("/", var.network_cidr)[1])
  network_gateway_ip = cidrhost(var.network_cidr, 1)

  # .11, .12, .13 — .1 is reserved for the bridge/gateway itself.
  node_ips = {
    for idx, name in var.node_names :
    name => cidrhost(var.network_cidr, idx + 11)
  }

  node_macs = {
    for idx, name in var.node_names :
    name => format("52:54:00:aa:bb:%02x", idx + 1)
  }
}

resource "libvirt_pool" "pg_cluster" {
  name = var.pool_name
  type = "dir"
  target = {
    path = "/var/lib/libvirt/images/${var.pool_name}"
  }
}

resource "libvirt_volume" "base_image" {
  name = "ubuntu-24.04-base"
  pool = libvirt_pool.pg_cluster.name

  create = {
    content = {
      url = var.base_image_url
    }
  }

  target = {
    format = { type = "qcow2" }
  }
}

# Volume with backing store (overlays)
resource "libvirt_volume" "node_disk" {
  for_each = toset(var.node_names)

  name          = "${each.value}-disk.qcow2"
  pool          = libvirt_pool.pg_cluster.name
  capacity      = var.disk_size_gib
  capacity_unit = "GiB"

  backing_store = {
    path   = libvirt_volume.base_image.path
    format = { type = "qcow2" }
  }

  target = {
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "node_init" {
  for_each = toset(var.node_names)

  name = "${each.value}-cloudinit"

  user_data = <<-EOT
    #cloud-config
    hostname: ${each.value}
    fqdn: ${each.value}.pgcluster.internal
    manage_etc_hosts: true
    ssh_pwauth: false
    ssh_authorized_keys:
      - ${trimspace(file(var.ssh_public_key_path))}
    package_update: true
  EOT

  meta_data = yamlencode({
    instance-id    = each.value
    local-hostname = each.value
  })
}

# libvirt_cloudinit_disk only generates the ISO on local disk (see its
# .path output); it must be ingested into the pool as a real volume
# before a domain can attach it — this is the pattern shown in the
# provider's own resource documentation.
resource "libvirt_volume" "node_cloudinit_vol" {
  for_each = toset(var.node_names)

  name = "${each.value}-cloudinit.iso"
  pool = libvirt_pool.pg_cluster.name

  create = {
    content = {
      url = libvirt_cloudinit_disk.node_init[each.value].path
    }
  }

  target = {
    format = { type = "iso" }
  }
}

resource "libvirt_domain" "node" {
  for_each = toset(var.node_names)

  name        = each.value
  type        = "kvm"
  vcpu        = var.vcpu
  memory      = var.memory_mib
  memory_unit = "MiB"
  running     = true

  os = {
    type         = "hvm"
    boot_devices = [{ dev = "hd" }]
  }

  devices = {
    disks = [
      {
        device = "disk"
        source = {
          volume = {
            pool   = libvirt_pool.pg_cluster.name
            volume = libvirt_volume.node_disk[each.value].name
          }
        }
        target = { dev = "vda", bus = "virtio" }
        driver = { name = "qemu", type = "qcow2" }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_pool.pg_cluster.name
            volume = libvirt_volume.node_cloudinit_vol[each.value].name
          }
        }
        target = { dev = "sda", bus = "sata" }
        driver = { name = "qemu", type = "raw" }
      }
    ]

    interfaces = [
      {
        # attaches this VM's NIC to the private pg_cluster network
        source = { network = { network = libvirt_network.pg_cluster.name } }
        mac    = { address = local.node_macs[each.value] }
        model  = { type = "virtio" }
      }
    ]
  }
}

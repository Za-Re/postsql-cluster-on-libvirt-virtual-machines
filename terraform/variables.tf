variable "node_names" {
  description = "Hostnames for the cluster VMs, in order (primary first)."
  type        = list(string)
  default     = ["pg-01", "pg-02", "pg-03"]
}

variable "vcpu" {
  description = "vCPUs per VM."
  type        = number
  default     = 2
}

variable "memory_mib" {
  description = "RAM per VM in MiB."
  type        = number
  # TODO: bump to 2048 (lab minimum) before the graded run — see docs/DECISIONS.md.
  default = 1536
}

variable "disk_size_gib" {
  description = "Root disk size per VM in GiB."
  type        = number
  default     = 12
}

variable "network_cidr" {
  description = "Private subnet for the cluster network."
  type        = string
  default     = "192.168.100.0/24"
}

variable "network_name" {
  description = "libvirt network name."
  type        = string
  default     = "pg-cluster-net"
}

variable "pool_name" {
  description = "libvirt storage pool name."
  type        = string
  default     = "pg-cluster-pool"
}

variable "base_image_url" {
  description = "Ubuntu 24.04 cloud image to clone VM disks from."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ssh_public_key_path" {
  description = "Public key injected into each VM via cloud-init."
  type        = string
  default     = "../ssh_keys/pg_cluster_ed25519.pub"
}

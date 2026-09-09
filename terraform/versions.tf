# See docs/DECISIONS.md for rationale (version pinning, provider choice).

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
  }
}

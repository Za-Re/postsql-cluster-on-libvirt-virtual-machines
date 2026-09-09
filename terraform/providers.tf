# See docs/DECISIONS.md for why qemu:///system over qemu:///session.

provider "libvirt" {
  uri = "qemu:///system"
}

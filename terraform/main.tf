locals {
  inv   = yamldecode(file("${path.module}/../inventory.yaml"))
  pve   = local.inv.proxmox
  net   = local.inv.network
  nodes = local.inv.nodes
  pki   = "${path.module}/../.local/pki"

  # AppRole credentials written by `make openbao-init` (scripts/openbao.sh seed).
  # Missing on the very first apply, when only the OpenBao VM is created.
  approle_file = "${path.module}/../.local/approle.json"
  approle      = fileexists(local.approle_file) ? jsondecode(file(local.approle_file)) : {}

  # OpenBao KV paths each role may read. Must match the policies in scripts/openbao.sh.
  secret_paths = {
    openbao     = ""
    etcd        = "k8s/etcd"
    k8s_control = "k8s/control k8s/join"
    k8s_worker  = "k8s/join"
  }
}

provider "proxmox" {
  endpoint = local.pve.endpoint
  insecure = true # Proxmox ships a self-signed certificate
  # API token comes from the PROXMOX_VE_API_TOKEN environment variable.

  # Uploading cloud-init snippets needs SSH to the Proxmox host (uses your ssh-agent).
  ssh {
    agent    = true
    username = local.pve.ssh_user
  }
}

# Ubuntu 24.04 cloud image, downloaded once onto the Proxmox host.
resource "proxmox_virtual_environment_download_file" "ubuntu" {
  content_type = "import"
  datastore_id = local.pve.file_datastore
  node_name    = local.pve.node
  url          = local.inv.versions.ubuntu_image
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  overwrite    = false # don't re-download (and rebuild VMs) every time Ubuntu refreshes the image
}

# One cloud-init user-data snippet per VM.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = local.nodes
  content_type = "snippets"
  datastore_id = local.pve.file_datastore
  node_name    = local.pve.node

  source_raw {
    file_name = "${each.key}-user-data.yaml"
    data = sensitive(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      hostname       = each.key
      role           = each.value.role
      domain         = local.net.domain
      admin_user     = local.inv.admin.user
      ssh_public_key = local.inv.admin.ssh_public_key
      repo_url       = local.inv.repo.url
      repo_branch    = local.inv.repo.branch
      ca_cert        = file("${local.pki}/homelab-ca.crt")
      bao_addr       = "https://${local.nodes.openbao.ip}:8200"
      role_id        = try(local.approle[each.value.role].role_id, "")
      secret_id      = try(local.approle[each.value.role].secret_id, "")
      secret_paths   = local.secret_paths[each.value.role]
      tls_cert       = each.value.role == "openbao" ? file("${local.pki}/openbao.crt") : ""
      tls_key        = each.value.role == "openbao" ? file("${local.pki}/openbao.key") : ""
    }))
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name            = each.key
  vm_id           = each.value.vmid
  node_name       = local.pve.node
  tags            = ["homelab", each.value.role]
  on_boot         = true
  stop_on_destroy = true

  agent {
    enabled = true # qemu-guest-agent is installed by cloud-init; lets OpenTofu see the VM's IP
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = 0 # no ballooning: Kubernetes and etcd expect fixed memory
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.pve.vm_datastore
    import_from  = proxmox_virtual_environment_download_file.ubuntu.id
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge = local.pve.bridge
  }

  operating_system {
    type = "l26"
  }

  serial_device {} # Ubuntu cloud images expect a serial console

  initialization {
    datastore_id = local.pve.vm_datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.net.prefix}"
        gateway = local.net.gateway
      }
    }

    dns {
      servers = local.net.dns
      domain  = local.net.domain
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
  }

  lifecycle {
    # cloud-init only matters on first boot; after that Puppet owns the VM.
    # Ignoring these stops a template edit or a new image from rebuilding running VMs.
    ignore_changes = [initialization, disk[0].import_from]
  }
}

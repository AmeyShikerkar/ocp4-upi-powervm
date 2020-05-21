################################################################
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Licensed Materials - Property of IBM
#
# ©Copyright IBM Corp. 2020
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################

locals {
    helpernode_vars = {
        cluster_domain  = var.cluster_domain
        cluster_id      = var.cluster_id
        bastion_ip      = var.bastion_ip
        forwarders      = var.dns_forwarders
        gateway_ip      = var.gateway_ip
        netmask         = cidrnetmask(var.cidr)
        broadcast       = cidrhost(var.cidr,-1)
        ipid            = cidrhost(var.cidr, 0)
        pool            = var.allocation_pools[0]

        bootstrap_info  = {
            ip = var.bootstrap_ip,
            mac = var.bootstrap_mac,
            name = "bootstrap.${var.cluster_id}.${var.cluster_domain}"
        }
        master_info     = [ for ix in range(length(var.master_ips)) :
            {
                ip = var.master_ips[ix],
                mac = var.master_macs[ix],
                name = "master-${ix}.${var.cluster_id}.${var.cluster_domain}"
            }
        ]
        worker_info     = [ for ix in range(length(var.worker_ips)) :
            {
                ip = var.worker_ips[ix],
                mac = var.worker_macs[ix],
                name = "worker-${ix}.${var.cluster_id}.${var.cluster_domain}"
            }
        ]

        client_tarball  = var.openshift_client_tarball
        install_tarball = var.openshift_install_tarball
    }

    inventory = {
        bastion_ip      = var.bastion_ip
        bootstrap_ip    = var.bootstrap_ip
        master_ips      = var.master_ips
        worker_ips      = var.worker_ips
    }

    install_vars = {
        cluster_id              = var.cluster_id
        cluster_domain          = var.cluster_domain
        pull_secret             = var.pull_secret
        public_ssh_key          = var.public_key
        log_level               = var.log_level
        release_image_override  = var.release_image_override
    }
}

resource "null_resource" "config" {
    connection {
        type        = "ssh"
        user        = var.rhel_username
        host        = var.bastion_ip
        private_key = var.private_key
        agent       = var.ssh_agent
        timeout     = "15m"
    }

    provisioner "remote-exec" {
        inline = [
            "rm -rf ocp4-helpernode",
            "echo 'Cloning into ocp4-helpernode...'",
            "git clone https://github.com/RedHatOfficial/ocp4-helpernode --quiet",
            "cd ocp4-helpernode && git checkout ${var.helpernode_tag}"
        ]
    }
    provisioner "file" {
        content     = templatefile("${path.module}/templates/helpernode_vars.yaml", local.helpernode_vars)
        destination = "~/ocp4-helpernode/helpernode_vars.yaml"
    }
    provisioner "remote-exec" {
        inline = [
            "echo 'Running ocp4-helpernode playbook...'",
            "cd ocp4-helpernode && ansible-playbook -e @helpernode_vars.yaml tasks/main.yml ${var.ansible_extra_options}"
        ]
    }
}

resource "null_resource" "install" {
    depends_on = [null_resource.config]

    connection {
        type        = "ssh"
        user        = var.rhel_username
        host        = var.bastion_ip
        private_key = var.private_key
        agent       = var.ssh_agent
        timeout     = "15m"
    }

    provisioner "remote-exec" {
        inline = [
            "rm -rf ~/install-playbooks",
        ]
    }

    provisioner "file" {
        source      = "${path.module}/../../ansible"
        destination = "~/install-playbooks"
    }

    provisioner "file" {
        content     = templatefile("${path.module}/templates/inventory", local.inventory)
        destination = "~/install-playbooks/inventory"
    }

    provisioner "file" {
        content     = templatefile("${path.module}/templates/install_vars.yaml", local.install_vars)
        destination = "~/install-playbooks/install_vars.yaml"
    }

    provisioner "remote-exec" {
        inline = [
            "echo 'Running ocp install playbook...'",
            "cd install-playbooks && ansible-playbook  -i inventory -e @install_vars.yaml playbooks/install.yaml ${var.ansible_extra_options}"
        ]
    }
}

resource "null_resource" "setup_oc" {
    depends_on = [null_resource.install]
    connection {
        type        = "ssh"
        user        = var.rhel_username
        host        = var.bastion_ip
        private_key = var.private_key
        agent       = var.ssh_agent
        timeout     = "15m"
    }
    provisioner "remote-exec" {
        inline = [
            "mkdir -p ~/.kube/",
            "cp ~/openstack-upi/auth/kubeconfig ~/.kube/config"
        ]
    }
}

resource "null_resource" "approve_worker_csr" {
    depends_on = [null_resource.setup_oc]
        connection {
        type        = "ssh"
        user        = var.rhel_username
        host        = var.bastion_ip
        private_key = var.private_key
        agent       = var.ssh_agent
        timeout     = "15m"
    }
    provisioner "remote-exec" {
        inline = [
            # Approving all CSR requests until worker nodes are Ready...
            "while [ $(oc get nodes | grep -w worker | grep -w  'Ready' | wc -l) != ${length(var.worker_ips)} ]; do oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs oc adm certificate approve; sleep 30; echo 'Worker not Ready, sleeping for 30s..'; done"
        ]
    }
}

resource "null_resource" "wait_install" {
    depends_on = [null_resource.approve_worker_csr]
    connection {
        type        = "ssh"
        user        = var.rhel_username
        host        = var.bastion_ip
        private_key = var.private_key
        agent       = var.ssh_agent
        timeout     = "15m"
    }
    provisioner "remote-exec" {
        inline = [
            "openshift-install wait-for install-complete --dir ~/openstack-upi --log-level ${var.log_level}"
        ]
    }

    # Force copy kubeconfig file again after install
    provisioner "remote-exec" {
        inline = [
            "\\cp ~/openstack-upi/auth/kubeconfig ~/.kube/config"
        ]
    }
}

resource "null_resource" "patch_image_registry" {
    depends_on = [null_resource.wait_install]
    count       = var.storage_type != "nfs" ? 1 : 0
    connection {
        type        = "ssh"
        user        = var.rhel_username
        host        = var.bastion_ip
        private_key = var.private_key
        agent       = var.ssh_agent
        timeout     = "15m"
    }
    provisioner "file" {
        content = <<EOF
#!/bin/bash

# The image-registry is not always available immediately after the OCP installer
while [ $(oc get configs.imageregistry.operator.openshift.io/cluster | wc -l) == 0 ]; do sleep 30; done
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"emptyDir":{}}, "managementState": "Managed"}}'

EOF
        destination = "/tmp/patch_image_registry.sh"
    }
    provisioner "remote-exec" {
        inline = [
            "chmod +x /tmp/patch_image_registry.sh; bash /tmp/patch_image_registry.sh",
        ]
    }
}

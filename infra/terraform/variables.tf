variable "cluster_name" {
  description = "Name for the VPC, project, droplets and firewall. Also the kubeadm cluster name."
  type        = string
  default     = "teleport-demo"
}

variable "region" {
  description = "DigitalOcean region."
  type        = string
  default     = "sfo3"
}

variable "vpc_cidr" {
  description = "Private network for the nodes. Must not overlap the pod (10.244.0.0/16) or service (10.96.0.0/12) ranges."
  type        = string
  default     = "10.200.0.0/20"
}

variable "image" {
  description = "Droplet image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "control_plane_size" {
  description = "Droplet size for the control plane node. kubeadm needs at least 2 vCPU and 2 GB."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_size" {
  description = "Droplet size for each worker node."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 2
}

variable "ssh_key_name" {
  description = "Name of an SSH key already uploaded to the DigitalOcean account. Its private key must be usable locally for scripts/kubeadm-up.sh."
  type        = string
  default     = "macbook"
}

variable "kubernetes_minor" {
  description = "pkgs.k8s.io channel. kubeadm, kubelet and kubectl install the latest patch of this minor."
  type        = string
  default     = "1.37"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (22) and the Kubernetes API (6443). No default on purpose; scripts/kubeadm-up.sh passes your current public IP."
  type        = list(string)
}

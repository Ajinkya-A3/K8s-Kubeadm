variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "instance_type" {
  type = string
  default = "t3.medium"
}

# variables.tf additions
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cluster_name" {
  type    = string
  default = "kubeadm-lab"
}

variable "tags" {
  type    = map(string)
  default = {
    ManagedBy   = "terraform"
  }
}

variable "worker_count" {
  type = number
  default = 2 
}

variable "key_name" {
  type = string
  default = "ec2"
}
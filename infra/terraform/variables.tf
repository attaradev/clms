variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for resources"
  type        = string
  default     = "clms"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to the instance"
  type        = string
  default     = "0.0.0.0/0"
}

variable "attach_eip" {
  description = "Allocate and attach an Elastic IP to the instance"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ssh_key_name" {
  description = "Existing AWS key pair name to use for SSH"
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "Public key contents to create a new key pair if ssh_key_name is null"
  type        = string
  default     = null
}

variable "remote_path" {
  description = "Deployment path created on the server"
  type        = string
  default     = "/opt/clms"
}

variable "domain_name" {
  description = "Public DNS name (FQDN) for the public entrypoint (Traefik). Used to build https_url. If null, outputs will use public IP."
  type        = string
  default     = null
}

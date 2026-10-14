variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Prefix used for resource names and tags."
  type        = string
  default     = "lb-demo"
}

variable "instance_type" {
  description = "EC2 instance type for the proxy and both backends."
  type        = string
  default     = "t3.micro"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block of the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "backends" {
  description = "Backend instances: fixed private IP and page colour for each."
  type = map(object({
    private_ip = string
    color      = string
  }))
  default = {
    "backend-1" = { private_ip = "10.0.1.11", color = "#2563eb" } # blue
    "backend-2" = { private_ip = "10.0.1.12", color = "#16a34a" } # green
  }
}

variable "backend_port" {
  description = "Port the Flask containers listen on."
  type        = number
  default     = 5000
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH into the proxy. Leave null to auto-detect your current public IP."
  type        = string
  default     = null
}

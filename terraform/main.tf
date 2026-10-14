# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI, published by AWS as a public SSM parameter.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_availability_zones" "available" {
  state = "available"
}

# The caller's public IP, used to restrict SSH when ssh_allowed_cidr is not set.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = coalesce(var.ssh_allowed_cidr, "${chomp(data.http.my_ip.response_body)}/32")
}

# ---------------------------------------------------------------------------
# Network: VPC, public subnet, internet gateway, routing
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true # backends need outbound internet to pull packages and images

  tags = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# Proxy: HTTP from anywhere, SSH only from the operator's IP.
resource "aws_security_group" "proxy" {
  name        = "${var.project_name}-proxy-sg"
  description = "Nginx reverse proxy"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-proxy-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "proxy_http" {
  security_group_id = aws_security_group.proxy.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "proxy_ssh" {
  security_group_id = aws_security_group.proxy.id
  description       = "SSH from operator IP"
  cidr_ipv4         = local.ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "proxy_all" {
  security_group_id = aws_security_group.proxy.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Backends: reachable only from the proxy (app port, and SSH via the proxy as a jump host).
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend-sg"
  description = "Flask backends, reachable only from the proxy"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-backend-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_app" {
  security_group_id            = aws_security_group.backend.id
  description                  = "App traffic from the proxy only"
  referenced_security_group_id = aws_security_group.proxy.id
  ip_protocol                  = "tcp"
  from_port                    = var.backend_port
  to_port                      = var.backend_port
}

resource "aws_vpc_security_group_ingress_rule" "backend_ssh" {
  security_group_id            = aws_security_group.backend.id
  description                  = "SSH via the proxy (jump host)"
  referenced_security_group_id = aws_security_group.proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# SSH key pair (private key saved locally, git-ignored)
# ---------------------------------------------------------------------------

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/${var.project_name}-key.pem"
  file_permission = "0600"
}

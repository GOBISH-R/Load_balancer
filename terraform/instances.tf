# ---------------------------------------------------------------------------
# Backend instances: same Flask image, different identity per instance
# ---------------------------------------------------------------------------

locals {
  backend_src = "${path.module}/../backend"

  # Files shipped to each backend and built into the Docker image there.
  backend_files = {
    for f in [
      "app.py",
      "requirements.txt",
      "Dockerfile",
      "templates/dashboard.html",
      "static/dashboard.css",
      "static/dashboard.js",
    ] : f => file("${local.backend_src}/${f}")
  }
}

resource "aws_instance" "backend" {
  for_each = var.backends

  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = [aws_security_group.backend.id]
  key_name                    = aws_key_pair.main.key_name
  user_data_replace_on_change = true

  # Gzipped: the app files exceed EC2's 16 KB user-data limit uncompressed; cloud-init unpacks it.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/backend-userdata.sh.tftpl", {
    server_name  = each.key
    server_color = each.value.color
    backend_port = var.backend_port
    files        = local.backend_files
  }))

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = "${var.project_name}-${each.key}", Role = "backend" }
}

# ---------------------------------------------------------------------------
# Nginx reverse proxy / load balancer
# ---------------------------------------------------------------------------

locals {
  nginx_conf = templatefile("${path.module}/../nginx/nginx.conf.tftpl", {
    backend1_ip  = aws_instance.backend["backend-1"].private_ip
    backend2_ip  = aws_instance.backend["backend-2"].private_ip
    backend_port = var.backend_port
  })
}

resource "aws_instance" "proxy" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  key_name                    = aws_key_pair.main.key_name
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/proxy-userdata.sh.tftpl", {
    nginx_conf = local.nginx_conf
  })

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = "${var.project_name}-nginx-proxy", Role = "proxy" }
}

# Fixed public IP so the demo URL survives proxy stop/start.
resource "aws_eip" "proxy" {
  domain   = "vpc"
  instance = aws_instance.proxy.id

  tags = { Name = "${var.project_name}-proxy-eip" }

  depends_on = [aws_internet_gateway.main]
}

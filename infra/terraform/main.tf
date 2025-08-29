locals {
  tags = {
    Name    = var.name
    Project = upper(var.name)
    Managed = "terraform"
  }
}

# Resolve latest Ubuntu 24.04 LTS (Noble) AMI via SSM Parameter Store
# See: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters.html
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Default VPC + first public subnet
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "clms" {
  name        = "${var.name}-sg"
  description = "Security group for ${var.name} host"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Key pair (optional)
resource "aws_key_pair" "generated" {
  count      = var.ssh_key_name == null && var.ssh_public_key != null ? 1 : 0
  key_name   = "${var.name}-key"
  public_key = var.ssh_public_key
  tags       = local.tags
}

resource "aws_instance" "clms" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = element(data.aws_subnets.default_public.ids, 0)
  vpc_security_group_ids      = [aws_security_group.clms.id]
  associate_public_ip_address = true
  key_name                    = coalesce(var.ssh_key_name, try(aws_key_pair.generated[0].key_name, null))

  user_data = <<-EOT
              #!/usr/bin/env bash
              set -euo pipefail
              export DEBIAN_FRONTEND=noninteractive

              # Install Docker Engine + compose plugin
              apt-get update -y
              apt-get install -y ca-certificates curl gnupg lsb-release
              install -m 0755 -d /etc/apt/keyrings
              curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
              chmod a+r /etc/apt/keyrings/docker.gpg
              echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
              apt-get update -y
              apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin openssl
              systemctl enable --now docker
              usermod -aG docker ubuntu || true

              # Prepare deploy layout and .env
              REMOTE_PATH="${var.remote_path}"
              mkdir -p "$REMOTE_PATH/back-end" "$REMOTE_PATH/.secrets/tls"
              if [ ! -f "$REMOTE_PATH/back-end/.env" ]; then
                APP_KEY="base64:$(openssl rand -base64 32)"
                cat > "$REMOTE_PATH/back-end/.env" <<ENV
                  APP_NAME=CLMS
                  APP_ENV=production
                  APP_KEY=$APP_KEY
                  APP_DEBUG=false
                  APP_URL=http://localhost

                  LOG_CHANNEL=stack
                  LOG_LEVEL=info

                  DB_CONNECTION=pgsql
                  DB_HOST=db
                  DB_PORT=5432
                  DB_DATABASE=clms
                  DB_USERNAME=clms
                  DB_PASSWORD=clms

                  BROADCAST_DRIVER=log
                  CACHE_DRIVER=file
                  FILESYSTEM_DISK=local
                  QUEUE_CONNECTION=database
                  SESSION_DRIVER=file
                  SESSION_LIFETIME=120

                  REDIS_HOST=redis
                  REDIS_PASSWORD=null
                  REDIS_PORT=6379

                  SANCTUM_STATEFUL_DOMAINS=localhost,localhost:3000
                  SESSION_DOMAIN=localhost
                ENV
                chown ubuntu:ubuntu "$REMOTE_PATH/back-end/.env"
              fi
              EOT

  tags = local.tags
}

resource "aws_eip" "ip" {
  count    = var.attach_eip ? 1 : 0
  instance = aws_instance.clms.id
  domain   = "vpc"
  tags     = local.tags
}

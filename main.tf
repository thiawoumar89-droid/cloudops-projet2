terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "eu-west-3"
  profile = "workload"
}

# On réutilise le VPC par défaut (focus = observabilité, pas réseau)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

# --- Trouver l'AMI Amazon Linux 2023 la plus récente ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# --- Groupe de sécurité : autoriser HTTP (80) depuis Internet ---
resource "aws_security_group" "web" {
  name        = "projet2-web-sg"
  description = "Autorise HTTP entrant"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- L'instance EC2 qui sert une page web ---
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y httpd
              systemctl enable --now httpd
              echo "<h1>Projet 2 - Observabilite - $(hostname)</h1>" > /var/www/html/index.html
              EOF

  tags = {
    Name    = "projet2-web"
    Projet  = "cloudops-projet2"
  }
}

output "ip_publique" {
  value = aws_instance.web.public_ip
}

# --- Security group de l'ALB : HTTP depuis Internet ---
resource "aws_security_group" "alb" {
  name        = "projet2-alb-sg"
  description = "Autorise HTTP entrant vers ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Le Load Balancer ---
resource "aws_lb" "web" {
  name               = "projet2-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

# --- La Target Group + son health check ---
resource "aws_lb_target_group" "web" {
  name     = "projet2-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# --- Rattacher l'instance EC2 à la Target Group ---
resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

# --- Le Listener : écoute sur 80, transmet à la Target Group ---
resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

output "url_alb" {
  value = "http://${aws_lb.web.dns_name}"
}
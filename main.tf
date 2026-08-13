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
  iam_instance_profile   = aws_iam_instance_profile.ec2.name   # <-- NOUVEAU

  user_data_replace_on_change = true

user_data = <<-EOF
#!/bin/bash
dnf install -y httpd amazon-cloudwatch-agent
systemctl enable --now httpd
echo "<h1>Projet 2 - Observabilite - $(hostname)</h1>" > /var/www/html/index.html

cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'CONF'
{
  "metrics": {
    "namespace": "Projet2/EC2",
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": [{"name": "mem_used_percent", "rename": "MemoryUtilization"}],
        "metrics_collection_interval": 60
      },
      "disk": {
        "resources": ["/"],
        "measurement": [{"name": "used_percent", "rename": "DiskUtilization"}],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/httpd/access_log",
            "log_group_name": "/projet2/apache/access",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/httpd/error_log",
            "log_group_name": "/projet2/apache/error",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
CONF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
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

# --- Security group de la base : accessible UNIQUEMENT depuis l'EC2 ---
resource "aws_security_group" "db" {
  name        = "projet2-db-sg"
  description = "Autorise MySQL depuis EC2 uniquement"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL depuis EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- La base de données ---
resource "aws_db_instance" "app" {
  identifier             = "projet2-db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "appdb"
  username               = "admin"
  password               = var.db_password
  vpc_security_group_ids = [aws_security_group.db.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false

  tags = {
    Name   = "projet2-db"
    Projet = "cloudops-projet2"
  }
}

output "db_endpoint" {
  value = aws_db_instance.app.endpoint
}

# --- Rôle IAM pour que l'EC2 puisse pousser des métriques ---
resource "aws_iam_role" "ec2_cloudwatch" {
  name = "projet2-ec2-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# --- Attacher la policy managée par AWS pour l'agent ---
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# --- Aussi utile : permettre la connexion via Session Manager (sans SSH) ---
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- L'instance profile : le "porte-rôle" qu'on attache à l'EC2 ---
resource "aws_iam_instance_profile" "ec2" {
  name = "projet2-ec2-profile"
  role = aws_iam_role.ec2_cloudwatch.name
}

# --- Topic SNS pour recevoir les alertes ---
resource "aws_sns_topic" "alerts" {
  name = "projet2-alerts"
}

# --- Souscription e-mail ---
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "thiawoumar89@gmail.com"
}

# --- Alarme 1 : CPU élevé sur l'EC2 ---
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "projet2-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "CPU EC2 au-dessus de 70% sur 2 periodes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.web.id
  }
}

# --- Alarme 2 : RAM élevée (votre métrique custom !) ---
resource "aws_cloudwatch_metric_alarm" "mem_high" {
  alarm_name          = "projet2-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "Projet2/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Memoire au-dessus de 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.web.id
  }
}

# --- Alarme 3 : erreurs 5xx côté ALB ---
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "projet2-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Plus de 5 erreurs 5xx sur l'ALB"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
  }
}

# --- Alarme 4 : plus aucune cible saine (app DOWN) ---
resource "aws_cloudwatch_metric_alarm" "no_healthy_host" {
  alarm_name          = "projet2-no-healthy-host"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Aucune cible saine derriere l'ALB"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "projet2-observabilite"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EC2 - CPU (%)"
          region = "eu-west-3"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web.id]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EC2 - Memoire & Disque (%)"
          region = "eu-west-3"
          metrics = [
            ["Projet2/EC2", "MemoryUtilization", "InstanceId", aws_instance.web.id],
            ["Projet2/EC2", "DiskUtilization", "InstanceId", aws_instance.web.id]
          ]
          period = 300
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB - Requetes & Latence"
          region = "eu-west-3"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.web.arn_suffix],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.web.arn_suffix, { yAxis = "right" }]
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB - Sante & Erreurs"
          region = "eu-west-3"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.web.arn_suffix, "TargetGroup", aws_lb_target_group.web.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.web.arn_suffix, { yAxis = "right" }]
          ]
          period = 300
          stat   = "Average"
        }
      }
    ]
  })
}

output "dashboard_url" {
  value = "https://eu-west-3.console.aws.amazon.com/cloudwatch/home?region=eu-west-3#dashboards/dashboard/projet2-observabilite"
}
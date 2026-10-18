# --- Data sources for pre-created resources ---

data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  filter {
    name   = "cidr-block"
    values = ["10.0.1.0/24", "10.0.3.0/24"]
  }
}

data "aws_security_group" "ec2" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-ec2_sg"]
  }
}

data "aws_security_group" "http" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-http_sg"]
  }
}

data "aws_security_group" "lb" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-sglb"]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Launch Template ---

resource "aws_launch_template" "main" {
  name          = "${var.name_prefix}-template"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  key_name      = "${var.name_prefix}-keypair"

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [data.aws_security_group.ec2.id, data.aws_security_group.http.id]
  }

  iam_instance_profile {
    name = "${var.name_prefix}-instance_profile"
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd jq
    systemctl enable httpd
    systemctl start httpd

    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

    cat > /var/www/html/index.html <<HTML
    <html>
    <body>
    <h1>Instance ID: $INSTANCE_ID</h1>
    <h1>Private IP: $PRIVATE_IP</h1>
    </body>
    </html>
    HTML
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name      = "${var.name_prefix}-instance"
      Terraform = "true"
      Project   = var.project_tag
    }
  }

  tags = {
    Name      = "${var.name_prefix}-template"
    Terraform = "true"
    Project   = var.project_tag
  }
}

# --- Target Group ---

resource "aws_lb_target_group" "main" {
  name     = "${var.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
  }

  tags = {
    Name      = "${var.name_prefix}-tg"
    Terraform = "true"
    Project   = var.project_tag
  }
}

# --- Application Load Balancer ---

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-loadbalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.aws_security_group.lb.id]
  subnets            = data.aws_subnets.public.ids

  tags = {
    Name      = "${var.name_prefix}-loadbalancer"
    Terraform = "true"
    Project   = var.project_tag
  }
}

# --- Listener ---

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  tags = {
    Terraform = "true"
    Project   = var.project_tag
  }
}

# --- Auto Scaling Group ---

resource "aws_autoscaling_group" "main" {
  name                = "${var.name_prefix}-asg"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 2
  vpc_zone_identifier = data.aws_subnets.public.ids

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [load_balancers, target_group_arns]
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-asg"
    propagate_at_launch = false
  }

  tag {
    key                 = "Terraform"
    value               = "true"
    propagate_at_launch = false
  }

  tag {
    key                 = "Project"
    value               = var.project_tag
    propagate_at_launch = false
  }
}

# --- ASG Attachment to Target Group ---

resource "aws_autoscaling_attachment" "main" {
  autoscaling_group_name = aws_autoscaling_group.main.name
  lb_target_group_arn    = aws_lb_target_group.main.arn
}

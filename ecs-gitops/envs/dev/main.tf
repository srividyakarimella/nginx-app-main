provider "aws" {
  region = "us-east-1"
}

# ------------------------
# VPC
# ------------------------
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# ------------------------
# Subnets
# ------------------------
resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.9.0/24"
  availability_zone = "us-east-1b"
}

# ------------------------
# Internet Gateway
# ------------------------
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# ------------------------
# Route Table & Associations
# ------------------------
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.rt.id
}

# FIX #3: Added association for public_2 so the ALB works across both subnets
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.rt.id
}

# ------------------------
# ALB Security Group (Public)
# ------------------------
resource "aws_security_group" "alb_sg" {
  name   = "alb_sg_v3" # FIX #1: Renamed to break out of the stuck AWS state
  vpc_id = aws_vpc.main.id

  ingress {
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

  # FIX #2: Prevents deletion blockages during deployment updates
  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------
# ECS Tasks Security Group (FIX #4: Dedicated group for tasks)
# ------------------------
resource "aws_security_group" "ecs_tasks_sg" {
  name        = "ecs_tasks_sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Only allows traffic from the ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Required to pull the image from ECR
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------
# ECS Cluster
# ------------------------
resource "aws_ecs_cluster" "cluster" {
  name = "nginx-cluster-dev"
}

# ------------------------
# CloudWatch Logs
# ------------------------
resource "aws_cloudwatch_log_group" "ecs" {
  name = "/ecs/nginx"
}

# ------------------------
# IAM Role
# ------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "nginx-ecs_task_execution_role-unique"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }  
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
# ADD THIS: Full ECR Image Pull Permission Attachment
resource "aws_iam_role_policy_attachment" "ecs_ecr_pull_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ------------------------
# ECS Task Definition
# ------------------------
resource "aws_ecs_task_definition" "task" {
  family                   = "nginx-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "nginx:latest"  # Use public nginx instead
      essential = true
      portMappings = [
        {
          containerPort = 80
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/nginx"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# ------------------------
# ALB
# ------------------------
resource "aws_lb" "alb" {
  name               = "nginx-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

# ------------------------
# Target Group
# ------------------------
resource "aws_lb_target_group" "tg" {
  name        = "nginx-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"


  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200-399"
  }
}

# ------------------------
# Listener (FIXED : Added missing HTTP protocol)
# ------------------------
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# ------------------------
# ECS Service
# ------------------------
resource "aws_ecs_service" "service" {
  name            = "nginx-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_1.id, aws_subnet.public_2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_tasks_sg.id] # FIX #4: Points to new task SG
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "nginx"
    container_port   = 80
  }

  desired_count = 1
}

# ------------------------
# Outputs
# ------------------------
output "alb_dns_name" {
  description = "The public URL of your NGINX application"
  value       = aws_lb.alb.dns_name
}
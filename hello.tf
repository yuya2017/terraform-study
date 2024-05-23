provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# VPCの作成
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
}

# インターネットゲートウェイの作成
resource "aws_internet_gateway" "my_igw" {
  vpc_id = aws_vpc.my_vpc.id
}

# ルートテーブルの作成
resource "aws_route_table" "my_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_igw.id
  }
}

# Subnetの作成
resource "aws_subnet" "my_subnet_a" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "my_subnet_b" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1b"
}

# サブネットをルートテーブルに関連付ける
resource "aws_route_table_association" "my_route_table_association_a" {
  subnet_id      = aws_subnet.my_subnet_a.id
  route_table_id = aws_route_table.my_route_table.id
}

resource "aws_route_table_association" "my_route_table_association_b" {
  subnet_id      = aws_subnet.my_subnet_b.id
  route_table_id = aws_route_table.my_route_table.id
}

# IAM Roleの作成
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "my-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}
# IAM Policyをアタッチ
resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECSクラスターの作成
resource "aws_ecs_cluster" "my_cluster" {
  name = "my-cluster"
}

# ECSタスク定義の作成
resource "aws_ecs_task_definition" "my_task_definition" {
  family                   = "my-task-family"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "my-container"
      image     = "nginx:latest"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
    }
  ])

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
}

# ECSサービスの作成
resource "aws_ecs_service" "my_service" {
  name            = "my-service"
  cluster         = aws_ecs_cluster.my_cluster.id
  task_definition = aws_ecs_task_definition.my_task_definition.arn
  desired_count   = 1

  launch_type = "FARGATE"

  network_configuration {
    assign_public_ip = true
    subnets         = [aws_subnet.my_subnet_a.id, aws_subnet.my_subnet_b.id]
    security_groups = [aws_security_group.ecs_service_sg.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.my_target_group.arn
    container_name   = "my-container"
    container_port   = 80
  }
}

# セキュリティグループの作成
resource "aws_security_group" "ecs_service_sg" {
  name        = "ecs-service-sg"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
    egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ロードバランサー用のセキュリティグループの作成
resource "aws_security_group" "lb_sg" {
  name        = "lb-sg"
  vpc_id      = aws_vpc.my_vpc.id

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
}

# ロードバランサーの作成
resource "aws_lb" "my_lb" {
  name               = "my-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.my_subnet_a.id, aws_subnet.my_subnet_b.id]

  enable_deletion_protection = false
}

# ターゲットグループの作成
resource "aws_lb_target_group" "my_target_group" {
  name        = "my-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.my_vpc.id
  target_type = "ip"
}

# リスナーの作成
resource "aws_lb_listener" "my_listener" {
  load_balancer_arn = aws_lb.my_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.my_target_group.arn
  }
}

// OIDCプロパイダ設定
data "http" "github_actions_openid_configuration" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

data "tls_certificate" "github_actions" {
  url = jsondecode(data.http.github_actions_openid_configuration.body).jwks_uri
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

// Github Actions用IAMロール
resource "aws_iam_role" "github_actions" {
  name = "my-github-actions-role"
  assume_role_policy = templatefile("./assume_role.json",
    {
      account_id  = data.aws_caller_identity.current.account_id,
      github_org  = "yuya2017",
      github_repo = "terraform-study",
    }
  )
}

resource "aws_iam_policy" "github_actions" {
  name   = "my-github-actions-policy"
  policy = templatefile("./administrator.json", {})
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

output "alb_dns_name" {
  value = aws_lb.my_lb.dns_name
}

locals {
  name = "aanuraag-playground"
}

data "template_file" "user_data" {
  template = file("${path.module}/templates/user-data.sh")

  vars = {
    cluster_name = local.name
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_ecs" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-*-amazon-ecs-optimized"]
  }

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  cidr = "172.16.0.0/16"

  name = local.name

  azs  = data.aws_availability_zones.available.names
  private_subnets = [
    "172.16.1.0/24",
    "172.16.2.0/24",
    "172.16.3.0/24"
  ]
  public_subnets = [
    "172.16.4.0/24",
    "172.16.5.0/24",
    "172.16.6.0/24"
  ]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true
}

module "ecs" {
  source = "terraform-aws-modules/ecs/aws"
  version = "~> 3.0"

  name = local.name

  container_insights = true

  capacity_providers = ["FARGATE", "FARGATE_SPOT", aws_ecs_capacity_provider.prov1.name]

  default_capacity_provider_strategy = [{
    capacity_provider = aws_ecs_capacity_provider.prov1.name # "FARGATE_SPOT"
    weight            = "1"
  }]
}

module "ec2_profile" {
  source = "terraform-aws-modules/ecs/aws//modules/ecs-instance-profile"

  name = local.name
}

resource "aws_ecs_capacity_provider" "prov1" {
  name = "${local.name}-prov1"

  auto_scaling_group_provider {
    auto_scaling_group_arn = module.asg.autoscaling_group_arn
    managed_scaling {
      status = "ENABLED"
    }
  }
}

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "alb-sg"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "all-icmp"]
  egress_rules        = ["all-all"]
}

module "ec2_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "ec2-sg"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      source_security_group_id = module.alb_sg.security_group_id
      rule = "all-tcp"
    }
  ]

  ingress_with_self = [
    {
      rule = "all-all"
    }
  ]

  egress_rules        = ["all-all"]
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 4.0"

  name = local.name

  use_lc    = true
  create_lc = true

  image_id                  = data.aws_ami.amazon_linux_ecs.id
  instance_type             = "t3.micro"
  security_groups           = [
    module.ec2_sg.security_group_id
  ]
  iam_instance_profile_name = module.ec2_profile.iam_instance_profile_id
  user_data                 = data.template_file.user_data.rendered

  # Auto scaling group
  vpc_zone_identifier       = module.vpc.private_subnets
  health_check_type         = "EC2"
  min_size                  = 0
  max_size                  = 2
  wait_for_capacity_timeout = 0

  tags = [
    {
      key                 = "Cluster"
      value               = local.name
      propagate_at_launch = true
    },
  ]
}

module "cloudwatch-xray-alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "${local.name}-cw-xray"

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [
    module.alb_sg.security_group_id
  ]

  target_groups = [
    {
      backend_port = 8080
      backend_protocol = "HTTP"
      target_type          = "ip"
      deregistration_delay = 10
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/"
      }
    },
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]
}

resource "aws_cloudwatch_log_group" "playground" {
  name              = local.name
  retention_in_days = 1
}

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "task_policy" {
  statement {
    actions = [
      "aps:RemoteWrite",
      "cloudwatch:ListMetrics",
      "logs:PutLogEvents",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
      "s3:ListAllMyBuckets",
      "xray:BatchGetTraces",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries"
    ]
    resources = [
      "*"
    ]
    effect = "Allow"
  }
}

resource "aws_iam_role" "task_role" {
  name = "${local.name}-sample-app-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name_prefix = "${local.name}-ecstask"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_role" {
  role = aws_iam_role.task_role.name
  policy = data.aws_iam_policy_document.task_policy.json
}

resource "aws_ecs_task_definition" "ecs-cloudwatch-xray" {
  family = "ecs-cloudwatch-xray"

  network_mode = "awsvpc"

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn = aws_iam_role.task_role.arn

  requires_compatibilities = [
    "FARGATE"
  ]

  cpu = 1024
  memory = 2048

  container_definitions = <<EOF
[
  {
    "name": "app",
    "image": "public.ecr.aws/aws-otel-test/aws-otel-java-springboot:a49aa48ce7a7eaece23dff0f773cc9495980746e",
    "cpu": 900,
    "memory": 384,
    "portMappings": [{
      "containerPort": 8080
    }],
    "environment": [
      { "name": "LISTEN_ADDRESS", "value": "0.0.0.0:8080" },
      { "name": "OTEL_METRICS_EXPORTER", "value": "otlp" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-region": "us-west-2",
        "awslogs-group": "${local.name}",
        "awslogs-stream-prefix": "ecs-cloudwatch-xray"
      }
    }
  },
  {
    "name": "otel",
    "image": "public.ecr.aws/o1b1b5c9/otel-collector-ecs",
    "cpu": 55,
    "memory": 128,
    "command": ["--config", "/etc/ecs/ecs-cloudwatch-xray.yaml"],
    "portMappings": [{
      "containerPort": 4317
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-region": "us-west-2",
        "awslogs-group": "${local.name}",
        "awslogs-stream-prefix": "ecs-cloudwatch-xray"
      }
    }
  }
]
EOF
}

resource "aws_ecs_service" "ecs-cloudwatch-xray" {
  name            = "ecs-cloudwatch-xray"
  cluster         = module.ecs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.ecs-cloudwatch-xray.arn

  launch_type = "FARGATE"

  health_check_grace_period_seconds = 3600
  network_configuration {
    subnets = module.vpc.private_subnets
    security_groups = [
      module.ec2_sg.security_group_id
    ]
    assign_public_ip = true
  }

  load_balancer {
    container_name = "app"
    container_port = 8080
    target_group_arn = module.cloudwatch-xray-alb.target_group_arns[0]
  }

  desired_count = 1

  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
}

resource "aws_prometheus_workspace" "test" {
  alias = "${local.name}-amp"
}

module "amp-xray-alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "${local.name}-amp-xray"

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [
    module.alb_sg.security_group_id
  ]

  target_groups = [
    {
      backend_port = 8080
      backend_protocol = "HTTP"
      target_type          = "ip"
      deregistration_delay = 10
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/"
      }
    },
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]
}

resource "aws_ecs_task_definition" "ecs-amp-xray" {
  family = "ecs-amp-xray"

  network_mode = "awsvpc"

  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn = aws_iam_role.task_role.arn

  requires_compatibilities = [
    "FARGATE"
  ]

  cpu = 1024
  memory = 2048

  container_definitions = <<EOF
[
  {
    "name": "app",
    "image": "public.ecr.aws/aws-otel-test/aws-otel-java-springboot:a49aa48ce7a7eaece23dff0f773cc9495980746e",
    "cpu": 900,
    "memory": 384,
    "portMappings": [{
      "containerPort": 8080
    }],
    "environment": [
      { "name": "LISTEN_ADDRESS", "value": "0.0.0.0:8080" },
      { "name": "OTEL_METRICS_EXPORTER", "value": "otlp" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-region": "us-west-2",
        "awslogs-group": "${local.name}",
        "awslogs-stream-prefix": "ecs-amp-xray"
      }
    }
  },
  {
    "name": "otel",
    "image": "public.ecr.aws/o1b1b5c9/otel-collector-ecs",
    "cpu": 55,
    "memory": 128,
    "command": ["--config", "/etc/ecs/ecs-amp-xray.yaml"],
    "environment": [
      { "name": "AWS_PROMETHEUS_ENDPOINT", "value": "${aws_prometheus_workspace.test.prometheus_endpoint}api/v1/remote_write" }
    ],
    "portMappings": [{
      "containerPort": 4317
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-region": "us-west-2",
        "awslogs-group": "${local.name}",
        "awslogs-stream-prefix": "ecs-amp-xray"
      }
    }
  }
]
EOF
}

resource "aws_ecs_service" "ecs-amp-xray" {
  name            = "ecs-amp-xray"
  cluster         = module.ecs.ecs_cluster_id
  task_definition = aws_ecs_task_definition.ecs-amp-xray.arn

  launch_type = "FARGATE"

  health_check_grace_period_seconds = 3600
  network_configuration {
    subnets = module.vpc.private_subnets
    security_groups = [
      module.ec2_sg.security_group_id
    ]
    assign_public_ip = true
  }

  load_balancer {
    container_name = "app"
    container_port = 8080
    target_group_arn = module.amp-xray-alb.target_group_arns[0]
  }

  desired_count = 1

  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
}

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

resource "aws_cloudwatch_log_group" "playground" {
  name              = local.name
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "aanuraag" {
  name              = "aanuraag"
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

module "amp-xray" {
  source = "./modules/test-app"

  name = "amp-xray"
  name_prefix = "aanuraag"
  vpc_id = module.vpc.vpc_id
  vpc_public_subnets = module.vpc.public_subnets
  vpc_private_subnets = module.vpc.private_subnets
  alb_security_group_id = module.alb_sg.security_group_id
  task_security_group_id = module.ec2_sg.security_group_id
  ecs_cluster_id = module.ecs.ecs_cluster_id
  ecs_execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  ecs_task_role_arn = aws_iam_role.task_role.arn
}

module "amp" {
  source = "./modules/test-app"

  name = "amp"
  name_prefix = "aanuraag"
  vpc_id = module.vpc.vpc_id
  vpc_public_subnets = module.vpc.public_subnets
  vpc_private_subnets = module.vpc.private_subnets
  alb_security_group_id = module.alb_sg.security_group_id
  task_security_group_id = module.ec2_sg.security_group_id
  ecs_cluster_id = module.ecs.ecs_cluster_id
  ecs_execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  ecs_task_role_arn = aws_iam_role.task_role.arn
}

module "cloudwatch-xray" {
  source = "./modules/test-app"

  name = "cloudwatch-xray"
  name_prefix = "aanuraag"
  vpc_id = module.vpc.vpc_id
  vpc_public_subnets = module.vpc.public_subnets
  vpc_private_subnets = module.vpc.private_subnets
  alb_security_group_id = module.alb_sg.security_group_id
  task_security_group_id = module.ec2_sg.security_group_id
  ecs_cluster_id = module.ecs.ecs_cluster_id
  ecs_execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  ecs_task_role_arn = aws_iam_role.task_role.arn
}

module "cloudwatch" {
  source = "./modules/test-app"

  name = "cloudwatch"
  name_prefix = "aanuraag"
  vpc_id = module.vpc.vpc_id
  vpc_public_subnets = module.vpc.public_subnets
  vpc_private_subnets = module.vpc.private_subnets
  alb_security_group_id = module.alb_sg.security_group_id
  task_security_group_id = module.ec2_sg.security_group_id
  ecs_cluster_id = module.ecs.ecs_cluster_id
  ecs_execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  ecs_task_role_arn = aws_iam_role.task_role.arn
}

module "xray" {
  source = "./modules/test-app"

  name = "xray"
  name_prefix = "aanuraag"
  vpc_id = module.vpc.vpc_id
  vpc_public_subnets = module.vpc.public_subnets
  vpc_private_subnets = module.vpc.private_subnets
  alb_security_group_id = module.alb_sg.security_group_id
  task_security_group_id = module.ec2_sg.security_group_id
  ecs_cluster_id = module.ecs.ecs_cluster_id
  ecs_execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  ecs_task_role_arn = aws_iam_role.task_role.arn
}

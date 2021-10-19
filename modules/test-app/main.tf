resource "aws_prometheus_workspace" "test" {
  alias = "${var.name_prefix}-${var.name}"
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "${var.name_prefix}-${var.name}"

  load_balancer_type = "application"

  vpc_id             = var.vpc_id
  subnets            = var.vpc_public_subnets
  security_groups    = [
    var.alb_security_group_id
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

resource "aws_ecs_task_definition" "test" {
  family = "${var.name_prefix}-${var.name}"

  network_mode = "awsvpc"

  execution_role_arn = var.ecs_execution_role_arn
  task_role_arn = var.ecs_task_role_arn

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
        "awslogs-group": "${var.name_prefix}",
        "awslogs-stream-prefix": "${var.name}"
      }
    }
  },
  {
    "name": "otel",
    "image": "public.ecr.aws/o1b1b5c9/otel-collector-ecs",
    "cpu": 55,
    "memory": 128,
    "command": ["--config", "/etc/ecs/ecs-${var.name}.yaml"],
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
        "awslogs-group": "${var.name_prefix}",
        "awslogs-stream-prefix": "${var.name}"
      }
    }
  }
]
EOF
}

resource "aws_ecs_service" "test" {
  name            = var.name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.test.arn

  launch_type = "FARGATE"

  health_check_grace_period_seconds = 3600
  network_configuration {
    subnets = var.vpc_private_subnets
    security_groups = [
      var.task_security_group_id
    ]
    assign_public_ip = true
  }

  load_balancer {
    container_name = "app"
    container_port = 8080
    target_group_arn = module.alb.target_group_arns[0]
  }

  desired_count = 1

  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
}

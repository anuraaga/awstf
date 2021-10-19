variable "name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_public_subnets" {
  type = list(string)
}

variable "vpc_private_subnets" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "task_security_group_id" {
  type = string
}

variable "ecs_cluster_id" {
  type = string
}

variable "ecs_execution_role_arn" {
  type = string
}

variable "ecs_task_role_arn" {
  type = string
}


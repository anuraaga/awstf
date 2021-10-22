provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias = "us_east_1"
  region = "us-east-1"
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

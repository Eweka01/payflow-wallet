terraform {
  backend "s3" {
    bucket         = "payflow-tfstate-470439679607"
    key            = "aws/finops/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "payflow-tfstate-lock"
    encrypt        = true
  }
}

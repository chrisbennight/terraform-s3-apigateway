terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.34.0"
    }
  }
}

provider "aws" {
  region = var.aws-region
}

locals {
  mime_types  = jsondecode(file("${path.module}/mime-types.json"))
  bucket_name = replace(var.website, ".", "-")
}

########## S3
resource "aws_s3_bucket" "website_logs" {
  bucket = "${local.bucket_name}-logs"
  acl    = "log-delivery-write"

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  })

  lifecycle {
    ignore_changes = [
    tags["Changed"]]
  }
}

resource "aws_s3_bucket_public_access_block" "website_logs_private" {
  bucket = aws_s3_bucket.website_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


resource "aws_s3_bucket" "website_root" {
  bucket = "${local.bucket_name}-root"

  logging {
    target_bucket = aws_s3_bucket.website_logs.bucket
    target_prefix = "${var.website}/"
  }


  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  })

  lifecycle {
    ignore_changes = [
    tags["Changed"]]
  }
}

resource "aws_s3_bucket_public_access_block" "website_contents_private" {
  bucket = aws_s3_bucket.website_root.id

  block_public_acls       = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  block_public_policy     = true
}

resource "aws_s3_bucket_object" "website_contents" {
  for_each = fileset(var.website-contents-root, "**/*")

  bucket       = aws_s3_bucket.website_root.bucket
  key          = each.value
  source       = "${var.website-contents-root}/${each.value}"
  etag         = filemd5("${var.website-contents-root}/${each.value}")
  content_type = lookup(local.mime_types, regex("\\.[^.]+$", each.value), null)
}


####### API Gateway
resource "aws_api_gateway_domain_name" "api_gateway_domain" {
  domain_name = var.website

  certificate_name        = var.website
  certificate_body        = file(pathexpand(var.ssl-cert-file-path))
  certificate_private_key = file(pathexpand(var.ssl-private-key-file-path))
  certificate_chain       = file(pathexpand(var.ssl-certificate-chain-file-path))


}

resource "aws_api_gateway_rest_api" "website_gateway" {
  name        = var.website
  description = "API for S3 Integration"

  endpoint_configuration {
    types = [
    "REGIONAL"]
  }
}


resource "aws_api_gateway_resource" "gateway_resource" {
  path_part   = "{proxy+}"
  parent_id   = aws_api_gateway_rest_api.website_gateway.root_resource_id
  rest_api_id = aws_api_gateway_rest_api.website_gateway.id
}

resource "aws_api_gateway_method" "gateway_method" {
  rest_api_id   = aws_api_gateway_rest_api.website_gateway.id
  resource_id   = aws_api_gateway_resource.gateway_resource.id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }


}

resource "aws_api_gateway_integration" "gateway_integration" {
  rest_api_id             = aws_api_gateway_rest_api.website_gateway.id
  resource_id             = aws_api_gateway_resource.gateway_resource.id
  http_method             = aws_api_gateway_method.gateway_method.http_method
  integration_http_method = "GET"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.aws-region}:s3:path/${aws_s3_bucket.website_root.bucket}/{proxy}"
  credentials             = aws_iam_role.s3_api_gateyway_role.arn

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }

}

resource "aws_iam_policy" "s3_policy" {
  name        = "s3-policy"
  description = "Policy for allowing all S3 Actions"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${local.bucket_name}-root/*"
        }
    ]
}
EOF
}


resource "aws_iam_role" "s3_api_gateyway_role" {
  name = "s3-api-gateyway-role"


  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
  EOF
}

resource "aws_iam_role_policy_attachment" "s3_policy_attach" {
  role       = aws_iam_role.s3_api_gateyway_role.name
  policy_arn = aws_iam_policy.s3_policy.arn
}


resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.website_gateway.id
  resource_id = aws_api_gateway_resource.gateway_resource.id
  http_method = aws_api_gateway_method.gateway_method.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Timestamp"      = true
    "method.response.header.Content-Length" = true
    "method.response.header.Content-Type"   = true
  }

  response_models = {
    "application/json" = "Empty"
  }

}

resource "aws_api_gateway_integration_response" "integration_response_200" {
  depends_on = [
  aws_api_gateway_integration.gateway_integration]

  rest_api_id = aws_api_gateway_rest_api.website_gateway.id
  resource_id = aws_api_gateway_resource.gateway_resource.id
  http_method = aws_api_gateway_method.gateway_method.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code

  response_parameters = {
    "method.response.header.Timestamp"      = "integration.response.header.Date"
    "method.response.header.Content-Length" = "integration.response.header.Content-Length"
    "method.response.header.Content-Type"   = "integration.response.header.Content-Type"
  }

}

resource "aws_api_gateway_deployment" "s3_api_deployment" {
  depends_on = [
  aws_api_gateway_integration.gateway_integration]
  rest_api_id = aws_api_gateway_rest_api.website_gateway.id
  stage_name  = "prod"
}

resource "aws_api_gateway_base_path_mapping" "website_base" {
  api_id      = aws_api_gateway_rest_api.website_gateway.id
  domain_name = aws_api_gateway_domain_name.api_gateway_domain.domain_name
  stage_name  = aws_api_gateway_deployment.s3_api_deployment.stage_name
}

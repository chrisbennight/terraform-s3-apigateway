variable "aws-region" {
  description = "aws region"
  type = string
}

variable "domain" {
  description = "Domain under which website is hosted"
  type        = string
}

variable "website" {
  description = "Website FQDN"
  type        = string
}

variable "website-contents-root" {
  description = "Website contents"
  type        = string
}

variable "tags" {
  description = "Tags added to resources"
  default     = {}
  type        = map(string)
}
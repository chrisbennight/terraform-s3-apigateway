# What
Terraform script that 
  * Creates a s3 bucket for a website and another for logs for that website
  * Copies the contents of a directory recursively into the content bucket and sets the appropriate content-type
  * Creates an API Gateway with a proxy+ integration with the AWS s3 service to serve the contents of that website

# ToDo
Setup custom domain, upload certs, create route53 dns entry for the webiste
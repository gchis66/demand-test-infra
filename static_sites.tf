# ----- hosted zones (created automatically if you registered in Route 53) -----
data "aws_route53_zone" "site" {
  for_each = var.sites
  name     = each.value
}

# ----- TLS certs (DNS-validated) -----
resource "aws_acm_certificate" "site" {
  for_each                  = var.sites
  domain_name               = each.value
  subject_alternative_names = ["www.${each.value}"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for pair in flatten([
      for site, cert in aws_acm_certificate.site : [
        for dvo in cert.domain_validation_options : {
          key  = "${site}-${dvo.domain_name}", zone = data.aws_route53_zone.site[site].zone_id,
          name = dvo.resource_record_name, type = dvo.resource_record_type, record = dvo.resource_record_value
        }
      ]
    ]) : pair.key => pair
  }
  zone_id = each.value.zone
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "site" {
  for_each        = var.sites
  certificate_arn = aws_acm_certificate.site[each.key].arn
  validation_record_fqdns = [
    for dvo in aws_acm_certificate.site[each.key].domain_validation_options : dvo.resource_record_name
  ]
}

# ----- private S3 buckets -----
resource "aws_s3_bucket" "site" {
  for_each = var.sites
  bucket   = "${each.key}-site-${data.aws_caller_identity.me.account_id}"
}
data "aws_caller_identity" "me" {}

resource "aws_s3_bucket_public_access_block" "site" {
  for_each                = var.sites
  bucket                  = aws_s3_bucket.site[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----- CloudFront with Origin Access Control -----
resource "aws_cloudfront_origin_access_control" "site" {
  for_each                          = var.sites
  name                              = "${each.key}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  for_each            = var.sites
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [each.value, "www.${each.value}"]
  price_class         = "PriceClass_100" # NA + EU edges; plenty for a FL/US test

  origin {
    domain_name              = aws_s3_bucket.site[each.key].bucket_regional_domain_name
    origin_id                = "s3-${each.key}"
    origin_access_control_id = aws_cloudfront_origin_access_control.site[each.key].id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${each.key}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site[each.key].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# S3 only accepts reads from its own distribution
resource "aws_s3_bucket_policy" "site" {
  for_each = var.sites
  bucket   = aws_s3_bucket.site[each.key].id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowCloudFrontOAC",
      Effect    = "Allow",
      Principal = { Service = "cloudfront.amazonaws.com" },
      Action    = "s3:GetObject",
      Resource  = "${aws_s3_bucket.site[each.key].arn}/*",
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site[each.key].arn } }
    }]
  })
}

# ----- DNS: apex + www → CloudFront -----
resource "aws_route53_record" "apex" {
  for_each = var.sites
  zone_id  = data.aws_route53_zone.site[each.key].zone_id
  name     = each.value
  type     = "A"
  alias {
    name                   = aws_cloudfront_distribution.site[each.key].domain_name
    zone_id                = aws_cloudfront_distribution.site[each.key].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  for_each = var.sites
  zone_id  = data.aws_route53_zone.site[each.key].zone_id
  name     = "www.${each.value}"
  type     = "A"
  alias {
    name                   = aws_cloudfront_distribution.site[each.key].domain_name
    zone_id                = aws_cloudfront_distribution.site[each.key].hosted_zone_id
    evaluate_target_health = false
  }
}
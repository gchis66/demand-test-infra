output "track_endpoint" {
  value = "${aws_apigatewayv2_api.track.api_endpoint}/track" # paste into ENDPOINT in both pages
}
output "cloudfront_domains" {
  value = { for k, d in aws_cloudfront_distribution.site : k => d.domain_name }
}
output "site_urls" {
  value = { for k, v in var.sites : k => "https://${v}" }
}
# ---------- identities: both domains + your Gmail (sandbox recipient) ----------
resource "aws_ses_domain_identity" "mail" {
  for_each = var.sites
  domain   = each.value
}

resource "aws_ses_domain_dkim" "mail" {
  for_each = var.sites
  domain   = aws_ses_domain_identity.mail[each.key].domain
}

resource "aws_ses_email_identity" "me" {
  email = var.forward_to_email # <-- your Gmail; verification email arrives on apply
}

# ---------- DNS: DKIM (verifies the domain), MX (receiving), SPF + DMARC ----------
resource "aws_route53_record" "dkim" {
  for_each = {
    for pair in setproduct(keys(var.sites), [0, 1, 2]) :
    "${pair[0]}-${pair[1]}" => { site = pair[0], idx = pair[1] }
  }
  zone_id = data.aws_route53_zone.site[each.value.site].zone_id
  name    = "${aws_ses_domain_dkim.mail[each.value.site].dkim_tokens[each.value.idx]}._domainkey"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.mail[each.value.site].dkim_tokens[each.value.idx]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mx" {
  for_each = var.sites
  zone_id  = data.aws_route53_zone.site[each.key].zone_id
  name     = each.value
  type     = "MX"
  ttl      = 600
  records  = ["10 inbound-smtp.us-east-1.amazonaws.com"]
}

resource "aws_route53_record" "spf" {
  for_each = var.sites
  zone_id  = data.aws_route53_zone.site[each.key].zone_id
  name     = each.value
  type     = "TXT"
  ttl      = 600
  records  = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "dmarc" {
  for_each = var.sites
  zone_id  = data.aws_route53_zone.site[each.key].zone_id
  name     = "_dmarc.${each.value}"
  type     = "TXT"
  ttl      = 600
  records  = ["v=DMARC1; p=none;"]
}

# ---------- inbound storage ----------
resource "aws_s3_bucket" "mail" {
  bucket = "demand-test-mail-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_lifecycle_configuration" "mail" {
  bucket = aws_s3_bucket.mail.id
  rule {
    id     = "expire-raw-mail"
    status = "Enabled"
    filter {
      prefix = "inbox/"
    }
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "mail" {
  bucket = aws_s3_bucket.mail.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowSESPut",
      Effect    = "Allow",
      Principal = { Service = "ses.amazonaws.com" },
      Action    = "s3:PutObject",
      Resource  = "${aws_s3_bucket.mail.arn}/*",
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id } }
    }]
  })
}

# ---------- forwarder lambda ----------
data "archive_file" "forwarder" {
  type        = "zip"
  source_file = "${path.module}/lambda/email_forwarder.py"
  output_path = "${path.module}/lambda/email_forwarder.zip"
}

resource "aws_iam_role" "forwarder" {
  name = "ses-email-forwarder"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "forwarder" {
  name = "ses-email-forwarder-permissions"
  role = aws_iam_role.forwarder.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.mail.arn}/*" },
      { Effect = "Allow", Action = ["ses:SendRawEmail"], Resource = "*" },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }
    ]
  })
}

resource "aws_lambda_function" "forwarder" {
  function_name    = "ses-email-forwarder"
  role             = aws_iam_role.forwarder.arn
  runtime          = "python3.12"
  handler          = "email_forwarder.handler"
  filename         = data.archive_file.forwarder.output_path
  source_code_hash = data.archive_file.forwarder.output_base64sha256
  timeout          = 30
  environment {
    variables = {
      MAIL_BUCKET = aws_s3_bucket.mail.bucket
      MAIL_PREFIX = "inbox/"
      FORWARD_TO  = var.forward_to_email
      DOMAINS     = join(",", values(var.sites))
    }
  }
}

resource "aws_lambda_permission" "ses" {
  statement_id   = "AllowSESInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.forwarder.function_name
  principal      = "ses.amazonaws.com"
  source_account = data.aws_caller_identity.me.account_id
}

# ---------- receipt rules (note: only ONE rule set can be active per account) ----------
resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "demand-test-rules"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "forward" {
  name          = "catchall-forward"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = values(var.sites) # bare domain = catch-all for it
  enabled       = true
  scan_enabled  = true # spam/virus scanning

  s3_action {
    bucket_name       = aws_s3_bucket.mail.bucket
    object_key_prefix = "inbox/"
    position          = 1
  }
  lambda_action {
    function_arn    = aws_lambda_function.forwarder.arn
    invocation_type = "Event"
    position        = 2
  }
  depends_on = [aws_s3_bucket_policy.mail, aws_lambda_permission.ses]
}

# ---------- SMTP credentials for Gmail "Send mail as" ----------
resource "aws_iam_user" "smtp" {
  name = "ses-smtp-gmail"
}

resource "aws_iam_user_policy" "smtp" {
  name = "ses-send-only"
  user = aws_iam_user.smtp.name
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = ["ses:SendRawEmail"], Resource = "*" }]
  })
}

resource "aws_iam_access_key" "smtp" {
  user = aws_iam_user.smtp.name
}

output "smtp_username" {
  value = aws_iam_access_key.smtp.id
}
output "smtp_password" {
  value     = aws_iam_access_key.smtp.ses_smtp_password_v4
  sensitive = true
}
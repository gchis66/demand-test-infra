# ----- DynamoDB -----
resource "aws_dynamodb_table" "events" {
  name         = "funnel_events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"
  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
}

# ----- Lambda -----
data "archive_file" "track" {
  type        = "zip"
  source_file = "${path.module}/lambda/track.py"
  output_path = "${path.module}/lambda/track.zip"
}

resource "aws_iam_role" "track" {
  name = "funnel-track-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "track" {
  name = "funnel-track-permissions"
  role = aws_iam_role.track.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.events.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }
    ]
  })
}

resource "aws_lambda_function" "track" {
  function_name    = "funnel-track"
  role             = aws_iam_role.track.arn
  runtime          = "python3.12"
  handler          = "track.handler"
  filename         = data.archive_file.track.output_path
  source_code_hash = data.archive_file.track.output_base64sha256
  timeout          = 5
  environment {
    variables = { TABLE = aws_dynamodb_table.events.name }
  }
}

# ----- HTTP API -----
resource "aws_apigatewayv2_api" "track" {
  name          = "funnel-track-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = flatten([for d in values(var.sites) : ["https://${d}", "https://www.${d}"]])
    allow_methods = ["POST"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "track" {
  api_id                 = aws_apigatewayv2_api.track.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.track.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "track" {
  api_id    = aws_apigatewayv2_api.track.id
  route_key = "POST /e"
  target    = "integrations/${aws_apigatewayv2_integration.track.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.track.id
  name        = "$default"
  auto_deploy = true
  default_route_settings { # crude flood protection for a public endpoint
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.track.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.track.execution_arn}/*/*"
}
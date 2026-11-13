# demand-test-infra

Terraform that stands up everything needed to test whether a business idea has demand, in one `terraform apply`: a landing page on its own domain, event tracking for the funnel, and a working email address on that domain.

## The problem

Testing an idea should cost a weekend and a few dollars, not a SaaS stack. Each test needs a real domain with HTTPS, a way to see where visitors drop off, and an inbox that looks legitimate when prospects reply. Doing that by hand in the console for every idea is slow and easy to get wrong, so it's one Terraform config keyed by a map of sites.

## What it builds

Per site in `var.sites` (add a line, apply, and only the new site's resources are created):

| Piece | AWS resources |
|---|---|
| Landing page | Private S3 bucket, CloudFront with Origin Access Control (the bucket is never public), ACM certificate validated by DNS, Route 53 apex and www records |
| Funnel tracking | HTTP API Gateway, Lambda (`lambda/track.py`), DynamoDB. Events are allowlisted (page view, section view, trial click, email submit and so on); anything else gets a 400 |
| Email on the domain | SES domain identity with DKIM, SPF and DMARC records, an inbound receipt rule that stores mail in S3 (with a lifecycle rule), and a Lambda (`lambda/email_forwarder.py`) that forwards it to a personal inbox |

## Decisions

- **One map drives everything.** `for_each` over `var.sites` means a second idea is a one-line change, and deferring a site is commenting out a line.
- **Buckets stay private.** CloudFront reads them through Origin Access Control with a bucket policy pinned to the distribution's ARN.
- **Tracking accepts a fixed list of events.** The endpoint is public by nature, so it rejects anything not on the allowlist and caps field sizes, which keeps junk out of the data.
- **`PriceClass_100`.** North America and Europe edges only, which is enough for a US test and cheaper.
- **State and secrets stay local.** `*.tfstate` and `*.tfvars` are gitignored; SMTP credentials exist only in state.

## Use

```bash
terraform init
terraform apply -var forward_to_email=you@example.com
```

Outputs: the tracking endpoint (paste it into `ENDPOINT` in the page), the CloudFront domains, and the site URLs.

| File | What |
|---|---|
| `static_sites.tf` | Buckets, certificates, CloudFront, DNS |
| `tracking.tf` | Event API, Lambda, DynamoDB |
| `email_ses.tf` | SES identity, DNS records, inbound mail and forwarding |
| `lambda/` | The two Python functions |
| `site/` | The landing pages |

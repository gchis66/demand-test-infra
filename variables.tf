variable "sites" {
  description = "site key => apex domain. Start with one; add remitmatch when its name is final — terraform apply will build just the new site's resources."
  type        = map(string)
  default = {
    firstknock = "firstknock.org" # registered
    remitmatch = "remitmatch.org" # registered — comment this line out if you want to defer building the RemitMatch site until its test window
  }
}

variable "forward_to_email" {
  type        = string
  description = "Inbox that receives forwarded mail from the SES receiving pipeline"
}
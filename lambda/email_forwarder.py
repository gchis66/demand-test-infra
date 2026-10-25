import email, os, re
import boto3

s3  = boto3.client("s3")
ses = boto3.client("ses")

BUCKET     = os.environ["MAIL_BUCKET"]
PREFIX     = os.environ.get("MAIL_PREFIX", "inbox/")
FORWARD_TO = os.environ["FORWARD_TO"]            # your Gmail
DOMAINS    = os.environ["DOMAINS"].split(",")     # firstknock.org,remitmatch.org

def handler(event, context):
    msg_id = event["Records"][0]["ses"]["mail"]["messageId"]
    recipients = event["Records"][0]["ses"]["receipt"]["recipients"]

    raw = s3.get_object(Bucket=BUCKET, Key=PREFIX + msg_id)["Body"].read()
    msg = email.message_from_bytes(raw)

    # which of our domains was this sent to? -> becomes the From identity
    rcpt = next((r for r in recipients if any(r.endswith("@" + d) or r.endswith("." + d) for d in DOMAINS)), recipients[0])
    our_domain = next((d for d in DOMAINS if rcpt.endswith(d)), DOMAINS[0])

    orig_from = msg.get("From", "unknown")
    subject   = msg.get("Subject", "(no subject)")

    # SES only sends from verified identities: rewrite From, keep real sender in Reply-To
    sender_name = re.sub(r'[<>"@]', "", orig_from.split("<")[0]).strip() or "Inbound"
    for h in ["From", "Reply-To", "To", "Cc", "Bcc", "Return-Path",
              "DKIM-Signature", "Sender", "Message-ID", "Subject"]:
        if h in msg: del msg[h]
    msg["From"]     = f"{sender_name} via {our_domain} <hello@{our_domain}>"
    msg["Reply-To"] = orig_from
    msg["To"]       = FORWARD_TO
    msg["Subject"]  = subject

    ses.send_raw_email(
        Source=f"hello@{our_domain}",
        Destinations=[FORWARD_TO],
        RawMessage={"Data": msg.as_bytes()},
    )
    return {"status": "forwarded", "messageId": msg_id}
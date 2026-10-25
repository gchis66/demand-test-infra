import base64, json, os, time
import boto3

ddb = boto3.resource("dynamodb").Table(os.environ["TABLE"])

ALLOWED_EVENTS = {"page_view", "section_view", "trial_click", "door_close",
                  "email_submit", "territory_check", "demo_approve_click",
                  "demo_split_click", "profile_complete", "profile_skip"}

def handler(event, context):
    try:
        body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf-8")
        p = json.loads(body)

        name    = str(p.get("event", ""))[:40]
        page    = str(p.get("page", "unknown"))[:30]
        session = str(p.get("session", "nosession"))[:40]
        if name not in ALLOWED_EVENTS:
            return {"statusCode": 400, "body": "bad event"}

        ts = p.get("ts") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        ddb.put_item(Item={
            "pk": f"PAGE#{page}",
            "sk": f"{ts}#{session}#{name}",
            "event": name,
            "session": session,
            "data": json.dumps(p)[:8000],   # full payload incl. UTM + form fields
        })
        return {"statusCode": 200, "body": "ok"}
    except Exception as e:
        print("ERROR", repr(e))
        return {"statusCode": 400, "body": "error"}
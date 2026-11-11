import os
import json
import urllib.request

WEBHOOK_URL = os.environ['https://discord.com/api/webhooks/1570066909695705088/XfrPt9g3n-YkegmU19wbLvTD9WkAJ7xT23rKUhBfsZGPDqtCmC-wAp4Gw5lYwDyVFBAY']

def handler(event, context):
    try:
        # Extract SNS message payload sent by CloudWatch Alarm
        sns_message = json.loads(event['Records'][0]['Sns']['Message'])
        alarm_name = sns_message.get('AlarmName', 'Unknown Alarm')
        new_state = sns_message.get('NewStateValue', 'UNKNOWN')
        reason = sns_message.get('NewStateReason', 'No reason provided')

        # Format Discord message color based on state (Red for ALARM, Green for OK)
        color = 15158332 if new_state == 'ALARM' else 3066993

        payload = {
            "embeds": [{
                "title": f"🚨 AWS CloudWatch Alert: {alarm_name}",
                "description": f"**Status:** {new_state}\n\n**Reason:** {reason}",
                "color": color
            }]
        }

        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(
            WEBHOOK_URL,
            data=data,
            headers={'Content-Type': 'application/json', 'User-Agent': 'AWS-SNS-Discord'}
        )

        with urllib.request.urlopen(req) as response:
            return {'statusCode': response.getcode(), 'body': 'Notification sent successfully'}

    except Exception as e:
        print(f"Error sending message to Discord: {e}")
        return {'statusCode': 500, 'body': str(e)}
}

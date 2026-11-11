import os
import json
import urllib.request


def get_webhook_url():
    webhook_url = os.environ.get('DISCORD_WEBHOOK_URL')
    if not webhook_url:
        raise ValueError('DISCORD_WEBHOOK_URL environment variable is not set')
    return webhook_url


def _extract_sns_message(record):
    if not isinstance(record, dict):
        return {}

    sns_data = record.get('Sns', {})
    if not isinstance(sns_data, dict):
        return {}

    message = sns_data.get('Message', '{}')
    if isinstance(message, str):
        try:
            parsed_message = json.loads(message)
        except json.JSONDecodeError:
            return {}
        if isinstance(parsed_message, dict):
            return parsed_message
        return {}

    if isinstance(message, dict):
        return message

    return {}


def handler(event, context):
    try:
        event = event or {}
        records = event.get('Records', []) if isinstance(event, dict) else []
        if not records:
            return {'statusCode': 400, 'body': 'No SNS records found'}

        sns_message = _extract_sns_message(records[0])
        if not sns_message:
            return {'statusCode': 400, 'body': 'No valid SNS message found'}

        alarm_name = sns_message.get('AlarmName', 'Unknown Alarm')
        new_state = str(sns_message.get('NewStateValue', 'UNKNOWN')).upper()
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
            get_webhook_url(),
            data=data,
            headers={'Content-Type': 'application/json', 'User-Agent': 'AWS-SNS-Discord'}
        )

        with urllib.request.urlopen(req) as response:
            return {'statusCode': response.getcode(), 'body': 'Notification sent successfully'}

    except Exception as e:
        print(f"Error sending message to Discord: {e}")
        return {'statusCode': 500, 'body': str(e)}

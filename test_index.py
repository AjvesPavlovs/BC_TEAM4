import json
import os
import unittest
from unittest.mock import patch

import index


class HandlerTests(unittest.TestCase):
    def setUp(self):
        self.webhook = 'https://example.com/webhook'
        self.original = os.environ.get('DISCORD_WEBHOOK_URL')
        os.environ['DISCORD_WEBHOOK_URL'] = self.webhook

    def tearDown(self):
        if self.original is None:
            os.environ.pop('DISCORD_WEBHOOK_URL', None)
        else:
            os.environ['DISCORD_WEBHOOK_URL'] = self.original

    def test_handler_uses_sns_message_payload(self):
        payload = {
            'AlarmName': 'ec2-high-cpu-alarm',
            'NewStateValue': 'ALARM',
            'NewStateReason': 'CPU crossed threshold'
        }

        class DummyResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_val, exc_tb):
                return False

            def getcode(self):
                return 204

        with patch('urllib.request.urlopen', return_value=DummyResponse()) as mock_urlopen:
            result = index.handler({
                'Records': [{
                    'Sns': {'Message': json.dumps(payload)}
                }]
            }, None)

        self.assertEqual(result['statusCode'], 204)
        self.assertEqual(mock_urlopen.call_count, 1)

    def test_handler_handles_lowercase_state_values(self):
        payload = {
            'AlarmName': 'disk-alarm',
            'NewStateValue': 'ok',
            'NewStateReason': 'Recovered'
        }

        class DummyResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_val, exc_tb):
                return False

            def getcode(self):
                return 204

        with patch('urllib.request.urlopen', return_value=DummyResponse()):
            result = index.handler({
                'Records': [{
                    'Sns': {'Message': json.dumps(payload)}
                }]
            }, None)

        self.assertEqual(result['statusCode'], 204)

    def test_handler_rejects_invalid_records(self):
        result = index.handler({'Records': [{'Sns': {'Message': 'not json'}}]}, None)
        self.assertEqual(result['statusCode'], 400)
        self.assertIn('No valid SNS message found', result['body'])


if __name__ == '__main__':
    unittest.main()

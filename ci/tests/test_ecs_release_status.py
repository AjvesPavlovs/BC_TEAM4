"""Offline mock tests for the read-only ECS monitor: python3 -m unittest discover -s ci/tests -p test_ecs_release_status.py"""
import contextlib
from io import StringIO
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ecs_release_status as m

CLUSTER = "slice-sip-ecs"
SERVICE = "slice-sip-app"
DEPLOY_ARN = "arn:aws:ecs:eu-west-1:123456789012:service-deployment/slice-sip-ecs/slice-sip-app/abc"
TG1 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/blue/123"
TG2 = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/green/456"


def response_for(state="SUCCESSFUL", healthy=True):
    def fake_aws(region, service, action, *args):
        assert (service, action) in {
            ("ecs", "describe-clusters"), ("ecs", "describe-services"),
            ("ecs", "list-service-deployments"), ("ecs", "describe-service-deployments"),
            ("elbv2", "describe-target-health"),
        }
        if action == "describe-clusters":
            return {"clusters": [{"clusterName": CLUSTER, "status": "ACTIVE"}]}
        if action == "describe-services":
            return {"services": [{"serviceName": SERVICE, "status": "ACTIVE", "desiredCount": 1,
                "runningCount": 1, "pendingCount": 0, "deploymentConfiguration": {"strategy": "BLUE_GREEN"},
                "loadBalancers": [{"targetGroupArn": TG1,
                    "advancedConfiguration": {"alternateTargetGroupArn": TG2}}]}]}
        if action == "list-service-deployments":
            return {"serviceDeployments": [{"serviceDeploymentArn": DEPLOY_ARN,
                "createdAt": "2026-11-13T08:00:00Z", "status": state}]}
        if action == "describe-service-deployments":
            return {"serviceDeployments": [{"status": state, "lifecycleStage": "BAKE_TIME"}]}
        if action == "describe-target-health":
            return {"TargetHealthDescriptions": [{"TargetHealth": {"State": "healthy"}}]} if healthy and TG1 in args else {"TargetHealthDescriptions": []}
        raise AssertionError(action)
    return fake_aws


class EcsReleaseTests(unittest.TestCase):
    def execute(self, fake):
        with patch.object(m, "aws", side_effect=fake), contextlib.redirect_stdout(StringIO()):
            return m.run("eu-west-1", CLUSTER, SERVICE)

    def test_success(self):
        self.assertEqual(self.execute(response_for()), 0)

    def test_deploying(self):
        self.assertEqual(self.execute(response_for("IN_PROGRESS")), 2)

    def test_rollback(self):
        self.assertEqual(self.execute(response_for("ROLLBACK_SUCCESSFUL")), 3)

    def test_without_healthy_targets(self):
        self.assertEqual(self.execute(response_for(healthy=False)), 2)

    def test_missing_cluster_is_explicitly_allowed_only_for_preflight(self):
        def absent(region, service, action, *args):
            return {"clusters": []}
        with patch.object(m, "aws", side_effect=absent), contextlib.redirect_stdout(StringIO()):
            self.assertEqual(m.run("eu-west-1", CLUSTER, SERVICE), 2)
            self.assertEqual(m.run("eu-west-1", CLUSTER, SERVICE, allow_missing=True), 0)

    def test_allowlist_rejects_mutation(self):
        with self.assertRaises(m.StatusError):
            m.aws("eu-west-1", "ecs", "update-service", "--cluster", CLUSTER)


if __name__ == "__main__":
    unittest.main()

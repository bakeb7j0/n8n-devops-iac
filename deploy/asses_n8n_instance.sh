#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

USER="$1"
SERVICE_NAME="${USER}-n8n-http-service"
TG_NAME="tg-${USER}"
PATH_PREFIX="/${USER}/"

source ./n8n.env

# ECS Service Status
echo "=== ECS Service Status ==="
SERVICE_STATUS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION" --profile "$PROFILE" \
  --query 'services[0].{Status:status,RunningCount:runningCount,DesiredCount:desiredCount}' --output json)

echo "$SERVICE_STATUS"

RUNNING=$(echo "$SERVICE_STATUS" | jq -r '.RunningCount')
DESIRED=$(echo "$SERVICE_STATUS" | jq -r '.DesiredCount')

# Target Health
echo "=== Target Health ==="
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --region "$REGION" --profile "$PROFILE" \
  --query 'TargetGroups[0].TargetGroupArn' --output text || echo "NONE")

if [ "$TG_ARN" == "NONE" ]; then
  echo "Target group $TG_NAME not found"
else
  TARGET_HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" --profile "$PROFILE" \
    --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Description:TargetHealth.Description}' \
    --output json)
  echo "$TARGET_HEALTH"
fi

# Connectivity Test
echo "=== Connectivity Test ==="
ALB_AUTH=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" --region "$REGION" --profile "$PROFILE" \
  --query 'LoadBalancers[0].DNSName' --output text)

if [ -z "$ALB_AUTH" ] || [ "$ALB_AUTH" == "None" ]; then
  echo "Cannot determine ALB DNS. Check ALB exists."
else
  echo "Trying HTTP GET on http://$ALB_AUTH${PATH_PREFIX}"
  echo ""
  curl -Iv --max-time 10 "http://$ALB_AUTH${PATH_PREFIX}" || echo "Connection failed"
fi

# Diagnostics
echo
echo "=== Diagnostics & Suggestions ==="

if (( RUNNING < 1 )); then
  echo "- ECS task is not running. Check if container is crashing or stuck in PENDING."
fi

if [ "$TG_ARN" != "NONE" ]; then
  UNHEALTHY_COUNT=$(echo "$TARGET_HEALTH" | jq -r '.[] | select(.State!="healthy") | .Id' | wc -l)
  if (( UNHEALTHY_COUNT > 0 )); then
    echo "- One or more targets are unhealthy. Logs, Paths, and HealthCheck config may need review."
  fi
fi

echo "- Verify your health check path matches a valid, 200-response endpoint (e.g., '/healthz')."
echo "- If curl times out, double-check your security groups and network reachability."
echo "- If listener rule or target group are misconfigured, re-run deploy_user_service.sh to reset."

echo "=== End of report ==="


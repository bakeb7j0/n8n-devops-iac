#!/bin/bash
set -euo pipefail
source ./n8n.env

SERVICE_NAME="brbaker-n8n-http-service"
TG_NAME="tg-brbaker"
PATH_PATTERN="/brbaker/*"

# --- Cleanup Phase ---

# 1. Delete ECS service if exists
if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
     --region "$REGION" --profile "$PROFILE" | jq -e '.services[]? | select(.status != "INACTIVE")' >/dev/null; then
  aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" --force \
    --region "$REGION" --profile "$PROFILE"
  echo "Deleted existing ECS service"
  sleep 30  # allow draining
fi

# 2. Delete listener rule for path pattern
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text \
  --region "$REGION" --profile "$PROFILE")
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text \
  --region "$REGION" --profile "$PROFILE")
RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?Conditions[0].Values[0]=='$PATH_PATTERN'].RuleArn" --output text \
  --region "$REGION" --profile "$PROFILE" || echo "")
if [[ -n "$RULE_ARN" && "$RULE_ARN" != "None" ]]; then
  aws elbv2 delete-rule --rule-arn "$RULE_ARN" \
    --region "$REGION" --profile "$PROFILE"
  echo "Deleted listener rule for $PATH_PATTERN"
fi

# 3. Delete target group if exists
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text \
  --region "$REGION" --profile "$PROFILE" || echo "")
if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN" \
    --region "$REGION" --profile "$PROFILE"
  echo "Deleted old target group $TG_NAME"
fi

# --- Deployment Phase ---

# 4. Create target group
TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 5678 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path / \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 3 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200-499 \
  --region "$REGION" --profile "$PROFILE" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "Created target group: $TG_ARN"

# Update env with TG_ARN
sed -i "/^TG_ARN=/d" ./n8n.env
echo "TG_ARN=$TG_ARN" >> ./n8n.env

# 5. Create listener rule
aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions Field=path-pattern,Values="$PATH_PATTERN" \
  --actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region "$REGION" --profile "$PROFILE"
echo "Listener rule for $PATH_PATTERN added"

# 6. Deploy ECS service
aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --desired-count 1 \
  --service-name "$SERVICE_NAME" \
  --task-definition "n8n-brbaker" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID_A,$SUBNET_ID_B],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=n8n,containerPort=5678" \
  --region "$REGION" --profile "$PROFILE"
echo "ECS service deployed for brbaker (HTTP)"
echo "Access your service here:"
echo "http://$ALB_DNS/$USER_PATH"


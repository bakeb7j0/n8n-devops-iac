#!/bin/bash
set -euo pipefail

# Load environment variables
source ./n8n.env

# Define service-specific variables
SERVICE_NAME="brbaker-n8n-http-service"
CONTAINER_NAME="n8n"
CONTAINER_PORT=5678
PATH_PATTERN="/brbaker/*"
TARGET_GROUP_NAME="tg-brbaker"
DESIRED_COUNT=1

# Function to update n8n.env
update_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^$key=" n8n.env; then
    sed -i "s|^$key=.*|$key=$value|" n8n.env
  else
    echo "$key=$value" >> n8n.env
  fi
}

# Delete old listener rule if exists
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text) \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "Listeners[0].ListenerArn" \
  --output text)

EXISTING_RULE_ARN=$(aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "Rules[?Conditions[?Field=='path-pattern' && Values[0]=='$PATH_PATTERN']].RuleArn | [0]" \
  --output text)

if [ "$EXISTING_RULE_ARN" != "None" ]; then
  aws elbv2 delete-rule \
    --rule-arn "$EXISTING_RULE_ARN" \
    --region "$REGION" \
    --profile "$PROFILE"
  echo "Deleted listener rule for $PATH_PATTERN"
fi

# Delete old target group if exists
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TARGET_GROUP_NAME" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text || true)

if [ -n "$TG_ARN" ]; then
  aws elbv2 delete-target-group \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" \
    --profile "$PROFILE" || true
  echo "Deleted old target group $TARGET_GROUP_NAME"
fi

# Create new target group
TG_ARN=$(aws elbv2 create-target-group \
  --name "$TARGET_GROUP_NAME" \
  --protocol HTTP \
  --port "$CONTAINER_PORT" \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)
echo "Created target group: $TG_ARN"
update_env_var "TG_ARN" "$TG_ARN"

# Create listener rule
aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions Field=path-pattern,Values="$PATH_PATTERN" \
  --actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region "$REGION" \
  --profile "$PROFILE"
echo "Listener rule for $PATH_PATTERN added"

# Deploy ECS service
aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition "n8n-brbaker" \
  --desired-count "$DESIRED_COUNT" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID_A,$SUBNET_ID_B],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=$CONTAINER_PORT" \
  --region "$REGION" \
  --profile "$PROFILE"
echo "ECS service deployed for brbaker (HTTP)"
echo "Access your service here: http://$ALB_DNS$PATH_PATTERN"


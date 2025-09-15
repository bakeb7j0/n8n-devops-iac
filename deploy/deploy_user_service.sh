#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

USER="$1"
SERVICE_NAME="${USER}-n8n-http-service"
TARGET_GROUP_NAME="tg-${USER}"
PATH_PATTERN="/${USER}/*"

source ./n8n.env

# Helper to update env file
update_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^$key=" n8n.env; then
    sed -i "s|^$key=.*|$key=$value|" n8n.env
  else
    echo "$key=$value" >> n8n.env
  fi
}

echo "Deploy: User=$USER, Service=$SERVICE_NAME"

# Grab ALB and Listener ARNs
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --region "$REGION" --profile "$PROFILE" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text)

# Delete existing listener rule
RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Rules[?contains(Conditions[0].Values[0],'$PATH_PATTERN')].RuleArn | [0]" \
  --output text || echo "")
if [[ -n "$RULE_ARN" && "$RULE_ARN" != "None" ]]; then
  aws elbv2 delete-rule --rule-arn "$RULE_ARN" \
    --region "$REGION" --profile "$PROFILE"
  echo "Deleted listener rule for $PATH_PATTERN"
fi

# Delete old target group if it's no longer used
EXISTING_TG=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" \
  --region "$REGION" --profile "$PROFILE" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "")
if [[ -n "$EXISTING_TG" && "$EXISTING_TG" != "None" ]]; then
  IN_USE=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --region "$REGION" --profile "$PROFILE" \
    --query "Rules[?Actions[?TargetGroupArn=='$EXISTING_TG']] | length(@)" --output text)
  if [[ "$IN_USE" -eq 0 ]]; then
    aws elbv2 delete-target-group --target-group-arn "$EXISTING_TG" \
      --region "$REGION" --profile "$PROFILE" || true
    echo "Deleted old target group $TARGET_GROUP_NAME"
  else
    echo "Target group still in use; skipping deletion"
  fi
fi

# Create or reuse target group
TG_ARN=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" \
  --region "$REGION" --profile "$PROFILE" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "")
if [[ -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "$TARGET_GROUP_NAME" --protocol HTTP --port 5678 \
    --vpc-id "$VPC_ID" --target-type ip --health-check-path "/" \
    --region "$REGION" --profile "$PROFILE" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  echo "Created target group $TARGET_GROUP_NAME"
else
  echo "Reusing target group $TARGET_GROUP_NAME"
fi
update_env_var "TG_ARN" "$TG_ARN"

# Add listener rule back
aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions Field=path-pattern,Values="$PATH_PATTERN" \
  --actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region "$REGION" --profile "$PROFILE" || echo "Rule may already exist"
echo "Listener rule for $PATH_PATTERN ensured"

# Handle ECS service status
STATUS=$(aws ecs describe-services --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" --region "$REGION" --profile "$PROFILE" \
  --query "services[0].status" --output text || echo "NONE")

if [[ "$STATUS" == "ACTIVE" ]]; then
  echo "Service is ACTIVE — draining old tasks"
  aws ecs update-service --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" --desired-count 0 \
    --region "$REGION" --profile "$PROFILE"
  echo "Waiting for service to become INACTIVE..."
  aws ecs wait services-inactive --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" --region "$REGION" --profile "$PROFILE"
elif [[ "$STATUS" == "DRAINING" ]]; then
  echo "Service is DRAINING — waiting for inactive"
  aws ecs wait services-inactive --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" --region "$REGION" --profile "$PROFILE"
elif [[ "$STATUS" != "NONE" ]]; then
  echo "Service state is $STATUS — waiting"
  aws ecs wait services-inactive --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" --region "$REGION" --profile "$PROFILE"
fi

# Create new service
aws ecs create-service \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --task-definition "n8n-$USER" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID_A,$SUBNET_ID_B],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=n8n,containerPort=5678" \
  --region "$REGION" --profile "$PROFILE"
echo "Created ECS service $SERVICE_NAME — waiting to stabilize..."

# Show countdown while waiting
for i in {60..1}; do
  echo -ne "Waiting for service stability: $i\033[0K\r"
  sleep 1
done
echo ""

# Final check for stability
aws ecs wait services-stable --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" --region "$REGION" --profile "$PROFILE"
echo "Service is stable and tasks are running."

# Update ALB_DNS for convenience
ALB_DNS_L=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --region "$REGION" --profile "$PROFILE" \
  --query "LoadBalancers[0].DNSName" --output text)
update_env_var "ALB_DNS" "$ALB_DNS_L"

echo "Deployment complete! Access via: http://$ALB_DNS_L/${USER}/"


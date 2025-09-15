#!/usr/bin/env bash
set -euo pipefail
USER_SLUG="${1:?Usage: $0 <user-slug> [--region us-east-1] [--profile prof]}"
AWS_REGION="us-east-1"; AWS_PROFILE="default"
shift || true
while [[ $# -gt 0 ]]; do case "$1" in --region) AWS_REGION="$2"; shift 2;; --profile) AWS_PROFILE="$2"; shift 2;;
	*) echo "Unknown: $1" >&2; exit 2;; esac; done
		need(){ command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }; need aws; need jq
			say(){ printf "\n=== %s ===\n" "$*"; }
			CL=$(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE"|jq -r '.clusterArns[]'|grep -i n8n|head -n1|awk -F/ '{print $NF}')
			SV=$(aws ecs list-services --cluster "$CL" --region "$AWS_REGION" --profile "$AWS_PROFILE"|jq -r '.serviceArns[]'|grep -i "$USER_SLUG"|head -n1|awk -F/ '{print $NF}')
			say "Cluster: $CL  Service: $SV"
			TG=$(aws ecs describe-services --cluster "$CL" --services "$SV" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				  --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
			LB=$(aws elbv2 describe-target-groups --target-group-arns "$TG" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				  --query 'TargetGroups[0].LoadBalancerArns[0]' --output text)
			DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				  --query 'LoadBalancers[0].DNSName' --output text)
			BASE="http://${DNS}/${USER_SLUG}"; PATHP="/${USER_SLUG}/"
			TD_ARN=$(aws ecs describe-services --cluster "$CL" --services "$SV" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
				  --query 'services[0].taskDefinition' --output text)
							  TD=$(aws ecs describe-task-definition --task-definition "$TD_ARN" --region "$AWS_REGION" --profile "$AWS_PROFILE")
							  up(){ jq --arg k "$1" --arg v "$2" '.taskDefinition.containerDefinitions |= (map(if .name=="n8n"
							  then .environment = ([(.environment // [])[] | select(.name!=$k)] + [{"name":$k,"value":$v}]) else . end))'; }
								  logs(){ jq --arg r "$AWS_REGION" --arg g "/ecs/n8n-'"$USER_SLUG"'" '
									  .taskDefinition.containerDefinitions |= (map(if .name=="n8n"
								  then (.logConfiguration.logDriver="awslogs") |
									       (.logConfiguration.options["awslogs-group"]=$g) |
									            (.logConfiguration.options["awslogs-region"]=$r) |
										         (.logConfiguration.options["awslogs-stream-prefix"]="ecs")
																		   else . end))'; }
																			   clean(){ jq 'walk(if type=="object" then with_entries(select(.value!=null)) else . end)'; }
																			   NEW="$TD"; NEW=$(printf '%s' "$NEW"|up N8N_PATH "$PATHP")
																			   NEW=$(printf '%s' "$NEW"|up N8N_EDITOR_BASE_URL "$BASE/")
																			   NEW=$(printf '%s' "$NEW"|up WEBHOOK_URL "$BASE/")
																			   NEW=$(printf '%s' "$NEW"|up N8N_HOST "0.0.0.0")
																			   NEW=$(printf '%s' "$NEW"|up N8N_PORT "5678")
																			   NEW=$(printf '%s' "$NEW"|up N8N_PROTOCOL "http")
																			   NEW=$(printf '%s' "$NEW"|logs)
																			   REG=$(printf '%s' "$NEW"|jq '{family:.taskDefinition.family,taskRoleArn:.taskDefinition.taskRoleArn,executionRoleArn:.taskDefinition.executionRoleArn,networkMode:.taskDefinition.networkMode,containerDefinitions:.taskDefinition.containerDefinitions,volumes:.taskDefinition.volumes,placementConstraints:.taskDefinition.placementConstraints,requiresCompatibilities:.taskDefinition.requiresCompatibilities,cpu:.taskDefinition.cpu,memory:.taskDefinition.memory,runtimePlatform:.taskDefinition.runtimePlatform,ephemeralStorage:.taskDefinition.ephemeralStorage}'|clean)
																			   aws logs create-log-group --log-group-name "/ecs/n8n-${USER_SLUG}" --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
																			   aws logs put-retention-policy --log-group-name "/ecs/n8n-${USER_SLUG}" --retention-in-days 14 --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
																			   say "Registering new task def"; NEW_TD=$(aws ecs register-task-definition --cli-input-json "$REG" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'taskDefinition.taskDefinitionArn' --output text)
																			   say "Rolling service"; aws ecs update-service --cluster "$CL" --service "$SV" --task-definition "$NEW_TD" --force-new-deployment --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
																			   aws ecs wait services-stable --cluster "$CL" --services "$SV" --region "$AWS_REGION" --profile "$AWS_PROFILE"
																			   echo "OK -> ${BASE}"

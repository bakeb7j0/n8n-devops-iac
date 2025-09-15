#!/usr/bin/env bash
set -euo pipefail

USER_SLUG="${1:-brbaker}"; shift || true
AWS_REGION="us-east-1"
AWS_PROFILE="default"
while [[ $# -gt 0 ]]; do
	  case "$1" in
		      --region)  AWS_REGION="$2"; shift 2 ;;
		          --profile) AWS_PROFILE="$2"; shift 2 ;;
			      *) echo "Unknown arg: $1" >&2; exit 2 ;;
			        esac
			done

			need(){ command -v "$1" >/dev/null || { echo "Missing: $1"; exit 1; }; }
			need aws; need jq; need curl

			say(){ printf "\n=== %s ===\n" "$*"; }

			# Sanitize to CloudWatch-compatible chars: A-Za-z0-9 _ - / .
			sanitize_log_group() {
				  printf "%s" "$1" | sed -E 's/[^A-Za-z0-9_\/\.\-]/-/g'
			  }

			  # jq helpers
			  upsert_env_n8n() {
				    local k="$1" v="$2"
				      jq --arg k "$k" --arg v "$v" '
				          .taskDefinition.containerDefinitions |=
					      (map(if .name=="n8n"
					               then .environment = (
							                       [(.environment // [])[] | select(.name!=$k)] + [{"name":$k,"value":$v}]
									                     )
											              else . end))
													        '
													}

													ensure_logs_n8n() {
														  local lg="$1"
														    jq --arg region "$AWS_REGION" --arg lg "$lg" '
														        .taskDefinition.containerDefinitions |=
															    (map(if .name=="n8n"
															             then
																	                (if (.logConfiguration|type!="object") or (.logConfiguration.logDriver != "awslogs")
																			            then .logConfiguration = {
																					                       logDriver: "awslogs",
																							                          options: {
																										                       "awslogs-group": $lg,
																												                            "awslogs-region": $region,
																															                         "awslogs-stream-prefix": "ecs"
																																		                    }
																																				                     }
																																						                 else
																																									               # Ensure values are exactly what we expect (idempotent upsert)
																																										                     (.logConfiguration.options["awslogs-group"] = $lg) |
																																													                   (.logConfiguration.options["awslogs-region"] = $region) |
																																															                 (.logConfiguration.options["awslogs-stream-prefix"] = "ecs")
																																												                 end)
																																														          else . end))
																																																    '
																																															    }

																																															    # Remove every null recursively; AWS rejects nulls in register payloads
																																															    strip_nulls() {
																																																      jq 'walk(if type=="object" then with_entries(select(.value != null)) else . end)'
																																															      }

																																															      say "Discover cluster/service"
																																															      CLUSTER=$(aws ecs list-clusters --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																        | jq -r '.clusterArns[]' | grep -i n8n | head -n1 | awk -F/ '{print $NF}')
																																															      SERVICE=$(aws ecs list-services --cluster "$CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																        | jq -r '.serviceArns[]' | grep -i "$USER_SLUG" | head -n1 | awk -F/ '{print $NF}')
																																															      [[ -n "$CLUSTER" && -n "$SERVICE" ]] || { echo "Cluster/Service not found"; exit 3; }
																																															      echo "Cluster: $CLUSTER"
																																															      echo "Service: $SERVICE"

																																															      say "Get target group + ALB DNS"
																																															      TG_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
																																																        --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																	  --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
																																															      LB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
																																																        --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																	  --query 'TargetGroups[0].LoadBalancerArns[0]' --output text)
																																															      ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
																																																        --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																	  --query 'LoadBalancers[0].DNSName' --output text)
																																															      [[ "$ALB_DNS" != "None" ]] || { echo "ALB DNS not found"; exit 4; }
																																															      echo "ALB DNS: $ALB_DNS"

																																															      BASE_URL="http://${ALB_DNS}/${USER_SLUG}"
																																															      N8N_PATH="/${USER_SLUG}/"

																																															      say "Fetch current Task Definition"
																																															      OLD_TD_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
																																																        --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																	  --query 'services[0].taskDefinition' --output text)
																																															      TD_JSON=$(aws ecs describe-task-definition --task-definition "$OLD_TD_ARN" \
																																																        --region "$AWS_REGION" --profile "$AWS_PROFILE")

																																															      say "Build new TD JSON with env + logs"
																																															      NEW_TD_JSON="$TD_JSON"
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | upsert_env_n8n "N8N_PATH" "$N8N_PATH")
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | upsert_env_n8n "N8N_EDITOR_BASE_URL" "$BASE_URL/")
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | upsert_env_n8n "WEBHOOK_URL" "$BASE_URL/")
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | upsert_env_n8n "N8N_HOST" "0.0.0.0")
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | upsert_env_n8n "N8N_PORT" "5678")
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | upsert_env_n8n "N8N_PROTOCOL" "http")

																																															      # Safe log group name
																																															      RAW_LOG_GROUP="/ecs/n8n-${USER_SLUG}"
																																															      LOG_GROUP="$(sanitize_log_group "$RAW_LOG_GROUP")"
																																															      NEW_TD_JSON=$(printf '%s' "$NEW_TD_JSON" | ensure_logs_n8n "$LOG_GROUP")

																																															      # Prepare register payload by selecting only allowed keys and stripping nulls
																																															      REGISTER_JSON=$(printf '%s' "$NEW_TD_JSON" | jq '{
																																															          family: .taskDefinition.family,
																																																      taskRoleArn: .taskDefinition.taskRoleArn,
																																																          executionRoleArn: .taskDefinition.executionRoleArn,
																																																	      networkMode: .taskDefinition.networkMode,
																																																	          containerDefinitions: .taskDefinition.containerDefinitions,
																																																		      volumes: .taskDefinition.volumes,
																																																		          placementConstraints: .taskDefinition.placementConstraints,
																																																			      requiresCompatibilities: .taskDefinition.requiresCompatibilities,
																																																			          cpu: .taskDefinition.cpu,
																																																				      memory: .taskDefinition.memory,
																																																				          runtimePlatform: .taskDefinition.runtimePlatform,
																																																					      ephemeralStorage: .taskDefinition.ephemeralStorage
																																																					        }' | strip_nulls)

																																																						# Ensure the log group exists (no-op if already there)
																																																						aws logs create-log-group --log-group-name "$LOG_GROUP" \
																																																							  --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true
																																																						aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 14 \
																																																							  --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true

																																																						say "Register new task definition revision"
																																																						NEW_TD_ARN=$(aws ecs register-task-definition \
																																																							  --cli-input-json "$REGISTER_JSON" \
																																																							    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
																																																							      --query 'taskDefinition.taskDefinitionArn' --output text)
																																																						echo "New TD: $NEW_TD_ARN"

																																																						say "Update service with force-new-deployment"
																																																						aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
																																																							  --task-definition "$NEW_TD_ARN" --force-new-deployment \
																																																							    --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null

																																																						say "Wait for service stable"
																																																						aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" \
																																																							  --region "$AWS_REGION" --profile "$AWS_PROFILE"

																																																						say "Probe health endpoint with base path"
																																																						curl -sS -I "http://${ALB_DNS}/${USER_SLUG}/healthz" || true

																																																						say "Probe UI (expect HTML)"
																																																						curl -sS "http://${ALB_DNS}/${USER_SLUG}/" | head -n 5 || true

																																																						echo "Done."

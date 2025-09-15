#!/bin/bash
set -euo pipefail
source ./n8n.env

TASK_DEF_NAME="n8n-brbaker"
ACCESS_POINT_ID="fsap-0230c11ed8d60c2f7"

aws ecs register-task-definition \
  --family "$TASK_DEF_NAME" \
  --network-mode "awsvpc" \
  --requires-compatibilities "FARGATE" \
  --cpu "512" \
  --memory "1024" \
  --execution-role-arn "$EXECUTION_ROLE_ARN" \
  --task-role-arn "$TASK_ROLE_ARN" \
  --container-definitions "[
    {
      \"name\": \"init-git-sync\",
      \"image\": \"amazonlinux:2\",
      \"essential\": false,
      \"entryPoint\": [\"/bin/bash\", \"-c\"],
      \"command\": [
        \"yum install -y git openssh; \
         mkdir -p /home/node/.ssh; \
         aws secretsmanager get-secret-value --secret-id n8n/brbaker/gitlab_ssh --region $REGION --query SecretString --output text > /home/node/.ssh/id_ed25519; \
         chmod 600 /home/node/.ssh/id_ed25519; \
         echo -e 'Host gitlab.com\\\\n  IdentityFile /home/node/.ssh/id_ed25519\\\\n  StrictHostKeyChecking no' > /home/node/.ssh/config; \
         git clone git@gitlab.com:analogicdev/internal/n8n-devops-iac.git /home/node/.n8n || echo 'repo already exists'; \
         chown -R 1000:1000 /home/node/.n8n\"
      ],
      \"mountPoints\": [
        {
          \"sourceVolume\": \"efs-workspace\",
          \"containerPath\": \"/home/node/.n8n\"
        }
      ]
    },
    {
      \"name\": \"n8n\",
      \"image\": \"n8nio/n8n\",
      \"essential\": true,
      \"portMappings\": [
        {
          \"containerPort\": 5678,
          \"protocol\": \"tcp\"
        }
      ],
      \"mountPoints\": [
        {
          \"sourceVolume\": \"efs-workspace\",
          \"containerPath\": \"/home/node/.n8n\"
        }
      ]
    }
  ]" \
  --volumes "[
    {
      \"name\": \"efs-workspace\",
      \"efsVolumeConfiguration\": {
        \"fileSystemId\": \"$EFS_ID\",
        \"transitEncryption\": \"ENABLED\",
        \"authorizationConfig\": {
          \"accessPointId\": \"$ACCESS_POINT_ID\",
          \"iam\": \"ENABLED\"
        }
      }
    }
  ]" \
  --region "$REGION" \
  --profile "$PROFILE"


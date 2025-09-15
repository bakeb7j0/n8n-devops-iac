aws iam attach-role-policy \
  --role-name n8nEcsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
  --profile alog-admin --region us-east-1

aws iam attach-role-policy \
  --role-name n8nEcsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonElasticFileSystemClientFullAccess \
  --profile alog-admin --region us-east-1

aws iam attach-role-policy \
  --role-name n8nEcsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
  --profile alog-admin --region us-east-1


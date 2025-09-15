#!/bin/bash
aws iam create-role \
  --role-name n8nEcsTaskExecutionRole \
  --assume-role-policy-document file://ecsTaskExecutionTrust.json \
  --profile alog-admin --region us-east-1


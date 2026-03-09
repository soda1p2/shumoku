# Shumoku - ECS Fargate デプロイガイド

`apps/server/compose.yaml` で定義されている Shumoku Server を AWS ECS Fargate で起動する手順です。

## 構成概要

```
Internet → ALB (:80) → ECS Fargate Service → Container (:8080)
                                                   ↕
                                              EFS (/data)
```

| リソース | 説明 |
|---------|------|
| ECS Cluster | Fargate クラスタ (Container Insights 有効) |
| ECS Service | Fargate タスク (desired count: 1) |
| ALB | インターネット向けロードバランサ |
| EFS | `/data` の永続化ボリューム |
| CloudWatch Logs | `/ecs/shumoku` (30日保持) |

## 前提条件

- AWS CLI v2 (設定済み)
- Docker
- 既存の VPC + パブリックサブネット (2 AZ 以上)

## 手順

### 1. ECR リポジトリ作成

```bash
aws ecr create-repository \
  --repository-name shumoku \
  --region ap-northeast-1 \
  --image-scanning-configuration scanOnPush=true
```

### 2. Docker イメージのビルド & プッシュ

```bash
# リポジトリルートで実行
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=ap-northeast-1
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ECR ログイン
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_URI

# ビルド (compose.yaml と同じ Dockerfile を使用)
docker build -t shumoku:latest -f apps/server/Dockerfile .

# タグ付け & プッシュ
docker tag shumoku:latest ${ECR_URI}/shumoku:latest
docker push ${ECR_URI}/shumoku:latest
```

### 3. CloudFormation でデプロイ

```bash
aws cloudformation deploy \
  --stack-name shumoku-fargate \
  --template-file deploy/ecs-fargate/cfn.yaml \
  --parameter-overrides \
    ImageUri="${ECR_URI}/shumoku:latest" \
    VpcId=vpc-xxxxxxxxx \
    SubnetIds="subnet-aaa,subnet-bbb" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-northeast-1
```

### 4. 動作確認

```bash
# ALB の DNS 名を取得
aws cloudformation describe-stacks \
  --stack-name shumoku-fargate \
  --query 'Stacks[0].Outputs[?OutputKey==`AlbDnsName`].OutputValue' \
  --output text

# ヘルスチェック
curl http://<ALB_DNS>/api/health
```

## ワンコマンドデプロイ (deploy.sh)

環境変数を設定してスクリプトを実行すると、上記すべてのステップを自動で行います。

```bash
export AWS_ACCOUNT_ID=123456789012
export AWS_REGION=ap-northeast-1
export VPC_ID=vpc-xxxxxxxxx
export SUBNET_IDS="subnet-aaa,subnet-bbb"

cd deploy/ecs-fargate
chmod +x deploy.sh
./deploy.sh --build-push
```

`--build-push` を省略すると、イメージのビルドをスキップし既存の ECR イメージでデプロイのみ行います。

## compose.yaml との対応

| compose.yaml | ECS Fargate (cfn.yaml) |
|-------------|------------------------|
| `ports: 8080:8080` | ALB → TargetGroup → ContainerPort 8080 |
| `volumes: shumoku-data:/data` | EFS + AccessPoint → `/data` |
| `restart: unless-stopped` | ECS Service (desired count で自動再起動) |
| `healthcheck` | ALB TargetGroup HealthCheck + Container HealthCheck |
| `init: true` | `LinuxParameters.InitProcessEnabled: true` |
| `security_opt: no-new-privileges` | Fargate ではデフォルトで制限済み |
| `cap_drop: ALL` | Fargate ではデフォルトで最小権限 |
| `logging: json-file` | CloudWatch Logs (awslogs ドライバ) |
| `environment` | TaskDefinition の Environment で同一値を設定 |

## カスタマイズ

### タスクサイズ変更

```bash
aws cloudformation deploy \
  --stack-name shumoku-fargate \
  --template-file deploy/ecs-fargate/cfn.yaml \
  --parameter-overrides \
    ImageUri="${ECR_URI}/shumoku:latest" \
    VpcId=vpc-xxxxxxxxx \
    SubnetIds="subnet-aaa,subnet-bbb" \
    TaskCpu=512 \
    TaskMemory=1024 \
  --capabilities CAPABILITY_NAMED_IAM
```

### EFS 無効化

ステートレスで運用する場合 (データ永続化不要):

```bash
--parameter-overrides EnableEFS=false ...
```

### HTTPS 対応

1. ACM で証明書を取得
2. `cfn.yaml` の `Listener` を HTTPS (443) に変更し `CertificateArn` を追加
3. ALB SecurityGroup に 443 を追加

### ECS Exec でコンテナにアクセス

```bash
aws ecs execute-command \
  --cluster shumoku-cluster \
  --task <task-id> \
  --container shumoku \
  --interactive \
  --command "/bin/sh"
```

## 削除

```bash
aws cloudformation delete-stack --stack-name shumoku-fargate --region ap-northeast-1
# ECR リポジトリも削除する場合
aws ecr delete-repository --repository-name shumoku --region ap-northeast-1 --force
```

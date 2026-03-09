# Shumoku - ECS Fargate デプロイガイド (ecspresso)

`apps/server/compose.yaml` で定義されている Shumoku Server を [ecspresso](https://github.com/kayac/ecspresso) を使って AWS ECS Fargate にデプロイする手順です。

## 構成概要

```
Internet → ALB (:80) → ECS Fargate Service → Container (:8080)
                                                   ↕
                                              EFS (/data)
```

### ツールの役割分担

| ツール | 管轄 |
|-------|------|
| CloudFormation (`cfn-infra.yaml`) | VPC 周辺のインフラ (ALB, EFS, SG, IAM, Logs, ECS Cluster) |
| ecspresso | ECS タスク定義 / サービス定義のデプロイ・運用 |

### ファイル構成

```
deploy/ecs-fargate/
├── ecspresso.yml          # ecspresso 設定ファイル
├── ecs-task-def.json      # ECS タスク定義 (Go template)
├── ecs-service-def.json   # ECS サービス定義 (Go template)
├── cfn-infra.yaml         # インフラ用 CloudFormation テンプレート
├── deploy.sh              # ヘルパースクリプト
└── README.md              # このファイル
```

## 前提条件

- AWS CLI v2 (設定済み)
- Docker
- [ecspresso](https://github.com/kayac/ecspresso) v2+
- 既存の VPC + パブリックサブネット (2 AZ 以上)

### ecspresso のインストール

```bash
# Homebrew
brew install kayac/tap/ecspresso

# Go
go install github.com/kayac/ecspresso/v2/cmd/ecspresso@latest

# バイナリ (Linux)
curl -sL https://github.com/kayac/ecspresso/releases/latest/download/ecspresso_linux_amd64.tar.gz \
  | tar xz -C /usr/local/bin ecspresso
```

## 手順

### 1. 環境変数の設定

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=ap-northeast-1
export VPC_ID=vpc-xxxxxxxxx
export SUBNET_IDS="subnet-aaa,subnet-bbb"
```

### 2. インフラのデプロイ (CloudFormation)

ALB, EFS, SG, IAM ロール, ECS クラスタを作成します。

```bash
cd deploy/ecs-fargate
./deploy.sh infra
```

### 3. Docker イメージのビルド & プッシュ

```bash
./deploy.sh build-push
```

### 4. ECS サービスのデプロイ (ecspresso)

```bash
./deploy.sh deploy
```

ecspresso がインフラスタックの出力値を読み取り、タスク定義・サービス定義のテンプレート変数を解決してデプロイします。

### ワンコマンドで全ステップ実行

```bash
./deploy.sh all
```

## 運用コマンド

```bash
# サービスの状態確認
./deploy.sh status

# ログの確認 (tail -f)
./deploy.sh logs

# コンテナにアクセス (ECS Exec)
./deploy.sh exec

# 前のタスク定義にロールバック
./deploy.sh rollback

# 全リソースの削除
./deploy.sh destroy
```

### ecspresso を直接使う場合

```bash
cd deploy/ecs-fargate

# 環境変数をセット (deploy.sh が自動で行う内容)
export AWS_REGION=ap-northeast-1
export AWS_ACCOUNT_ID=123456789012
export IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/shumoku:latest"
export SERVICE_SG_ID=sg-xxxxxxxxx
export TARGET_GROUP_ARN=arn:aws:elasticloadbalancing:...
export EFS_FILE_SYSTEM_ID=fs-xxxxxxxxx
export EFS_ACCESS_POINT_ID=fsap-xxxxxxxxx
export SUBNET_1=subnet-aaa
export SUBNET_2=subnet-bbb

# デプロイ
ecspresso deploy --config ecspresso.yml

# diff (ドライラン)
ecspresso diff --config ecspresso.yml

# タスク定義の確認
ecspresso render --config ecspresso.yml

# ロールバック
ecspresso rollback --config ecspresso.yml
```

## compose.yaml との対応

| compose.yaml | ECS Fargate (ecspresso) |
|-------------|------------------------|
| `ports: 8080:8080` | ALB → TargetGroup → ContainerPort 8080 |
| `volumes: shumoku-data:/data` | EFS + AccessPoint → `/data` |
| `restart: unless-stopped` | ECS Service (desired count で自動再起動) |
| `healthcheck` | ALB HealthCheck + Container HealthCheck |
| `init: true` | `linuxParameters.initProcessEnabled: true` |
| `security_opt: no-new-privileges` | Fargate ではデフォルトで制限済み |
| `cap_drop: ALL` | Fargate ではデフォルトで最小権限 |
| `logging: json-file` | CloudWatch Logs (awslogs ドライバ) |
| `environment` | `ecs-task-def.json` の `environment` で同一値を設定 |

## カスタマイズ

### タスクサイズ変更

`ecs-task-def.json` の `cpu` / `memory` を編集して再デプロイ:

```bash
# 変更を確認
ecspresso diff --config ecspresso.yml

# 適用
ecspresso deploy --config ecspresso.yml
```

### HTTPS 対応

1. ACM で証明書を取得
2. `cfn-infra.yaml` の `Listener` を HTTPS (443) に変更し `CertificateArn` を追加
3. ALB SecurityGroup に 443 を追加
4. `./deploy.sh infra` で適用

### EFS 無効化

`ecs-task-def.json` から `volumes` と `mountPoints` を削除して再デプロイします。

## 削除

```bash
./deploy.sh destroy
```

ECR リポジトリも削除する場合:

```bash
aws ecr delete-repository --repository-name shumoku --region ap-northeast-1 --force
```

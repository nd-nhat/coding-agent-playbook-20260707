// AWS インフラ（docs/design.md §10）。
// - frontend: S3(OAC) + CloudFront（SPA fallback）
// - backend/mock: ECS Fargate（private subnet）+ internal ALB
// - CloudFront: / → S3、/api/* → VPC Origin → internal ALB → api
import { Stack, type StackProps, RemovalPolicy, CfnOutput } from 'aws-cdk-lib';
import type { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecsPatterns from 'aws-cdk-lib/aws-ecs-patterns';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as ecrAssets from 'aws-cdk-lib/aws-ecr-assets';

// build context = リポジトリルート（infra から1つ上）
const REPO_ROOT = '..';

export class DiagnosisStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    const vpc = new ec2.Vpc(this, 'Vpc', { maxAzs: 2, natGateways: 1 });
    const cluster = new ecs.Cluster(this, 'Cluster', { vpc });

    // --- mock サーバ（internal ALB・外部公開しない） ---
    const mock = new ecsPatterns.ApplicationLoadBalancedFargateService(this, 'Mock', {
      cluster,
      cpu: 256,
      memoryLimitMiB: 512,
      desiredCount: 1,
      publicLoadBalancer: false,
      taskImageOptions: {
        // Fargate (amd64) 向けに build platform を固定 — arm64 host (Apple Silicon) からの
        // deploy で arm image が push され task が起動不能になるのを防ぐ
        image: ecs.ContainerImage.fromAsset(REPO_ROOT, {
          file: 'apps/mock/Dockerfile',
          platform: ecrAssets.Platform.LINUX_AMD64,
        }),
        containerPort: 8787,
        environment: { MOCK_PORT: '8787' },
      },
    });
    mock.targetGroup.configureHealthCheck({ path: '/health' });

    // トークン署名鍵は Secrets Manager で自動生成（平文で env に入れない）
    const tokenSecret = new secretsmanager.Secret(this, 'TokenSecret', {
      generateSecretString: { passwordLength: 48, excludePunctuation: true },
    });

    // 外部連携の向き先は deploy 時に切替可能にする（mock は fallback）。
    //   cdk deploy -c externalBaseUrl=https://real-api...  または env EXTERNAL_BASE_URL
    const externalBaseUrl =
      (this.node.tryGetContext('externalBaseUrl') as string | undefined) ??
      process.env.EXTERNAL_BASE_URL ??
      `http://${mock.loadBalancer.loadBalancerDnsName}`;

    // --- api（internal ALB・診断 backend） ---
    const api = new ecsPatterns.ApplicationLoadBalancedFargateService(this, 'Api', {
      cluster,
      cpu: 512,
      memoryLimitMiB: 1024,
      desiredCount: 2,
      publicLoadBalancer: false, // CloudFront VPC Origin の前提（ALB を public に晒さない）
      taskImageOptions: {
        image: ecs.ContainerImage.fromAsset(REPO_ROOT, {
          file: 'apps/api/Dockerfile',
          platform: ecrAssets.Platform.LINUX_AMD64,
        }),
        containerPort: 8788,
        environment: {
          API_PORT: '8788',
          NODE_ENV: 'production', // secret 未注入なら fail-fast させる
          // backend → mock（既定）/ 実 API（context or env で切替）
          EXTERNAL_BASE_URL: externalBaseUrl,
        },
        // TOKEN_SECRET は平文 env でなく Secrets Manager から注入
        secrets: { TOKEN_SECRET: ecs.Secret.fromSecretsManager(tokenSecret) },
      },
    });
    api.targetGroup.configureHealthCheck({ path: '/health' });
    // CPU でオートスケール（ステートレストークンなので多タスクで状態共有不要）
    api.service.autoScaleTaskCount({ minCapacity: 2, maxCapacity: 6 }).scaleOnCpuUtilization('Cpu', {
      targetUtilizationPercent: 60,
    });

    // api タスク → mock internal ALB（80）を許可
    mock.loadBalancer.connections.allowFrom(api.service, ec2.Port.tcp(80));

    // --- frontend: S3(OAC) + CloudFront ---
    const siteBucket = new s3.Bucket(this, 'SiteBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    const distribution = new cloudfront.Distribution(this, 'Cdn', {
      defaultRootObject: 'index.html',
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(siteBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      },
      additionalBehaviors: {
        // /api/* は VPC Origin 経由で internal ALB(api) へ
        'api/*': {
          origin: origins.VpcOrigin.withApplicationLoadBalancer(api.loadBalancer, {
            protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
          }),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
        },
      },
      // SPA fallback（403/404 → index.html）は **あえて入れない**:
      // CloudFront の errorResponses は distribution 全体に効くため、/api/* の
      // 403（consentMiddleware）/404 まで index.html(200) に書き換えてしまい、
      // RPC クライアントが JSON エラーでなく HTML を掴む。本 SPA はクライアント
      // ルーティングを持たない単一ページ（'/' は defaultRootObject で index.html）
      // のため deep-link fallback も不要。ルーティング導入時は S3 behavior 限定の
      // CloudFront Function で実装すること。
    });

    // SPA ビルド成果物を S3 へアップロード + CloudFront を invalidate
    // （deploy 前に `npm run build --workspace @diag/web` で apps/web/dist を生成しておくこと）
    new s3deploy.BucketDeployment(this, 'DeploySite', {
      sources: [s3deploy.Source.asset('../apps/web/dist')],
      destinationBucket: siteBucket,
      distribution,
      distributionPaths: ['/*'],
    });

    new CfnOutput(this, 'CdnUrl', { value: `https://${distribution.distributionDomainName}` });
    new CfnOutput(this, 'SiteBucketName', { value: siteBucket.bucketName });
  }
}

import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as codebuild from "aws-cdk-lib/aws-codebuild";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as iam from "aws-cdk-lib/aws-iam";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";

export interface FixerPipelineStackProps extends StackProps {
  /** 修正対象 repo "<owner>/<repo>"。fixer が clone して PR を出す先 */
  readonly targetRepo: string;
  /** 壊れた状態の branch（fix の起点） */
  readonly targetBranch: string;
  /** PR の base branch */
  readonly prBase: string;
  /** anthropic=直 API key、bedrock=AWS Bedrock 経由 */
  readonly backend: "anthropic" | "bedrock";
  /** backend=anthropic は API model id、bedrock は inference profile id */
  readonly anthropicModel: string;
  /** fixer-entrypoint.sh を持つ repo（既定 = targetRepo。別 app を直すなら playbook を指す） */
  readonly entrypointRepo: string;
  /** fixer-entrypoint.sh の ref（既定 main。default branch 依存にしない） */
  readonly entrypointRef: string;
}

/**
 * ADR cloud-unattended-sre.md パターン A の「最小 e2e」インフラ:
 *   S3 に sanitized triage を PUT  ->  EventBridge  ->  CodeBuild(fixer 識別子)が
 *   fixer-entrypoint.sh を実行（backend=anthropic で直 key / backend=bedrock で AWS Bedrock）  ->  PR。
 * CloudWatch alarm -> Lambda(観測) の自動配線はこの上に足す（pipeline/README.md）。本 stack は
 * 「fixer が実 AWS で動いて PR が出る」を最小コストで確かめる段。
 */
export class FixerPipelineStack extends Stack {
  constructor(scope: Construct, id: string, props: FixerPipelineStackProps) {
    super(scope, id, props);

    // sanitized triage の handoff バケット（観測が PUT / fixer が GET する唯一の入力経路）。
    // EventBridge 通知を有効化して S3 ObjectCreated を rule で受ける。
    const triageBucket = new s3.Bucket(this, "TriageBucket", {
      eventBridgeEnabled: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // GitHub token は両 backend 共通で必要。Anthropic key は backend=anthropic のときだけ作る
    // （bedrock 経路は IAM で InvokeModel を許可するので key 不要）。値は host が put-secret-value で投入する。
    const githubTokenSecret = new secretsmanager.Secret(this, "FixerGithubToken", {
      description: "fixer が clone/push/PR に使う repo-scoped GitHub token（host が投入）",
    });
    const anthropicKeySecret =
      props.backend === "anthropic"
        ? new secretsmanager.Secret(this, "AnthropicApiKey", {
            description: "fixer の ANTHROPIC_API_KEY（host が put-secret-value で実値を投入）",
          })
        : undefined;

    const baseEnvVars: { [name: string]: codebuild.BuildEnvironmentVariable } = {
      BACKEND: { value: props.backend },
      ANTHROPIC_MODEL: { value: props.anthropicModel },
      TARGET_REPO: { value: props.targetRepo },
      TARGET_BRANCH: { value: props.targetBranch },
      PR_BASE: { value: props.prBase },
      ENTRYPOINT_REPO: { value: props.entrypointRepo },
      ENTRYPOINT_REF: { value: props.entrypointRef },
      // bucket は deploy 時に確定（static）。key だけ EventBridge が build ごとに上書きする。
      TRIAGE_BUCKET: { value: triageBucket.bucketName },
      TRIAGE_S3_KEY: { value: "" },
      // secret 値は env に常時注入せず ARN だけ渡し、install 完了後の build phase で取得する
      // （install phase の未固定コードに GH_TOKEN を晒さない）。
      GH_SECRET_ARN: { value: githubTokenSecret.secretArn },
    };
    if (anthropicKeySecret) {
      baseEnvVars.ANTHROPIC_SECRET_ARN = { value: anthropicKeySecret.secretArn };
    }

    const buildCommands: string[] = [
      // secret は install 後の build phase で取得する（install 中の未固定コードに晒さない）。
      'export GH_TOKEN=$(aws secretsmanager get-secret-value --secret-id "$GH_SECRET_ARN" --query SecretString --output text)',
    ];
    if (anthropicKeySecret) {
      buildCommands.push(
        'export ANTHROPIC_API_KEY=$(aws secretsmanager get-secret-value --secret-id "$ANTHROPIC_SECRET_ARN" --query SecretString --output text)'
      );
    }
    buildCommands.push(
      'test -n "$TRIAGE_S3_KEY" || { echo "ERROR: TRIAGE_S3_KEY 未設定(EventBridge override)" >&2; exit 1; }',
      'aws s3 cp "s3://$TRIAGE_BUCKET/$TRIAGE_S3_KEY" /tmp/triage.json',
      'git config --global user.email "sre-fixer@users.noreply.github.com"',
      'git config --global user.name "SRE Fixer (unattended)"',
      // token を clone URL に埋めない: gh の credential helper で push/clone 認証する。これで /work/.git/config
      // に token が残らず、claude -p の Read が .git/config から token を抜く経路を塞ぐ。
      "gh auth setup-git",
      // entrypoint は明示 ref(既定 main)で取得し default branch 依存にしない。修正対象は壊れた branch を /work に。
      'git clone --depth 1 --branch "$ENTRYPOINT_REF" "https://github.com/$ENTRYPOINT_REPO.git" /tmp/src',
      'git clone "https://github.com/$TARGET_REPO.git" /work',
      'git -C /work checkout "$TARGET_BRANCH"',
      // BACKEND / ANTHROPIC_MODEL / ANTHROPIC_API_KEY は env 経由で entrypoint に届く（inline 再代入で backend を上書きしない）。
      'cd /work && PR_BASE="$PR_BASE" TRIAGE_PATH=/tmp/triage.json bash /tmp/src/examples/sre-bedrock/pipeline/fixer-entrypoint.sh'
    );

    // fixer を回す CodeBuild。source は持たず(NO_SOURCE)、buildspec が clone する。
    const fixerProject = new codebuild.Project(this, "FixerProject", {
      timeout: Duration.minutes(20),
      environment: {
        buildImage: codebuild.LinuxBuildImage.STANDARD_7_0,
        computeType: codebuild.ComputeType.SMALL,
      },
      environmentVariables: baseEnvVars,
      buildSpec: codebuild.BuildSpec.fromObject({
        version: "0.2",
        phases: {
          install: {
            commands: [
              // claude CLI は version 固定（供給網リスク低減。secret はこの phase の env に無い）。
              "npm install -g @anthropic-ai/claude-code@2.1.196",
              // gh が無ければ pinned binary を入れる（CodeBuild standard image は gh 非搭載のことがある）。
              'type gh >/dev/null 2>&1 || { curl -fsSL https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar xz -C /tmp && install -m755 /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh; }',
            ],
          },
          build: {
            commands: buildCommands,
          },
        },
      }),
    });

    // ---- fixer 識別子の権限境界（fixer-identity-iam.json の CDK 版）----
    // 自分の secret（GitHub token、+ backend=anthropic 時は直 key）だけ GET（build phase の get-secret-value 用）。
    githubTokenSecret.grantRead(fixerProject);
    if (anthropicKeySecret) {
      anthropicKeySecret.grantRead(fixerProject);
    }
    // backend=bedrock は直 key の代替として profile + foundation model 両方の InvokeModel を ALLOW。foundation model 側は profile 経由のみに絞る (直接 invoke を塞ぐ defense-in-depth)。
    //   https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-prereq.html
    if (props.backend === "bedrock") {
      // <region-prefix>.<provider>.<model> から provider 以降 (= foundation model id) を抽出。
      // region prefix は将来追加されうるため固定列挙せず汎用パターンで剥がす。
      const match = props.anthropicModel.match(/^(?:[a-z][a-z0-9-]*)\.(anthropic\..+)$/);
      if (!match) {
        throw new Error(
          `backend=bedrock の anthropicModel は inference profile id (例: global.anthropic.claude-opus-4-6-v1) を指定してください: ${props.anthropicModel}`
        );
      }
      const foundationModelId = match[1];
      const inferenceProfileArn = `arn:aws:bedrock:*:${this.account}:inference-profile/${props.anthropicModel}`;
      fixerProject.addToRolePolicy(
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
          resources: [inferenceProfileArn],
        })
      );
      fixerProject.addToRolePolicy(
        new iam.PolicyStatement({
          effect: iam.Effect.ALLOW,
          actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
          resources: [`arn:aws:bedrock:*::foundation-model/${foundationModelId}`],
          conditions: {
            StringLike: {
              "bedrock:InferenceProfileArn": inferenceProfileArn,
            },
          },
        })
      );
    }
    // triage 1 件を GET（バケット列挙は Deny。event で渡る key だけ読める）。
    triageBucket.grantRead(fixerProject, "triage/*");
    fixerProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: ["s3:ListBucket", "s3:ListBucketVersions"],
        resources: [triageBucket.bucketArn],
      })
    );
    // incident / app data の read は明示 Deny（観測の仕事。fixer は触らない）。
    fixerProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: [
          "logs:StartQuery",
          "logs:GetQueryResults",
          "logs:GetLogRecord",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:StartLiveTail",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
        ],
        resources: ["*"],
      })
    );
    // 資格情報ブローカ Deny（権限昇格・観測 role 乗り換えを塞ぐ）。
    fixerProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: [
          "sts:AssumeRole",
          "sts:AssumeRoleWithWebIdentity",
          "sts:AssumeRoleWithSAML",
          "sts:GetFederationToken",
          "sts:GetSessionToken",
        ],
        resources: ["*"],
      })
    );

    // ---- S3 ObjectCreated(triage/*) -> EventBridge -> CodeBuild StartBuild ----
    // 起動は infra（観測の credential でなく）。fixer に渡る override は event 由来の TRIAGE_S3_KEY だけ。
    new events.Rule(this, "TriageObjectCreatedRule", {
      eventPattern: {
        source: ["aws.s3"],
        detailType: ["Object Created"],
        detail: {
          bucket: { name: [triageBucket.bucketName] },
          object: { key: [{ prefix: "triage/" }] },
        },
      },
      targets: [
        new targets.CodeBuildProject(fixerProject, {
          event: events.RuleTargetInput.fromObject({
            // StartBuild の environmentVariablesOverride に event 由来の object key だけ載せる。
            environmentVariablesOverride: [
              {
                name: "TRIAGE_S3_KEY",
                type: "PLAINTEXT",
                value: events.EventField.fromPath("$.detail.object.key"),
              },
            ],
          }),
        }),
      ],
    });

    // runbook が put-secret-value / s3 cp に使う識別子を deploy 出力で copyable にする。
    new CfnOutput(this, "TriageBucketName", {
      value: triageBucket.bucketName,
      description: "triage を置く S3 バケット（s3://<this>/triage/<uuid>.json）",
    });
    if (anthropicKeySecret) {
      new CfnOutput(this, "AnthropicApiKeySecretArn", {
        value: anthropicKeySecret.secretArn,
        description: "put-secret-value で ANTHROPIC_API_KEY を投入する Secret ARN",
      });
    }
    new CfnOutput(this, "FixerGithubTokenSecretArn", {
      value: githubTokenSecret.secretArn,
      description: "put-secret-value で GitHub token を投入する Secret ARN",
    });
  }
}

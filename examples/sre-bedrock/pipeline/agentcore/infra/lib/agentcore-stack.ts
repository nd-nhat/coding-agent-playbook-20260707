import { CfnOutput, DockerImage, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as path from "node:path";
import { execSync } from "node:child_process";
import * as agentcore from "aws-cdk-lib/aws-bedrockagentcore";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as codebuild from "aws-cdk-lib/aws-codebuild";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as iam from "aws-cdk-lib/aws-iam";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";

export interface FixerAgentCoreStackProps extends StackProps {
  readonly targetRepo: string;
  readonly targetBranch: string;
  readonly prBase: string;
  /** Bedrock inference profile id (例: global.anthropic.claude-opus-4-6-v1) */
  readonly anthropicModel: string;
  readonly entrypointRepo: string;
  readonly entrypointRef: string;
}

/**
 * ADR cloud-unattended-sre.md パターン B (AgentCore Runtime + Claude Agent SDK on Bedrock) の最小 e2e:
 *   S3 に sanitized triage を PUT  ->  EventBridge  ->  CodeBuild(bridge)が
 *   bridge.sh で AgentCore Runtime (Node 22 hosted agent server) を InvokeAgentRuntime し、
 *   返ってきた structured patches を repo に適用 -> 冪等 push -> PR。
 */
export class FixerAgentCoreStack extends Stack {
  constructor(scope: Construct, id: string, props: FixerAgentCoreStackProps) {
    super(scope, id, props);

    // sanitized triage の handoff バケット (並走可能にするため stack 専有)。
    const triageBucket = new s3.Bucket(this, "TriageBucket", {
      eventBridgeEnabled: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // bridge が clone/push/PR 操作に使う GitHub token。値は host が put-secret-value で投入。
    const githubTokenSecret = new secretsmanager.Secret(this, "FixerGithubToken", {
      description: "Pattern B bridge の repo-scoped GitHub token (host が投入)",
    });

    // ---- AgentCore Runtime: Node 22 hosted agent server (推論 layer) ----
    // fromCodeAsset(NODE_22) は AWS が提供する Node 22 runtime image に asset を mount する形で起動するため、
    // Dockerfile / ECR push を書かなくて済む。entrypoint は package.json の `start` ではなく explicit に指定。
    const runtimeRole = new iam.Role(this, "AgentRuntimeRole", {
      assumedBy: new iam.ServicePrincipal("bedrock-agentcore.amazonaws.com"),
      // IAM Role description は ASCII + Latin-1 (¡-ÿ) のみ許容 (CFN API level validation、CDK synth では検出されない)。
      description: "Pattern B agent runtime execution role: Bedrock InvokeModel permission",
    });
    // least-privilege IAM: inference profile + foundation model の InvokeModel*。
    // foundation model 側は profile 経由のみ (bedrock:InferenceProfileArn condition で defense-in-depth)。
    const match = props.anthropicModel.match(/^(?:[a-z][a-z0-9-]*)\.(anthropic\..+)$/);
    if (!match) {
      throw new Error(
        `anthropicModel は inference profile id (例: global.anthropic.claude-opus-4-6-v1) を指定してください: ${props.anthropicModel}`
      );
    }
    const foundationModelId = match[1];
    const inferenceProfileArn = `arn:aws:bedrock:*:${this.account}:inference-profile/${props.anthropicModel}`;
    runtimeRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        resources: [inferenceProfileArn],
      })
    );
    runtimeRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        resources: [`arn:aws:bedrock:*::foundation-model/${foundationModelId}`],
        conditions: { StringLike: { "bedrock:InferenceProfileArn": inferenceProfileArn } },
      })
    );

    // fromCodeAsset は node_modules を含まないため起動時 dep 不在を防ぐ bundling (`npm ci --omit=dev`) を回す。local → docker fallback で CI / clean clone でも deploy 可能。
    const agentPath = path.join(__dirname, "..", "..", "agent");
    const agentRuntime = new agentcore.Runtime(this, "FixerRuntime", {
      // runtimeName は明示しない (auto generate)。固定値だと同一 account/region への並列 stack deploy が名前衝突する。
      description: "Pattern B SRE fixer: bridge から呼ばれて triage + repo file 抜粋から structured fix を返す",
      executionRole: runtimeRole,
      agentRuntimeArtifact: agentcore.AgentRuntimeArtifact.fromCodeAsset({
        path: agentPath,
        runtime: agentcore.AgentCoreRuntime.NODE_22,
        // entryPoint は単一要素のみ受け付ける (NODE_22 runtime 指定済みのため interpreter は暗黙、ファイル名だけ渡す)。
        // NODE_22 runtime は拡張子 .js 必須 (.mjs 不可)。package.json の "type": "module" により .js のまま ESM として動く。
        entrypoint: ["server.js"],
        bundling: {
          image: DockerImage.fromRegistry("public.ecr.aws/sam/build-nodejs22.x:latest"),
          command: ["bash", "-c", "cp -R /asset-input/. /asset-output/ && cd /asset-output && npm ci --omit=dev"],
          local: {
            tryBundle(outputDir: string): boolean {
              try {
                execSync(`cp -R "${agentPath}/." "${outputDir}"`);
                execSync(`npm ci --omit=dev --prefix "${outputDir}"`, { stdio: "inherit" });
                return true;
              } catch {
                return false;
              }
            },
          },
        },
      }),
      environmentVariables: {
        ANTHROPIC_MODEL: props.anthropicModel,
      },
      protocolConfiguration: agentcore.ProtocolType.HTTP,
    });

    // ---- bridge CodeBuild: S3 event 受信 -> bridge.sh で Runtime invoke + push + PR ----
    const bridgeProject = new codebuild.Project(this, "BridgeProject", {
      timeout: Duration.minutes(20),
      environment: {
        buildImage: codebuild.LinuxBuildImage.STANDARD_7_0,
        computeType: codebuild.ComputeType.SMALL,
      },
      environmentVariables: {
        AGENT_RUNTIME_ARN: { value: agentRuntime.agentRuntimeArn },
        TARGET_REPO: { value: props.targetRepo },
        TARGET_BRANCH: { value: props.targetBranch },
        PR_BASE: { value: props.prBase },
        ENTRYPOINT_REPO: { value: props.entrypointRepo },
        ENTRYPOINT_REF: { value: props.entrypointRef },
        TRIAGE_BUCKET: { value: triageBucket.bucketName },
        TRIAGE_S3_KEY: { value: "" },
        GH_SECRET_ARN: { value: githubTokenSecret.secretArn },
      },
      buildSpec: codebuild.BuildSpec.fromObject({
        version: "0.2",
        phases: {
          install: {
            commands: [
              'type gh >/dev/null 2>&1 || { curl -fsSL https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar xz -C /tmp && install -m755 /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh; }',
            ],
          },
          build: {
            commands: [
              'export GH_TOKEN=$(aws secretsmanager get-secret-value --secret-id "$GH_SECRET_ARN" --query SecretString --output text)',
              'test -n "$TRIAGE_S3_KEY" || { echo "ERROR: TRIAGE_S3_KEY 未設定(EventBridge override)" >&2; exit 1; }',
              'git config --global user.email "sre-fixer-pattern-b@users.noreply.github.com"',
              'git config --global user.name "SRE Fixer Pattern B (AgentCore Runtime)"',
              // entrypointRepo が private のとき clone に認証が要るため、clone 前に credential helper を設定する。
              "gh auth setup-git",
              'git clone --depth 1 --branch "$ENTRYPOINT_REF" "https://github.com/$ENTRYPOINT_REPO.git" /tmp/src',
              'bash /tmp/src/examples/sre-bedrock/pipeline/agentcore/bridge.sh',
            ],
          },
        },
      }),
    });

    // ---- 権限境界 ----
    githubTokenSecret.grantRead(bridgeProject);
    triageBucket.grantRead(bridgeProject, "triage/*");
    bridgeProject.addToRolePolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.DENY,
        actions: ["s3:ListBucket", "s3:ListBucketVersions"],
        resources: [triageBucket.bucketArn],
      })
    );
    // bridge は AgentCore Runtime InvokeAgentRuntime のみ (Bedrock InvokeModel は直接行わない=識別子分離)。
    agentRuntime.grantInvoke(bridgeProject);
    // bridge は incident/app data の read 系を一切持たない (= 観測 identity との分離)。
    bridgeProject.addToRolePolicy(
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
    bridgeProject.addToRolePolicy(
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

    // ---- S3 ObjectCreated(triage/*) -> EventBridge -> CodeBuild ----
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
        new targets.CodeBuildProject(bridgeProject, {
          event: events.RuleTargetInput.fromObject({
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

    // ---- runbook 用 outputs ----
    new CfnOutput(this, "TriageBucketName", {
      value: triageBucket.bucketName,
      description: "triage を置く S3 バケット (s3://<this>/triage/<uuid>.json)",
    });
    new CfnOutput(this, "FixerGithubTokenSecretArn", {
      value: githubTokenSecret.secretArn,
      description: "put-secret-value で GitHub token を投入する Secret ARN",
    });
    new CfnOutput(this, "AgentRuntimeArn", {
      value: agentRuntime.agentRuntimeArn,
      description: "Pattern B agent runtime の ARN (bridge から invoke)",
    });
  }
}

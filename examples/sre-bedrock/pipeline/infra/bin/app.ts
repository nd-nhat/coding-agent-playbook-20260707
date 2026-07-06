#!/usr/bin/env node
import { App } from "aws-cdk-lib";
import { FixerPipelineStack } from "../lib/fixer-pipeline-stack";

const app = new App();

// 実値は host から context(-c key=val) or env で渡す(IaC に焼かない)。
const targetRepo = app.node.tryGetContext("targetRepo") ?? process.env.TARGET_REPO;
const targetBranch =
  app.node.tryGetContext("targetBranch") ?? process.env.TARGET_BRANCH ?? "stage/08-server-500-broken";
const prBase = app.node.tryGetContext("prBase") ?? process.env.PR_BASE ?? targetBranch;
const backend = (app.node.tryGetContext("backend") ?? "anthropic") as "anthropic" | "bedrock";
// anthropic は直 API model id、bedrock は inference profile id を取る。
const anthropicModel =
  app.node.tryGetContext("anthropicModel") ??
  (backend === "bedrock" ? "global.anthropic.claude-opus-4-6-v1" : "claude-opus-4-8");
const entrypointRepo = app.node.tryGetContext("entrypointRepo") ?? targetRepo;
const entrypointRef = app.node.tryGetContext("entrypointRef") ?? "main";

if (!targetRepo) {
  throw new Error("targetRepo が必要です: cdk deploy -c targetRepo=<owner>/<repo>");
}
if (backend !== "anthropic" && backend !== "bedrock") {
  throw new Error(`backend は anthropic | bedrock のいずれか（指定: ${backend}）`);
}

new FixerPipelineStack(app, "SreBedrockFixerPipeline", {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
  targetRepo,
  targetBranch,
  prBase,
  backend,
  anthropicModel,
  entrypointRepo,
  entrypointRef,
});

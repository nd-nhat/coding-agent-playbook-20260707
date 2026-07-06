#!/usr/bin/env node
import { App } from "aws-cdk-lib";
import { FixerAgentCoreStack } from "../lib/agentcore-stack";

const app = new App();

const targetRepo = app.node.tryGetContext("targetRepo") ?? process.env.TARGET_REPO;
const targetBranch =
  app.node.tryGetContext("targetBranch") ?? process.env.TARGET_BRANCH ?? "stage/08-server-500-broken";
const prBase = app.node.tryGetContext("prBase") ?? process.env.PR_BASE ?? targetBranch;
const anthropicModel =
  app.node.tryGetContext("anthropicModel") ?? process.env.ANTHROPIC_MODEL ?? "global.anthropic.claude-opus-4-6-v1";
const entrypointRepo = app.node.tryGetContext("entrypointRepo") ?? process.env.ENTRYPOINT_REPO ?? targetRepo;
const entrypointRef = app.node.tryGetContext("entrypointRef") ?? process.env.ENTRYPOINT_REF ?? "main";

if (!targetRepo) {
  throw new Error("targetRepo が必要です: cdk deploy -c targetRepo=<owner>/<repo>");
}

new FixerAgentCoreStack(app, "SreBedrockFixerAgentCore", {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
  targetRepo,
  targetBranch,
  prBase,
  anthropicModel,
  entrypointRepo,
  entrypointRef,
});

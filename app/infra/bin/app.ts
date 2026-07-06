import { App } from 'aws-cdk-lib';
import { DiagnosisStack } from '../lib/stack.ts';

const app = new App();
new DiagnosisStack(app, 'DiagnosisMvpStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? 'ap-northeast-1',
  },
});

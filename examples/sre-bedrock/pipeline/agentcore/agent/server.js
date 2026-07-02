// AgentCore Runtime hosted SRE fixer agent。/invocations を Bedrock InvokeModel に翻訳して structured fix を返す (推論 layer の責務)。

import { createServer } from "node:http";
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

const PORT = 8080;
const HOST = "0.0.0.0";
// IAM role 経由で credentials は注入される (executionRole)。region は runtime の deploy region に従う。
const ANTHROPIC_MODEL = process.env.ANTHROPIC_MODEL ?? "global.anthropic.claude-opus-4-6-v1";
const bedrockClient = new BedrockRuntimeClient({});

// triage + 必要 file 抜粋だけが入力 (raw log / secret なし、AWS / network には出ない = identity 境界の再現)。
const SYSTEM_PROMPT = `あなたは本番インシデントを最小修正する SRE agent。観測段から渡される sanitized triage と、bridge が抽出した repo file 抜粋だけを入力に最小 fix を提案する。

入力 JSON は { triage, files: { path: content } } の形。triage の signature を repo 内で特定し、files に含まれる該当ファイルへの最小修正を返せ。

返却は **JSON のみ** で以下 schema に厳密に従う (前後に文章を付けず JSON だけを出力):
{ "patches": [ { "path": <string>, "newContent": <string> } ], "reasoning": <string 1-2 sentence> }

制約:
- 無関係な refactor をしない。triage で示された failing_path 周辺の最小修正のみ。
- input files に無いパスは patches に含めない。
- 修正不要 (= bug が既に直っている or 特定不能) なら "patches": [] で返す。
- newContent はファイル全体の修正後 content。`;

function jsonResponse(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

async function readJsonBody(req, limit = 1024 * 1024) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > limit) {
      throw new Error(`request body too large (>${limit} bytes)`);
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf-8");
  return raw ? JSON.parse(raw) : {};
}

async function callBedrock(input) {
  // Anthropic on Bedrock の Messages API。inference profile (e.g. global.anthropic.claude-opus-4-6-v1) を modelId に渡す。
  const cmd = new InvokeModelCommand({
    modelId: ANTHROPIC_MODEL,
    contentType: "application/json",
    accept: "application/json",
    body: JSON.stringify({
      anthropic_version: "bedrock-2023-05-31",
      max_tokens: 4096,
      system: SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: [{ type: "text", text: JSON.stringify(input) }],
        },
      ],
    }),
  });
  const response = await bedrockClient.send(cmd);
  const payload = JSON.parse(new TextDecoder().decode(response.body));
  // Claude の応答は content[].text に乗る。最初の text を抽出して JSON parse する。
  const text = (payload.content ?? []).find((c) => c.type === "text")?.text ?? "";
  return text;
}

function extractJson(text) {
  // モデル応答に万一前後文や code fence が混ざっていた場合に最初の `{...}` JSON object を抽出する。
  const match = text.match(/\{[\s\S]*\}/);
  if (!match) {
    throw new Error("model response に JSON object が含まれない");
  }
  return JSON.parse(match[0]);
}

const server = createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/ping") {
      jsonResponse(res, 200, { status: "Healthy" });
      return;
    }
    if (req.method === "POST" && req.url === "/invocations") {
      // 入力 parse error は 400 / size 超過は 413 / Bedrock 由来失敗は 502 / 内部 = 500 で status を分ける
      // (集約して 500 に倒すと caller (bridge) が retry 可否を区別できない)。
      let input;
      try {
        input = await readJsonBody(req);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        const status = msg.includes("too large") ? 413 : 400;
        jsonResponse(res, status, { error: `invalid request body: ${msg}` });
        return;
      }
      if (!input || typeof input !== "object" || !input.triage
          || !input.files || typeof input.files !== "object") {
        jsonResponse(res, 400, { error: "input must have { triage, files: object<path,content> }" });
        return;
      }
      const allowedPaths = new Set(Object.keys(input.files));

      let modelText;
      try {
        modelText = await callBedrock(input);
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(JSON.stringify({ level: "error", event: "bedrock_failed", message: msg }));
        jsonResponse(res, 502, { error: "bedrock upstream failed", detail: msg });
        return;
      }

      // patch 要素は { path ∈ input.files keys, newContent: string } を必須化 ({patches:[{path:1, newContent:null}]} 等の schema 違反を caller 側で握り潰さない)。
      let fix;
      try {
        fix = extractJson(modelText);
      } catch (_) {
        jsonResponse(res, 502, { error: "model response not JSON", rawText: modelText });
        return;
      }
      if (!Array.isArray(fix.patches)) {
        jsonResponse(res, 502, { error: "model response missing patches array", rawText: modelText });
        return;
      }
      for (const p of fix.patches) {
        if (!p || typeof p !== "object"
            || typeof p.path !== "string"
            || !allowedPaths.has(p.path)
            || typeof p.newContent !== "string") {
          jsonResponse(res, 502, {
            error: "patch element schema violation (path must be string in input.files, newContent must be string)",
            rejected: { path: p?.path, pathType: typeof p?.path, newContentType: typeof p?.newContent, inAllowlist: typeof p?.path === "string" ? allowedPaths.has(p.path) : null },
          });
          return;
        }
      }
      jsonResponse(res, 200, fix);
      return;
    }
    jsonResponse(res, 404, { error: `unknown route: ${req.method} ${req.url}` });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(JSON.stringify({ level: "error", event: "invocation_failed", message }));
    jsonResponse(res, 500, { error: "internal server error", detail: message });
  }
});

server.listen(PORT, HOST, () => {
  console.log(JSON.stringify({ level: "info", event: "server_started", host: HOST, port: PORT, model: ANTHROPIC_MODEL }));
});

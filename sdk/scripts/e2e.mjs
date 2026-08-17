import { connect, ZaptunnelRpcError } from "../dist/lib/index.js";

const [relay, nodeId, address, rune] = process.argv.slice(2);

if (!relay || !nodeId || !address || !rune) {
  console.error("usage: node scripts/e2e.mjs RELAY NODE_ID HOST:PORT RUNE");
  process.exit(2);
}

const node = await connect({ relay, nodeId, address, rune });

try {
  const info = await node.getInfo();

  if (!info || info.id !== nodeId) {
    throw new Error(`unexpected getinfo response: ${JSON.stringify(info)}`);
  }

  const capabilities = await node.getCapabilities();
  capabilities.require("getinfo");
  capabilities.require("waitanyinvoice");

  try {
    await node.waitAnyInvoice({ lastPayIndex: Number.MAX_SAFE_INTEGER, waitTimeoutSeconds: 0 });
    throw new Error("waitanyinvoice unexpectedly found an invoice beyond the maximum safe cursor");
  } catch (error) {
    if (!(error instanceof ZaptunnelRpcError) || error.code !== "rpc_timeout") throw error;
  }

  console.log(JSON.stringify({
    nodeId: info.id,
    browserPeerId: node.publicKey,
    clnVersion: capabilities.versionRaw,
    waitAnyInvoice: true
  }));
} finally {
  node.disconnect();
}

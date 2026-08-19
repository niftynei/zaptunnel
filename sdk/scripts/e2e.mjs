import { createConnectionManager, ZaptunnelRpcError } from "../dist/lib/index.js";

const [relay, nodeId, address] = process.argv.slice(2);
const rune = process.env.ZAPTUNNEL_RUNE;

if (!relay || !nodeId || !address || !rune) {
  console.error("usage: ZAPTUNNEL_RUNE=... node scripts/e2e.mjs RELAY NODE_ID HOST:PORT");
  process.exit(2);
}

const node = createConnectionManager({
  relay,
  nodeId,
  address,
  rune,
  retry: { minDelayMs: 0, maxDelayMs: 10, jitter: 0 }
});

try {
  const firstClient = await node.start();
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

  firstClient.disconnect();

  for (let attempt = 0; attempt < 100 && node.currentClient === firstClient; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  if (node.currentClient === firstClient) {
    throw new Error("connection manager did not observe the forced disconnect");
  }

  const replacementClient = await node.start();
  const reconnectedInfo = await node.getInfo();

  if (replacementClient === firstClient || reconnectedInfo.id !== nodeId) {
    throw new Error("connection manager did not establish a fresh working session");
  }

  if (replacementClient.publicKey !== firstClient.publicKey) {
    throw new Error("connection manager did not preserve its browser BOLT-8 identity");
  }

  console.log(JSON.stringify({
    nodeId: info.id,
    browserPeerId: firstClient.publicKey,
    clnVersion: capabilities.versionRaw,
    waitAnyInvoice: true,
    reconnected: true
  }));
} finally {
  node.stop();
}

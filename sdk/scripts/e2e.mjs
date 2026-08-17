import { connect } from "../dist/lib/index.js";

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

  console.log(JSON.stringify({ nodeId: info.id, browserPeerId: node.publicKey }));
} finally {
  node.disconnect();
}

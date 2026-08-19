import Lnmessage from "lnmessage";

const [nodeId, address, relayOrigin = "http://127.0.0.1:4000"] = process.argv.slice(2);
const rune = process.env.ZAPTUNNEL_RUNE;

if (!nodeId || !address || !rune) {
  console.error("usage: ZAPTUNNEL_RUNE=... node scripts/connect.mjs NODE_ID HOST:PORT [RELAY_ORIGIN]");
  process.exit(2);
}

const parsedAddress = new URL(`tcp://${address}`);
const response = await fetch(`${relayOrigin}/v1/connections`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ node_id: nodeId, address })
});

if (!response.ok) {
  throw new Error(`admission failed: ${response.status} ${await response.text()}`);
}

const admission = await response.json();
const websocketUrl = new URL(admission.websocket_path, relayOrigin);
websocketUrl.protocol = websocketUrl.protocol === "https:" ? "wss:" : "ws:";
const ln = new Lnmessage({
  remoteNodePublicKey: nodeId,
  ip: parsedAddress.hostname,
  port: Number(parsedAddress.port),
  wsProxy: websocketUrl.toString().replace(/\/$/, "")
});

try {
  const connected = await ln.connect(false);

  if (!connected) {
    throw new Error("BOLT-8 connection closed before initialization completed");
  }

  const result = await ln.commando({
    reqId: crypto.randomUUID().replaceAll("-", "").slice(0, 16),
    method: "getinfo",
    params: [],
    rune
  });

  console.log(JSON.stringify({ browserPeerId: ln.publicKey, result }, null, 2));
} finally {
  ln.disconnect();
}

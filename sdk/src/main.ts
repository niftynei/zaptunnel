import Lnmessage from "lnmessage";
import "./style.css";

type Admission = {
  websocket_path: string;
};

const relayOrigin = import.meta.env.VITE_ZAPTUNNEL_RELAY ?? "http://127.0.0.1:4000";
const form = document.querySelector<HTMLFormElement>("#connect-form");
const status = document.querySelector<HTMLPreElement>("#status");

if (!form || !status) {
  throw new Error("missing required page elements");
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  status.textContent = "Requesting connection…";

  const nodeId = value("node-id");
  const address = value("address");
  const rune = value("rune");
  const { host, port } = parseAddress(address);

  try {
    const response = await fetch(`${relayOrigin}/v1/connections`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ node_id: nodeId, address })
    });

    if (!response.ok) {
      throw new Error(`admission failed: ${response.status} ${await response.text()}`);
    }

    const admission = (await response.json()) as Admission;
    const websocketUrl = new URL(admission.websocket_path, relayOrigin);
    websocketUrl.protocol = websocketUrl.protocol === "https:" ? "wss:" : "ws:";
    status.textContent = "Establishing BOLT-8 connection…";

    const ln = new Lnmessage({
      remoteNodePublicKey: nodeId,
      ip: host,
      port,
      wsProxy: websocketUrl.toString().replace(/\/$/, ""),
      logger: {
        info: console.info,
        warn: console.warn,
        error: console.error
      }
    });

    await ln.connect();
    status.textContent = "Connected. Calling getinfo…";

    const info = await ln.commando({
      reqId: crypto.randomUUID().replaceAll("-", "").slice(0, 16),
      method: "getinfo",
      params: [],
      rune
    });

    status.textContent = JSON.stringify(info, null, 2);
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
});

function value(id: string): string {
  const input = document.querySelector<HTMLInputElement>(`#${id}`);

  if (!input) {
    throw new Error(`missing input: ${id}`);
  }

  return input.value.trim();
}

function parseAddress(address: string): { host: string; port: number } {
  const parsed = new URL(`tcp://${address}`);
  const port = Number(parsed.port);

  if (!parsed.hostname || !Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("address must be host:port");
  }

  return { host: parsed.hostname, port };
}

import Lnmessage from "lnmessage";

export type RpcParams = unknown[] | Record<string, unknown>;

export const DEFAULT_RELAY = "https://relay.zapptunnel.com";

export type ZaptunnelLogger = {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
};

export type ConnectOptions = {
  /** Public Zaptunnel relay origin, for example https://relay.zapptunnel.com. */
  relay?: string;
  /** Compressed 33-byte Core Lightning node public key. */
  nodeId: string;
  /** Publicly reachable Lightning peer listener in host:port form. */
  address: string;
  /** Default Commando rune used by call() and convenience methods. */
  rune?: string;
  /** Optional persistent BOLT-8 initiator private key, encoded as 32-byte hex. */
  privateKey?: string;
  /** Disable automatic lnmessage reconnects by default for deterministic app lifecycle. */
  reconnect?: boolean;
  logger?: ZaptunnelLogger;
  signal?: AbortSignal;
};

type AdmissionResponse = {
  websocket_path: string;
};

export class ZaptunnelError extends Error {
  readonly code: string;
  readonly status?: number;

  constructor(message: string, options: { code: string; status?: number; cause?: unknown }) {
    super(message, { cause: options.cause });
    this.name = "ZaptunnelError";
    this.code = options.code;
    this.status = options.status;
  }
}

export class ZaptunnelClient {
  readonly nodeId: string;
  readonly address: string;
  readonly publicKey: string;
  readonly privateKey: string;

  #rune?: string;
  #transport: Lnmessage;

  constructor(transport: Lnmessage, options: Pick<ConnectOptions, "nodeId" | "address" | "rune">) {
    this.#transport = transport;
    this.#rune = options.rune;
    this.nodeId = options.nodeId;
    this.address = options.address;
    this.publicKey = transport.publicKey;
    this.privateKey = transport.privateKey;
  }

  /** Invoke any CLN JSON-RPC method through Commando. */
  async call<T = unknown>(method: string, params: RpcParams = [], options: { rune?: string } = {}): Promise<T> {
    const rune = options.rune ?? this.#rune;

    if (!rune) {
      throw new ZaptunnelError("a Commando rune is required for RPC calls", { code: "rune_required" });
    }

    return (await this.#transport.commando({ method, params, rune })) as T;
  }

  getInfo<T = unknown>(): Promise<T> {
    return this.getinfo<T>();
  }

  getinfo<T = unknown>(): Promise<T> {
    return this.call<T>("getinfo");
  }

  invoice<T = unknown>(params: Record<string, unknown>): Promise<T> {
    return this.call<T>("invoice", params);
  }

  disconnect(): void {
    this.#transport.disconnect();
  }
}

/** Request admission and establish an end-to-end BOLT-8 session with CLN. */
export async function connect(options: ConnectOptions): Promise<ZaptunnelClient> {
  validateNodeId(options.nodeId);
  const { host, port } = parseAddress(options.address);
  const relay = parseRelay(options.relay ?? DEFAULT_RELAY);
  const admission = await requestAdmission(relay, options, globalThis.fetch);
  const websocketUrl = new URL(admission.websocket_path, relay);
  websocketUrl.protocol = websocketUrl.protocol === "https:" ? "wss:" : "ws:";

  const transport = new Lnmessage({
    remoteNodePublicKey: options.nodeId.toLowerCase(),
    ip: host,
    port,
    wsProxy: websocketUrl.toString().replace(/\/$/, ""),
    privateKey: options.privateKey,
    logger: options.logger
  });

  try {
    const connected = await transport.connect(options.reconnect ?? false);

    if (!connected) {
      throw new ZaptunnelError("the Lightning connection closed during its BOLT-8 handshake", {
        code: "connection_closed"
      });
    }

    return new ZaptunnelClient(transport, options);
  } catch (error) {
    transport.disconnect();

    if (error instanceof ZaptunnelError) throw error;
    throw new ZaptunnelError("failed to establish the Lightning connection", {
      code: "connection_failed",
      cause: error
    });
  }
}

async function requestAdmission(
  relay: URL,
  options: Pick<ConnectOptions, "nodeId" | "address" | "signal">,
  fetcher: typeof fetch
): Promise<AdmissionResponse> {
  let response: Response;

  try {
    response = await fetcher(new URL("/v1/connections", relay), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ node_id: options.nodeId.toLowerCase(), address: options.address }),
      signal: options.signal
    });
  } catch (error) {
    throw new ZaptunnelError("could not reach the Zaptunnel relay", {
      code: "relay_unreachable",
      cause: error
    });
  }

  const body = (await response.json().catch(() => ({}))) as Partial<AdmissionResponse> & {
    error?: string;
  };

  if (!response.ok) {
    const code = body.error ?? "admission_failed";
    throw new ZaptunnelError(`Zaptunnel admission failed: ${code}`, { code, status: response.status });
  }

  if (typeof body.websocket_path !== "string" || !body.websocket_path.startsWith("/")) {
    throw new ZaptunnelError("the relay returned an invalid admission response", {
      code: "invalid_relay_response",
      status: response.status
    });
  }

  return { websocket_path: body.websocket_path };
}

export function parseAddress(address: string): { host: string; port: number } {
  let parsed: URL;

  try {
    parsed = new URL(`tcp://${address}`);
  } catch (error) {
    throw new ZaptunnelError("address must be host:port", { code: "invalid_address", cause: error });
  }

  const port = Number(parsed.port);

  if (!parsed.hostname || !Number.isInteger(port) || port < 1 || port > 65_535 || parsed.pathname !== "") {
    throw new ZaptunnelError("address must be host:port", { code: "invalid_address" });
  }

  return { host: parsed.hostname, port };
}

function parseRelay(relay: string): URL {
  let parsed: URL;

  try {
    parsed = new URL(relay);
  } catch (error) {
    throw new ZaptunnelError("relay must be an HTTP or HTTPS origin", {
      code: "invalid_relay",
      cause: error
    });
  }

  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) {
    throw new ZaptunnelError("relay must be an HTTP or HTTPS origin", { code: "invalid_relay" });
  }

  return parsed;
}

function validateNodeId(nodeId: string): void {
  if (!/^(02|03)[0-9a-f]{64}$/i.test(nodeId)) {
    throw new ZaptunnelError("nodeId must be a compressed secp256k1 public key", {
      code: "invalid_node_id"
    });
  }
}

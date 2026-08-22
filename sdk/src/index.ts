import Lnmessage from "lnmessage";

export type RpcParams = unknown[] | Record<string, unknown>;

export type RpcCallOptions = {
  /** Override the client's default rune for this call. */
  rune?: string;
  /** Reject locally if the request has not completed within this many milliseconds. Defaults to 30 seconds. */
  timeoutMs?: number;
  /** Reject locally when the signal is aborted. */
  signal?: AbortSignal;
};

export type ClnVersion = {
  raw: string;
  major: number;
  minor: number;
  patch: number;
  suffix: string;
};

export type GetInfoResponse = {
  id: string;
  alias: string;
  color: string;
  version: string;
  network: string;
  blockheight: number;
  num_peers: number;
  num_pending_channels: number;
  num_active_channels: number;
  num_inactive_channels: number;
  [key: string]: unknown;
};

export type PaidInvoice = {
  label: string;
  payment_hash: string;
  status: "paid";
  pay_index: number;
  amount_received_msat: unknown;
  paid_at: number;
  payment_preimage: string;
  expires_at: number;
  created_index?: number;
  updated_index?: number;
  description?: string;
  amount_msat?: unknown;
  bolt11?: string;
  bolt12?: string;
  paid_outpoint?: { txid: string; outnum: number };
  [key: string]: unknown;
};

export type WaitAnyInvoiceOptions = RpcCallOptions & {
  /** Ignore paid invoices at or below this monotonically increasing CLN index. */
  lastPayIndex?: number;
  /** Ask CLN to end the long poll after this many seconds. Defaults to 30 seconds. */
  waitTimeoutSeconds?: number;
};

export type PaidInvoiceStreamOptions = Omit<WaitAnyInvoiceOptions, "timeoutMs" | "waitTimeoutSeconds"> & {
  /** Finite CLN long-poll duration. Defaults to 30 seconds so cancellation is bounded. */
  waitTimeoutSeconds?: number;
  /** Local grace period after CLN's long-poll timeout. Defaults to 5 seconds. */
  timeoutGraceMs?: number;
  /** Minimum pause after a fast CLN timeout response. Defaults to 250 ms. */
  retryDelayMs?: number;
};

export const DEFAULT_RELAY = "https://relay.zapptunnel.com";
export const BITCOIN_MAINNET_CHAIN_HASH =
  "6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000";

const INIT_MESSAGE_TYPE = 16;
const GOSSIP_TIMESTAMP_FILTER_MESSAGE_TYPE = 265;
const COMMANDO_RESPONSE_CONTINUES_MESSAGE_TYPE = 22_859;
const COMMANDO_RESPONSE_MESSAGE_TYPE = 22_861;
const NO_GOSSIP_FIRST_TIMESTAMP = 0xffff_ffff;
const NO_GOSSIP_TIMESTAMP_RANGE = 0;
const DEFAULT_CONNECTION_TIMEOUT_MS = 15_000;
const DEFAULT_RPC_TIMEOUT_MS = 30_000;
const MAX_PARTIAL_COMMANDO_RESPONSES = 128;
const MAX_PARTIAL_COMMANDO_BYTES = 1_048_576;

export type ZaptunnelLogger = {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
};

export type ZaptunnelConnectionStatus =
  | "connected"
  | "connecting"
  | "waiting_reconnect"
  | "disconnected"
  | "failed";

export type ZaptunnelManagerStatus =
  | "idle"
  | "connecting"
  | "connected"
  | "waiting_reconnect"
  | "failed"
  | "stopped";

export type ZaptunnelFailureStage =
  | "input"
  | "relay_admission"
  | "endpoint_verification"
  | "lightning_handshake"
  | "lightning_transport"
  | "authorization"
  | "rpc"
  | "lifecycle"
  | "unknown";

export type ZaptunnelTroubleshooting = {
  /** Stable SDK error code. */
  code: string;
  /** More specific nested error when a lifecycle wrapper exhausted retries. */
  causeCode?: string;
  stage: ZaptunnelFailureStage;
  title: string;
  summary: string;
  retryable: boolean;
  requestId?: string;
  suggestions: readonly string[];
};

export type ZaptunnelManagerState = {
  status: ZaptunnelManagerStatus;
  /** One-based attempt number for the current outage; zero while connected. */
  attempt: number;
  /** Unix timestamp in milliseconds, or null when no retry is scheduled. */
  nextRetryAt: number | null;
  /** Remaining delay at the instant this snapshot was read. */
  retryInMs: number | null;
  requestId?: string;
  diagnostic?: ZaptunnelTroubleshooting;
};

export type ReconnectPolicy = {
  /** First retry delay. Defaults to 1 second. */
  minDelayMs?: number;
  /** Maximum retry delay. Defaults to 30 seconds. */
  maxDelayMs?: number;
  /** Exponential multiplier. Defaults to 2. */
  multiplier?: number;
  /** Symmetric random variation from 0 through 1. Defaults to 0.2. */
  jitter?: number;
  /** Attempts per outage, including the first attempt. Defaults to unlimited. */
  maxAttempts?: number;
};

export type ZaptunnelIdentityStore = {
  /** Load a previously saved BOLT-8 initiator private key for this node. */
  loadPrivateKey(nodeId: string): string | undefined | Promise<string | undefined>;
  /** Save the generated BOLT-8 initiator private key. Runes are never passed here. */
  savePrivateKey(nodeId: string, privateKey: string): void | Promise<void>;
};

export type ZaptunnelPaymentChallenge = {
  amountSats: number;
  expiresAt: number;
  invoice: string;
  paymentHash: string;
  protocol: "bolt12";
  quoteId: string;
};

export type ZaptunnelPaymentClaim = {
  relay: string;
  nodeId: string;
  quoteId: string;
  claimPath: string;
  claimToken: string;
  expiresAt: number;
  /** Original invoice data, retained so recovery can render the same payment request. */
  challenge: ZaptunnelPaymentChallenge;
};

export type ZaptunnelPaymentStore = {
  /** Recover a pending or previously paid claim after a reload. */
  loadClaim(nodeId: string): ZaptunnelPaymentClaim | undefined | Promise<ZaptunnelPaymentClaim | undefined>;
  /** Persist the bearer claim secret. Applications should use protected storage. */
  saveClaim(nodeId: string, claim: ZaptunnelPaymentClaim): void | Promise<void>;
  clearClaim(nodeId: string): void | Promise<void>;
};

export type ZaptunnelPaymentStatus = "paying" | "waiting_settlement" | "settled";

export type ZaptunnelPaymentOptions = {
  /**
   * Pay or display the BOLT12 invoice. Settlement is verified by the relay, so
   * any return value from the wallet is ignored.
   */
  payInvoice(challenge: ZaptunnelPaymentChallenge): Promise<unknown>;
  /** Optional durable recovery for pending claims and page reloads. */
  store?: ZaptunnelPaymentStore;
  onStatus?(status: ZaptunnelPaymentStatus, challenge: ZaptunnelPaymentChallenge): void;
};

export type ConnectOptions = {
  /** Public Zaptunnel relay origin, for example https://relay.zapptunnel.com. */
  relay?: string;
  /** Permit plaintext HTTP/WS to a non-loopback relay. Unsafe; intended only for controlled test networks. */
  allowInsecureRelay?: boolean;
  /** Compressed 33-byte Core Lightning node public key. */
  nodeId: string;
  /** Publicly reachable Lightning peer listener in host:port form. */
  address: string;
  /** Default Commando rune used by call() and convenience methods. */
  rune?: string;
  /** Optional persistent BOLT-8 initiator private key, encoded as 32-byte hex. */
  privateKey?: string;
  /**
   * BOLT wire-order chain hash used by the restrictive gossip filter. The SDK
   * normally learns this from the node's init message and otherwise defaults
   * to Bitcoin mainnet. Set this for non-mainnet nodes that omit init networks.
   */
  chainHash?: string;
  /** @deprecated Relay tickets are single-use; use createConnectionManager() instead. */
  reconnect?: boolean;
  /** Receives only SDK-authored, payload-free lifecycle diagnostics. */
  logger?: ZaptunnelLogger;
  signal?: AbortSignal;
  /** Local deadline for WebSocket and BOLT-8 establishment. Defaults to 15 seconds. */
  connectionTimeoutMs?: number;
  payment?: ZaptunnelPaymentOptions;
  /** A previously purchased reconnect-safe lease returned by Zaptunnel. */
  paymentLease?: string;
};

export type ConnectionManagerOptions = Omit<ConnectOptions, "reconnect" | "signal"> & {
  retry?: ReconnectPolicy;
  identityStore?: ZaptunnelIdentityStore;
};

type AdmissionResponse = {
  websocket_path: string;
  request_id?: string;
  lease?: string;
  lease_expires_at?: number;
};

export class ZaptunnelError extends Error {
  readonly code: string;
  readonly status?: number;
  readonly requestId?: string;

  constructor(
    message: string,
    options: { code: string; status?: number; requestId?: string; cause?: unknown }
  ) {
    super(message, { cause: options.cause });
    this.name = "ZaptunnelError";
    this.code = options.code;
    this.status = options.status;
    this.requestId = options.requestId;
  }
}

export class ZaptunnelRpcError extends ZaptunnelError {
  readonly method: string;
  readonly rpcCode?: number;
  readonly data?: unknown;

  constructor(
    message: string,
    options: {
      code: string;
      method: string;
      rpcCode?: number;
      data?: unknown;
      cause?: unknown;
    }
  ) {
    super(message, options);
    this.name = "ZaptunnelRpcError";
    this.method = options.method;
    this.rpcCode = options.rpcCode;
    this.data = options.data;
  }
}

export class ZaptunnelPaymentRequiredError extends ZaptunnelError {
  readonly challenge: ZaptunnelPaymentChallenge;

  constructor(challenge: ZaptunnelPaymentChallenge, options: { requestId?: string } = {}) {
    super("an additional connection requires payment", {
      code: "payment_required",
      status: 402,
      requestId: options.requestId
    });
    this.name = "ZaptunnelPaymentRequiredError";
    this.challenge = challenge;
  }
}

type TroubleshootingDefinition = Omit<
  ZaptunnelTroubleshooting,
  "code" | "causeCode" | "requestId"
>;

const TROUBLESHOOTING: Readonly<Record<string, TroubleshootingDefinition>> = Object.freeze({
  invalid_node_id: {
    stage: "input",
    title: "Invalid node ID",
    summary: "The node ID is not a 33-byte compressed secp256k1 public key.",
    retryable: false,
    suggestions: ["Copy the id field from lightning-cli getinfo."]
  },
  invalid_address: {
    stage: "input",
    title: "Invalid Lightning address",
    summary: "The address must contain a hostname or IP address and Lightning peer port.",
    retryable: false,
    suggestions: ["Use host:port, or [IPv6]:port, without http:// or https://."]
  },
  invalid_relay: {
    stage: "input",
    title: "Invalid relay address",
    summary: "The relay must be an HTTP or HTTPS origin.",
    retryable: false,
    suggestions: ["Use https://relay.zapptunnel.com or a complete self-hosted relay origin."]
  },
  invalid_chain_hash: {
    stage: "input",
    title: "Invalid chain hash",
    summary: "The BOLT chain hash must be exactly 32 bytes of hexadecimal data.",
    retryable: false,
    suggestions: ["Remove chainHash to use automatic network detection when possible."]
  },
  invalid_cln_version: {
    stage: "input",
    title: "Invalid CLN version",
    summary: "The version requirement is not in a supported CLN version format.",
    retryable: false,
    suggestions: ["Use a version such as v24.02 or v24.02.1."]
  },
  invalid_option: {
    stage: "input",
    title: "Invalid SDK option",
    summary: "One of the SDK or retry-policy options is outside its accepted range.",
    retryable: false,
    suggestions: ["Correct the option identified by the original error message."]
  },
  relay_unreachable: {
    stage: "relay_admission",
    title: "Relay unreachable",
    summary: "The browser could not reach the relay admission endpoint.",
    retryable: true,
    suggestions: ["Check internet connectivity and the relay URL.", "Retry after the relay is reachable."]
  },
  invalid_relay_response: {
    stage: "relay_admission",
    title: "Invalid relay response",
    summary: "The relay returned a response this SDK version does not understand.",
    retryable: true,
    suggestions: ["Check SDK/relay compatibility.", "Report the request ID to the relay operator."]
  },
  admission_failed: {
    stage: "relay_admission",
    title: "Relay admission failed",
    summary: "The relay refused the connection without a more specific stable code.",
    retryable: true,
    suggestions: ["Retry once, then report the request ID if the failure continues."]
  },
  rate_limited: {
    stage: "relay_admission",
    title: "Too many connection requests",
    summary: "The relay is temporarily rate limiting this client.",
    retryable: true,
    suggestions: ["Wait for the SDK backoff instead of repeatedly retrying manually."]
  },
  connection_limit: {
    stage: "relay_admission",
    title: "Free connection limit reached",
    summary: "This node already has the maximum number of concurrent free sessions.",
    retryable: true,
    suggestions: ["Close an unused session or wait for one to disconnect before retrying."]
  },
  pending_limit: {
    stage: "relay_admission",
    title: "Connection ticket already pending",
    summary: "The destination already has the configured number of unclaimed connection tickets.",
    retryable: true,
    suggestions: ["Retry after the short admission-ticket lifetime or claim the ticket already issued."]
  },
  payment_required: {
    stage: "relay_admission",
    title: "Connection payment required",
    summary: "The node's free concurrent connection slots are already in use.",
    retryable: true,
    suggestions: ["Pay the Lightning invoice to obtain a reconnect-safe connection lease."]
  },
  payment_quote_limit: {
    stage: "relay_admission",
    title: "Too many pending payment quotes",
    summary: "This client already has the maximum number of unpaid connection invoices.",
    retryable: true,
    suggestions: ["Finish or allow an existing invoice to expire before requesting another."]
  },
  payment_failed: {
    stage: "relay_admission",
    title: "Connection payment failed",
    summary: "The wallet did not complete the requested Lightning payment.",
    retryable: true,
    suggestions: ["Check the wallet result and request a fresh payment challenge if necessary."]
  },
  payment_expired: {
    stage: "relay_admission",
    title: "Payment claim expired",
    summary: "The invoice was not observed as paid before its settlement grace period ended.",
    retryable: true,
    suggestions: ["Request a fresh invoice. Contact the relay operator if the expired invoice was paid."]
  },
  invalid_claim: {
    stage: "authorization",
    title: "Payment claim rejected",
    summary: "The saved external-wallet claim secret is invalid for this quote.",
    retryable: false,
    suggestions: ["Clear the saved claim and request a fresh payment challenge."]
  },
  payment_status_unavailable: {
    stage: "relay_admission",
    title: "Payment status unavailable",
    summary: "The relay could not currently determine whether the invoice was paid.",
    retryable: true,
    suggestions: ["Keep the claim secret and retry after the relay billing connection recovers."]
  },
  billing_unavailable: {
    stage: "relay_admission",
    title: "Relay billing unavailable",
    summary: "The relay could not reach or safely use its billing service.",
    retryable: true,
    suggestions: ["Keep any payment claim and retry after the relay recovers."]
  },
  invalid_lease: {
    stage: "relay_admission",
    title: "Connection lease invalid",
    summary: "The paid connection lease is invalid, expired, or belongs to another node.",
    retryable: true,
    suggestions: ["Remove the stale lease and request a new connection payment challenge."]
  },
  lease_node_mismatch: {
    stage: "authorization",
    title: "Connection lease belongs to another node",
    summary: "The supplied paid lease is not valid for this destination node.",
    retryable: false,
    suggestions: ["Use the lease only with the node for which it was purchased."]
  },
  lease_in_use: {
    stage: "relay_admission",
    title: "Connection lease already active",
    summary: "This paid lease already has a pending or active connection.",
    retryable: true,
    suggestions: ["Close the previous session or wait for the relay to release it."]
  },
  relay_draining: {
    stage: "relay_admission",
    title: "Relay restarting",
    summary: "The relay is draining existing sessions and temporarily refusing new admission.",
    retryable: true,
    suggestions: ["Allow the connection manager to retry after the deployment completes."]
  },
  relay_overloaded: {
    stage: "relay_admission",
    title: "Relay at capacity",
    summary: "The relay does not currently have capacity for another session.",
    retryable: true,
    suggestions: ["Wait for automatic backoff or use another relay deployment."]
  },
  onion_unavailable: {
    stage: "relay_admission",
    title: "Tor routing unavailable",
    summary: "The selected relay cannot currently route v3 onion addresses.",
    retryable: true,
    suggestions: ["Use a Tor-capable relay or provide the node's clearnet address."]
  },
  non_public_address: {
    stage: "relay_admission",
    title: "Private destination refused",
    summary: "The public relay does not connect to private, loopback, or otherwise restricted addresses.",
    retryable: false,
    suggestions: ["Provide the node's publicly reachable clearnet address or v3 onion service."]
  },
  invalid_connection_request: {
    stage: "relay_admission",
    title: "Invalid connection request",
    summary: "The relay rejected the supplied node ID, address, or request shape.",
    retryable: false,
    suggestions: ["Validate the node ID and host:port address before retrying."]
  },
  misdirected_request: {
    stage: "relay_admission",
    title: "Wrong relay host",
    summary: "The request reached a host name that this service does not handle.",
    retryable: false,
    suggestions: ["Use the configured relay origin rather than the website or server IP."]
  },
  not_found: {
    stage: "relay_admission",
    title: "Relay endpoint not found",
    summary: "The selected server does not expose the requested Zaptunnel endpoint.",
    retryable: false,
    suggestions: ["Check the relay URL and SDK/relay version compatibility."]
  },
  website_not_packaged: {
    stage: "relay_admission",
    title: "Relay website unavailable",
    summary: "This relay build does not contain the packaged website assets.",
    retryable: false,
    suggestions: ["Use the relay API directly or deploy a release containing the website bundle."]
  },
  invalid_ticket: {
    stage: "relay_admission",
    title: "Expired relay ticket",
    summary: "The single-use WebSocket admission ticket was invalid, expired, or already used.",
    retryable: true,
    suggestions: ["Request fresh admission; createConnectionManager() does this automatically."]
  },
  endpoint_unverified: {
    stage: "endpoint_verification",
    title: "Lightning endpoint could not be verified",
    summary: "The supplied address did not complete a BOLT-8 handshake as the supplied node ID.",
    retryable: true,
    suggestions: [
      "Confirm the node ID and peer address came from the same CLN node.",
      "Confirm CLN is online and accepting Lightning peer connections on that port.",
      "For onion addresses, confirm the onion service maps to the CLN peer listener."
    ]
  },
  connection_closed: {
    stage: "lightning_handshake",
    title: "Lightning connection closed",
    summary: "The peer connection closed before or after the BOLT-8 session was established.",
    retryable: true,
    suggestions: ["Check CLN availability and let the connection manager create a fresh session."]
  },
  connection_timeout: {
    stage: "lightning_handshake",
    title: "Lightning connection timed out",
    summary: "The WebSocket or BOLT-8 handshake did not complete before the local deadline.",
    retryable: true,
    suggestions: ["Check the peer and relay, then retry with a fresh admission ticket."]
  },
  transport_integrity_failure: {
    stage: "lightning_transport",
    title: "Encrypted Lightning transport failed integrity validation",
    summary: "A received Lightning frame failed authenticated decryption and the session was closed.",
    retryable: true,
    suggestions: ["Retry with a fresh session. If it repeats, report the relay request ID and inspect relay/network integrity."]
  },
  transport_resource_limit: {
    stage: "lightning_transport",
    title: "Lightning transport response limit exceeded",
    summary: "The peer sent too many or too-large partial Commando responses, so the SDK closed the session.",
    retryable: false,
    suggestions: ["Inspect the destination node or plugin before reconnecting."]
  },
  connection_failed: {
    stage: "lightning_handshake",
    title: "Lightning connection failed",
    summary: "The browser and CLN node could not finish their encrypted Lightning connection.",
    retryable: true,
    suggestions: ["Check the node address, CLN logs, and relay request ID before retrying."]
  },
  gossip_filter_failed: {
    stage: "lightning_handshake",
    title: "Gossip filter failed",
    summary: "The SDK connected but could not configure its restrictive BOLT 7 gossip filter.",
    retryable: true,
    suggestions: ["Retry with a fresh session and report the request ID if it repeats."]
  },
  rune_required: {
    stage: "authorization",
    title: "Rune required",
    summary: "A Commando RPC call was attempted without a rune.",
    retryable: false,
    suggestions: ["Provide a narrowly scoped rune that permits the requested RPC method."]
  },
  rune_not_authorized: {
    stage: "authorization",
    title: "Rune not authorized",
    summary: "CLN rejected the rune or its restrictions for this RPC call.",
    retryable: false,
    suggestions: ["Create a new least-privilege rune permitting the method and parameters."]
  },
  method_not_found: {
    stage: "rpc",
    title: "RPC method unavailable",
    summary: "The connected CLN node does not expose the requested RPC method.",
    retryable: false,
    suggestions: ["Use getCapabilities() and check the node's CLN version and plugins."]
  },
  unsupported_method: {
    stage: "rpc",
    title: "RPC capability unavailable",
    summary: "The application's required RPC method is not exposed by this node.",
    retryable: false,
    suggestions: ["Choose a supported fallback or update the node/plugin configuration."]
  },
  unsupported_cln_version: {
    stage: "rpc",
    title: "CLN version unsupported",
    summary: "The connected node is older than the application requires.",
    retryable: false,
    suggestions: ["Upgrade CLN or use a feature compatible with the reported version."]
  },
  invalid_params: {
    stage: "rpc",
    title: "Invalid RPC parameters",
    summary: "CLN rejected the supplied method parameters.",
    retryable: false,
    suggestions: ["Compare the parameters with the RPC documentation for this CLN version."]
  },
  invalid_rpc_response: {
    stage: "rpc",
    title: "Invalid CLN response",
    summary: "CLN returned a response that violated the SDK's expected safety constraints.",
    retryable: false,
    suggestions: ["Check the node's CLN version and report the preserved RPC details."]
  },
  rpc_timeout: {
    stage: "rpc",
    title: "CLN wait timed out",
    summary: "A CLN-side wait reached its configured deadline without an event.",
    retryable: true,
    suggestions: ["This is expected for finite long polls; continue waiting when appropriate."]
  },
  request_timeout: {
    stage: "rpc",
    title: "Local request timed out",
    summary: "The browser stopped waiting before the RPC completed.",
    retryable: true,
    suggestions: ["Increase timeoutMs only when the RPC is safe to wait for or retry."]
  },
  request_aborted: {
    stage: "lifecycle",
    title: "Request cancelled",
    summary: "The application cancelled this connection or RPC operation.",
    retryable: true,
    suggestions: ["Start a new operation only if cancellation was not intentional."]
  },
  rpc_failed: {
    stage: "rpc",
    title: "CLN RPC failed",
    summary: "CLN returned an RPC error without a more specific stable SDK code.",
    retryable: false,
    suggestions: ["Inspect the preserved RPC code and data before deciding whether to retry."]
  },
  reconnect_exhausted: {
    stage: "lifecycle",
    title: "Connection retries exhausted",
    summary: "The connection manager reached its configured attempt limit.",
    retryable: true,
    suggestions: ["Fix the underlying error, then call retryNow() to begin another retry cycle."]
  },
  manager_stopped: {
    stage: "lifecycle",
    title: "Connection manager stopped",
    summary: "This manager was permanently stopped and cannot create another session.",
    retryable: false,
    suggestions: ["Create a new connection manager instance when another session is needed."]
  }
});

const UNKNOWN_TROUBLESHOOTING: TroubleshootingDefinition = Object.freeze({
  stage: "unknown",
  title: "Unexpected connection error",
  summary: "The failure did not contain a stable Zaptunnel error code.",
  retryable: false,
  suggestions: ["Capture the browser console details and report what operation failed."]
});

/** Turn an SDK error into safe, user-facing troubleshooting data. */
export function diagnoseZaptunnelError(error: unknown): ZaptunnelTroubleshooting {
  const chain = zaptunnelErrorChain(error);
  const primary = chain[0];
  const underlying = chain.find((item) => item.code !== "reconnect_exhausted") ?? primary;
  const primaryDefinition = troubleshootingDefinition(primary?.code);
  const underlyingDefinition = troubleshootingDefinition(underlying?.code);
  const definition = primaryDefinition ?? underlyingDefinition ?? UNKNOWN_TROUBLESHOOTING;
  const suggestions = [
    ...definition.suggestions,
    ...(underlyingDefinition && underlyingDefinition !== definition
      ? underlyingDefinition.suggestions
      : [])
  ].filter((suggestion, index, all) => all.indexOf(suggestion) === index);

  return {
    code: primary?.code ?? "unknown_error",
    causeCode: underlying && underlying !== primary ? underlying.code : undefined,
    stage: underlyingDefinition?.stage ?? definition.stage,
    title: definition.title,
    summary: underlyingDefinition?.summary ?? definition.summary,
    retryable: definition.retryable || underlyingDefinition?.retryable === true,
    requestId: chain.find((item) => item.requestId)?.requestId,
    suggestions: Object.freeze(suggestions)
  };
}

function troubleshootingDefinition(code: unknown): TroubleshootingDefinition | undefined {
  return typeof code === "string" && Object.hasOwn(TROUBLESHOOTING, code)
    ? TROUBLESHOOTING[code]
    : undefined;
}

function zaptunnelErrorChain(error: unknown): ZaptunnelError[] {
  const chain: ZaptunnelError[] = [];
  const seen = new Set<unknown>();
  let current = error;

  for (let depth = 0; depth < 8 && current !== undefined && !seen.has(current); depth += 1) {
    seen.add(current);
    if (current instanceof ZaptunnelError) chain.push(current);
    current = current instanceof Error ? current.cause : undefined;
  }

  return chain;
}

export class ClnCapabilities {
  readonly versionRaw: string;
  readonly version: ClnVersion | null;
  readonly methods: readonly string[];
  #methodSet: Set<string>;

  constructor(versionRaw: string, methods: Iterable<string>) {
    this.versionRaw = versionRaw;
    this.version = parseClnVersion(versionRaw);
    this.methods = Object.freeze([...new Set(methods)].sort());
    this.#methodSet = new Set(this.methods);
  }

  supports(method: string): boolean {
    return this.#methodSet.has(method);
  }

  require(method: string): void {
    if (!this.supports(method)) {
      throw new ZaptunnelError(`the connected CLN node does not expose the ${method} RPC method`, {
        code: "unsupported_method"
      });
    }
  }

  isVersionAtLeast(required: string | ClnVersion): boolean {
    return this.version !== null && compareClnVersions(this.version, required) >= 0;
  }

  requireVersion(required: string | ClnVersion): void {
    if (!this.isVersionAtLeast(required)) {
      const minimum = typeof required === "string" ? required : required.raw;
      throw new ZaptunnelError(`CLN ${minimum} or newer is required; connected node reports ${this.versionRaw}`, {
        code: "unsupported_cln_version"
      });
    }
  }
}

export class ZaptunnelClient {
  readonly nodeId: string;
  readonly address: string;
  readonly publicKey: string;
  readonly requestId?: string;
  readonly paymentLease?: string;
  readonly paymentLeaseExpiresAt?: number;

  #rune?: string;
  #transport: Lnmessage;
  #disconnectCleanup?: () => void;
  #privateKey: string;
  #lastTransportError?: ZaptunnelError;
  #transportAbort = new AbortController();
  #partialCommandoBytes = new Map<string, number>();
  #partialCommandoTotalBytes = 0;

  constructor(
    transport: Lnmessage,
    options: Pick<ConnectOptions, "nodeId" | "address" | "rune">,
    disconnectCleanup?: () => void,
    requestId?: string,
    paymentLease?: string,
    paymentLeaseExpiresAt?: number
  ) {
    this.#transport = transport;
    this.#rune = options.rune;
    const transportErrors = transport.connectionErrors$?.subscribe((error) => {
      this.#lastTransportError = normalizeTransportError(error, requestId);
      this.#transportAbort.abort();
    });
    const transportStatus = transport.connectionStatus$?.subscribe((status) => {
      if (status === "disconnected" || status === "failed") this.#transportAbort.abort();
    });
    const decryptedMessages = transport.decryptedMsgs$?.subscribe((message) => {
      this.#trackPartialCommandoResponse(message, requestId);
    });
    this.#disconnectCleanup = () => {
      transportErrors?.unsubscribe();
      transportStatus?.unsubscribe();
      decryptedMessages?.unsubscribe();
      disconnectCleanup?.();
    };
    this.nodeId = options.nodeId;
    this.address = options.address;
    this.publicKey = transport.publicKey;
    this.#privateKey = transport.privateKey;
    this.requestId = requestId;
    this.paymentLease = paymentLease;
    this.paymentLeaseExpiresAt = paymentLeaseExpiresAt;
  }

  /** Persistent BOLT-8 identity. Treat this value as a secret. */
  get privateKey(): string {
    return this.#privateKey;
  }

  /** Most recent fatal authenticated-transport error, if one occurred. */
  get lastTransportError(): ZaptunnelError | undefined {
    return this.#lastTransportError;
  }

  /** Invoke any CLN JSON-RPC method through Commando. */
  async call<T = unknown>(method: string, params: RpcParams = [], options: RpcCallOptions = {}): Promise<T> {
    const rune = options.rune ?? this.#rune;

    if (!rune) {
      throw new ZaptunnelError("a Commando rune is required for RPC calls", { code: "rune_required" });
    }

    validateCallControls(options);

    if (options.signal?.aborted) {
      throw requestControlError(method, "request_aborted", "the CLN RPC request was aborted");
    }

    if (this.#transportAbort.signal.aborted) {
      throw (
        this.#lastTransportError ??
        new ZaptunnelRpcError("the Lightning transport is disconnected", {
          code: "connection_closed",
          method
        })
      );
    }

    const operation = this.#transport.commando({ method, params, rune }) as Promise<T>;
    return await controlRpcOperation(
      operation,
      method,
      options,
      this.#transportAbort.signal,
      () => this.#lastTransportError
    );
  }

  getInfo<T = GetInfoResponse>(options: RpcCallOptions = {}): Promise<T> {
    return this.getinfo<T>(options);
  }

  getinfo<T = GetInfoResponse>(options: RpcCallOptions = {}): Promise<T> {
    return this.call<T>("getinfo", [], options);
  }

  invoice<T = unknown>(params: Record<string, unknown>, options: RpcCallOptions = {}): Promise<T> {
    return this.call<T>("invoice", params, options);
  }

  async getCapabilities(options: RpcCallOptions = {}): Promise<ClnCapabilities> {
    const [info, help] = await Promise.all([
      this.call<Pick<GetInfoResponse, "version">>("getinfo", [], options),
      this.call<{ help: Array<{ command: string }> }>("help", [], options)
    ]);

    const methods = help.help
      .map(({ command }) => command.trim().split(/\s+/, 1)[0])
      .filter((method): method is string => Boolean(method));

    return new ClnCapabilities(info.version, methods);
  }

  async waitAnyInvoice(options: WaitAnyInvoiceOptions = {}): Promise<PaidInvoice> {
    validateNonNegativeInteger(options.lastPayIndex, "lastPayIndex");
    validateNonNegativeInteger(options.waitTimeoutSeconds, "waitTimeoutSeconds");

    const waitTimeoutSeconds = options.waitTimeoutSeconds ?? 30;
    const params: Record<string, number> = { timeout: waitTimeoutSeconds };
    if (options.lastPayIndex !== undefined) params.lastpay_index = options.lastPayIndex;

    const timeoutMs = options.timeoutMs ?? waitTimeoutSeconds * 1_000 + 5_000;

    return await this.call<PaidInvoice>("waitanyinvoice", params, {...options, timeoutMs});
  }

  async *paidInvoices(options: PaidInvoiceStreamOptions = {}): AsyncGenerator<PaidInvoice, void, void> {
    const waitTimeoutSeconds = options.waitTimeoutSeconds ?? 30;
    const timeoutGraceMs = options.timeoutGraceMs ?? 5_000;
    const retryDelayMs = options.retryDelayMs ?? 250;
    let lastPayIndex = options.lastPayIndex ?? 0;

    validateNonNegativeInteger(lastPayIndex, "lastPayIndex");
    validateNonNegativeInteger(waitTimeoutSeconds, "waitTimeoutSeconds");
    validateNonNegativeInteger(timeoutGraceMs, "timeoutGraceMs");
    validateNonNegativeInteger(retryDelayMs, "retryDelayMs");

    while (!options.signal?.aborted) {
      try {
        const invoice = await this.waitAnyInvoice({
          lastPayIndex,
          waitTimeoutSeconds,
          timeoutMs: waitTimeoutSeconds * 1_000 + timeoutGraceMs,
          rune: options.rune,
          signal: options.signal
        });

        if (!Number.isSafeInteger(invoice.pay_index) || invoice.pay_index <= lastPayIndex) {
          throw new ZaptunnelRpcError("CLN returned an invalid pay_index from waitanyinvoice", {
            code: "invalid_rpc_response",
            method: "waitanyinvoice"
          });
        }

        lastPayIndex = invoice.pay_index;
        yield invoice;
      } catch (error) {
        if (options.signal?.aborted && error instanceof ZaptunnelError && error.code === "request_aborted") {
          return;
        }

        if (
          error instanceof ZaptunnelRpcError &&
          (error.code === "rpc_timeout" || error.rpcCode === 904)
        ) {
          await waitForAbortableDelay(retryDelayMs, options.signal);
          continue;
        }

        throw error;
      }
    }
  }

  disconnect(): void {
    this.#transportAbort.abort();
    this.#disconnectCleanup?.();
    this.#disconnectCleanup = undefined;
    this.#transport.disconnect();
  }

  /** Observe the stable, high-level state of the underlying Lightning connection. */
  onConnectionStatus(listener: (status: ZaptunnelConnectionStatus) => void): () => void {
    const subscription = this.#transport.connectionStatus$.subscribe(listener);
    return () => subscription.unsubscribe();
  }

  #trackPartialCommandoResponse(message: Uint8Array, requestId?: string): void {
    const type = readUint16(message, 0);
    if (type !== COMMANDO_RESPONSE_CONTINUES_MESSAGE_TYPE && type !== COMMANDO_RESPONSE_MESSAGE_TYPE) {
      return;
    }
    if (message.byteLength < 10) return;

    const responseId = bytesToHex(message.subarray(2, 10));
    const previous = this.#partialCommandoBytes.get(responseId) ?? 0;

    if (type === COMMANDO_RESPONSE_MESSAGE_TYPE) {
      this.#partialCommandoBytes.delete(responseId);
      this.#partialCommandoTotalBytes -= previous;
      return;
    }

    const next = previous + message.byteLength;
    this.#partialCommandoBytes.set(responseId, next);
    this.#partialCommandoTotalBytes += message.byteLength;

    if (
      this.#partialCommandoBytes.size > MAX_PARTIAL_COMMANDO_RESPONSES ||
      next > MAX_PARTIAL_COMMANDO_BYTES ||
      this.#partialCommandoTotalBytes > MAX_PARTIAL_COMMANDO_BYTES
    ) {
      this.#lastTransportError = new ZaptunnelError(
        "the peer exceeded the partial Commando response budget",
        { code: "transport_resource_limit", requestId }
      );
      this.#transportAbort.abort();
      this.#transport.disconnect();
    }
  }
}

async function waitForAbortableDelay(delayMs: number, signal?: AbortSignal): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(new ZaptunnelError("the operation was aborted", { code: "request_aborted" }));
      return;
    }

    const timer = setTimeout(finish, delayMs);
    signal?.addEventListener("abort", abort, { once: true });

    function finish() {
      signal?.removeEventListener("abort", abort);
      resolve();
    }

    function abort() {
      clearTimeout(timer);
      reject(new ZaptunnelError("the operation was aborted", { code: "request_aborted" }));
    }
  });
}

/** Request admission and establish an end-to-end BOLT-8 session with CLN. */
export async function connect(options: ConnectOptions): Promise<ZaptunnelClient> {
  validateNodeId(options.nodeId);
  if (options.chainHash !== undefined) validateChainHash(options.chainHash);
  validateNonNegativeInteger(options.connectionTimeoutMs, "connectionTimeoutMs");
  const { host, port } = parseAddress(options.address);
  const relay = parseRelay(options.relay ?? DEFAULT_RELAY, options.allowInsecureRelay ?? false);
  const admission = await requestAdmission(relay, options, globalThis.fetch);
  const websocketUrl = new URL(admission.websocket_path, relay);
  websocketUrl.protocol = websocketUrl.protocol === "https:" ? "wss:" : "ws:";

  const transport = new Lnmessage({
    remoteNodePublicKey: options.nodeId.toLowerCase(),
    ip: host,
    port,
    wsProxy: websocketUrl.toString().replace(/\/$/, ""),
    privateKey: options.privateKey
  });
  let initialTransportError: ZaptunnelError | undefined;
  const transportErrorSubscription = transport.connectionErrors$.subscribe((error) => {
    initialTransportError = normalizeTransportError(error, admission.request_id);
  });
  let transportErrorSubscriptionTransferred = false;

  let gossipFilterError: unknown;
  const gossipSubscription = transport.decryptedMsgs$.subscribe((message) => {
    if (readUint16(message, 0) !== INIT_MESSAGE_TYPE) return;

    const chainHash =
      options.chainHash?.toLowerCase() ?? extractInitChainHash(message) ?? BITCOIN_MAINNET_CHAIN_HASH;

    try {
      const BufferConstructor = message.constructor as unknown as {
        from(bytes: Uint8Array): typeof message;
      };
      if (!transport.socket) throw new Error("the Lightning socket is not available");

      const plaintext = BufferConstructor.from(encodeRestrictiveGossipTimestampFilter(chainHash));
      const encrypted = transport.noise.encryptMessage(plaintext);
      transport.socket.send(encrypted);
    } catch (error) {
      gossipFilterError = error;
      options.logger?.error("Failed to send the restrictive BOLT 7 gossip filter");
    }
  });

  try {
    if (options.signal?.aborted) {
      throw new ZaptunnelError("the Lightning connection attempt was aborted", {
        code: "request_aborted",
        requestId: admission.request_id
      });
    }

    // A relay ticket can be redeemed only once. Reusing the same wsProxy URL
    // through lnmessage's built-in reconnect can never establish a new relay
    // session, so resilient reconnects belong to ZaptunnelConnectionManager.
    const connected = await controlConnectionOperation(
      transport.connect(false),
      options.signal,
      options.connectionTimeoutMs ?? DEFAULT_CONNECTION_TIMEOUT_MS,
      () => transport.disconnect(),
      admission.request_id
    );

    if (!connected) {
      throw (
        initialTransportError ??
        new ZaptunnelError("the Lightning connection closed during its BOLT-8 handshake", {
          code: "connection_closed",
          requestId: admission.request_id
        })
      );
    }

    if (gossipFilterError) {
      throw new ZaptunnelError("failed to configure the Lightning gossip filter", {
        code: "gossip_filter_failed",
        requestId: admission.request_id,
        cause: gossipFilterError
      });
    }

    const client = new ZaptunnelClient(
      transport,
      options,
      () => {
        transportErrorSubscription.unsubscribe();
        gossipSubscription.unsubscribe();
      },
      admission.request_id,
      admission.lease,
      admission.lease_expires_at
    );
    transportErrorSubscriptionTransferred = true;
    return client;
  } catch (error) {
    gossipSubscription.unsubscribe();
    if (!transportErrorSubscriptionTransferred) transportErrorSubscription.unsubscribe();
    transport.disconnect();

    if (error instanceof ZaptunnelError) throw error;
    throw new ZaptunnelError("failed to establish the Lightning connection", {
      code: "connection_failed",
      requestId: admission.request_id,
      cause: error
    });
  }
}

type NormalizedReconnectPolicy = Required<ReconnectPolicy>;

const DEFAULT_RECONNECT_POLICY: Readonly<NormalizedReconnectPolicy> = Object.freeze({
  minDelayMs: 1_000,
  maxDelayMs: 30_000,
  multiplier: 2,
  jitter: 0.2,
  maxAttempts: Number.POSITIVE_INFINITY
});

type ConnectionWaiter = {
  resolve(client: ZaptunnelClient): void;
  reject(error: ZaptunnelError): void;
};

/**
 * Owns a sequence of fresh, single-admission Lightning sessions.
 *
 * Ordinary RPC calls are delegated exactly once. Only connection setup and the
 * cursor-based paid-invoice stream are automatically resumed.
 */
export class ZaptunnelConnectionManager {
  readonly nodeId: string;
  readonly address: string;

  #options: Omit<ConnectOptions, "signal">;
  #retry: NormalizedReconnectPolicy;
  #identityStore?: ZaptunnelIdentityStore;
  #privateKey?: string;
  #savedPrivateKey?: string;
  #identityLoaded = false;
  #client: ZaptunnelClient | null = null;
  #sessionAbort: AbortController | null = null;
  #clientStatusCleanup?: () => void;
  #attemptAbort: AbortController | null = null;
  #attemptInFlight = false;
  #attempts = 0;
  #retryTimer?: ReturnType<typeof setTimeout>;
  #nextRetryAt: number | null = null;
  #started = false;
  #stopped = false;
  #status: ZaptunnelManagerStatus = "idle";
  #lastError?: unknown;
  #terminalError?: ZaptunnelError;
  #listeners = new Set<(status: ZaptunnelManagerStatus) => void>();
  #stateListeners = new Set<(state: ZaptunnelManagerState) => void>();
  #waiters = new Set<ConnectionWaiter>();
  #onlineListener = () => this.#resumeAfterLifecycleEvent();
  #visibilityListener = () => {
    if (typeof document === "undefined" || document.visibilityState === "visible") {
      this.#resumeAfterLifecycleEvent();
    }
  };

  constructor(options: ConnectionManagerOptions) {
    validateNodeId(options.nodeId);
    parseAddress(options.address);
    if (options.chainHash !== undefined) validateChainHash(options.chainHash);

    const { retry, identityStore, ...connectionOptions } = options;
    this.#retry = normalizeReconnectPolicy(retry);
    this.#identityStore = identityStore;
    this.#privateKey = options.privateKey;
    this.nodeId = options.nodeId.toLowerCase();
    this.#options = { ...connectionOptions, nodeId: this.nodeId, reconnect: false };
    this.address = options.address;
  }

  get status(): ZaptunnelManagerStatus {
    return this.#status;
  }

  get currentClient(): ZaptunnelClient | null {
    return this.#client;
  }

  get privateKey(): string | undefined {
    return this.#privateKey;
  }

  get publicKey(): string | undefined {
    return this.#client?.publicKey;
  }

  get requestId(): string | undefined {
    return this.#client?.requestId;
  }

  get lastError(): unknown {
    return this.#lastError;
  }

  /** A point-in-time lifecycle snapshot suitable for troubleshooting UI. */
  get connectionState(): ZaptunnelManagerState {
    const error = this.#terminalError ?? this.#lastError;
    const diagnostic = error === undefined ? undefined : diagnoseZaptunnelError(error);
    return {
      status: this.#status,
      attempt: this.#attempts,
      nextRetryAt: this.#nextRetryAt,
      retryInMs:
        this.#nextRetryAt === null ? null : Math.max(0, this.#nextRetryAt - Date.now()),
      requestId: this.#client?.requestId ?? diagnostic?.requestId,
      diagnostic
    };
  }

  /** Start the lifecycle and resolve when the current session is connected. */
  start(): Promise<ZaptunnelClient> {
    return this.#waitForClient();
  }

  /** Stop permanently, cancel pending retries, and close the current session. */
  stop(): void {
    if (this.#stopped) return;

    this.#stopped = true;
    this.#clearRetryTimer();
    this.#attemptAbort?.abort();
    this.#attemptAbort = null;
    this.#dropClient();
    this.#detachBrowserLifecycle();
    this.#setStatus("stopped");

    const error = managerStoppedError();
    for (const waiter of this.#waiters) waiter.reject(error);
    this.#waiters.clear();
  }

  /** Retry immediately after an offline period or an exhausted finite policy. */
  retryNow(): void {
    if (!this.#started || this.#stopped || this.#client || this.#attemptInFlight) return;
    if (!browserIsOnline()) return;

    this.#terminalError = undefined;
    this.#attempts = 0;
    this.#scheduleReconnect(0, true);
  }

  /** Subscribe to manager lifecycle state. The current state is delivered immediately. */
  onConnectionStatus(listener: (status: ZaptunnelManagerStatus) => void): () => void {
    this.#listeners.add(listener);
    this.#notifyListener(listener, this.#status);
    return () => this.#listeners.delete(listener);
  }

  /** Subscribe to detailed lifecycle snapshots. The current snapshot is delivered immediately. */
  onConnectionState(listener: (state: ZaptunnelManagerState) => void): () => void {
    this.#stateListeners.add(listener);
    this.#notifyStateListener(listener, this.connectionState);
    return () => this.#stateListeners.delete(listener);
  }

  /** Invoke one RPC on one connected session. It is never replayed after failure. */
  async call<T = unknown>(
    method: string,
    params: RpcParams = [],
    options: RpcCallOptions = {}
  ): Promise<T> {
    const client = await this.#waitForClient(options.signal);
    return await client.call<T>(method, params, options);
  }

  getInfo<T = GetInfoResponse>(options: RpcCallOptions = {}): Promise<T> {
    return this.getinfo<T>(options);
  }

  getinfo<T = GetInfoResponse>(options: RpcCallOptions = {}): Promise<T> {
    return this.call<T>("getinfo", [], options);
  }

  invoice<T = unknown>(params: Record<string, unknown>, options: RpcCallOptions = {}): Promise<T> {
    return this.call<T>("invoice", params, options);
  }

  async getCapabilities(options: RpcCallOptions = {}): Promise<ClnCapabilities> {
    const client = await this.#waitForClient(options.signal);
    return await client.getCapabilities(options);
  }

  async waitAnyInvoice(options: WaitAnyInvoiceOptions = {}): Promise<PaidInvoice> {
    const client = await this.#waitForClient(options.signal);
    return await client.waitAnyInvoice(options);
  }

  /**
   * Resume paid-invoice polling on every fresh session without losing the
   * monotonic pay_index cursor. Persist each yielded cursor in application
   * storage if recovery across a page reload is required.
   */
  async *paidInvoices(options: PaidInvoiceStreamOptions = {}): AsyncGenerator<PaidInvoice, void, void> {
    let lastPayIndex = options.lastPayIndex ?? 0;
    validateNonNegativeInteger(lastPayIndex, "lastPayIndex");

    while (!this.#stopped && !options.signal?.aborted) {
      let client: ZaptunnelClient;

      try {
        client = await this.#waitForClient(options.signal);
      } catch (error) {
        if (options.signal?.aborted || this.#stopped) return;
        throw error;
      }

      const sessionAbort = this.#sessionAbort;
      if (!sessionAbort) continue;
      const linked = linkAbortSignals(options.signal, sessionAbort.signal);

      try {
        for await (const invoice of client.paidInvoices({
          ...options,
          lastPayIndex,
          signal: linked.signal
        })) {
          lastPayIndex = invoice.pay_index;
          yield invoice;
        }
      } catch (error) {
        if (options.signal?.aborted || this.#stopped) return;
        if (client !== this.#client || sessionAbort.signal.aborted) continue;
        throw error;
      } finally {
        linked.cleanup();
      }
    }
  }

  /** Test seam for alternate transports; production always calls connect(). */
  protected establishConnection(options: ConnectOptions): Promise<ZaptunnelClient> {
    return connect(options);
  }

  async #attemptConnection(): Promise<void> {
    if (this.#stopped || this.#client || this.#attemptInFlight) return;

    if (!browserIsOnline()) {
      this.#setStatus("waiting_reconnect");
      return;
    }

    this.#attemptInFlight = true;
    this.#attempts += 1;
    this.#setStatus("connecting");
    const controller = new AbortController();
    this.#attemptAbort = controller;

    try {
      await this.#loadIdentity();
      if (controller.signal.aborted) return;
      const client = await this.establishConnection({
        ...this.#options,
        privateKey: this.#privateKey,
        reconnect: false,
        signal: controller.signal
      });

      if (this.#stopped) {
        client.disconnect();
        return;
      }

      this.#client = client;
      this.#sessionAbort = new AbortController();
      this.#attempts = 0;
      this.#lastError = undefined;
      this.#terminalError = undefined;
      this.#privateKey = client.privateKey;
      if (client.paymentLease) this.#options.paymentLease = client.paymentLease;

      this.#clientStatusCleanup = client.onConnectionStatus((status) => {
        if (client !== this.#client) return;
        if (status === "disconnected" || status === "failed") this.#handleConnectionLoss(client);
      });

      void this.#saveIdentity(client.privateKey);
      this.#setStatus("connected");
      for (const waiter of this.#waiters) waiter.resolve(client);
      this.#waiters.clear();
    } catch (error) {
      if (this.#stopped || controller.signal.aborted) return;

      const failure = normalizeConnectionAttemptError(error);
      this.#lastError = failure;
      const retryable = diagnoseZaptunnelError(failure).retryable;

      if (!retryable) {
        this.#terminalError = failure;
        this.#setStatus("failed");
        for (const waiter of this.#waiters) waiter.reject(failure);
        this.#waiters.clear();
      } else if (this.#attempts >= this.#retry.maxAttempts) {
        this.#terminalError = new ZaptunnelError("connection retry attempts were exhausted", {
          code: "reconnect_exhausted",
          requestId: failure.requestId,
          cause: failure
        });
        this.#setStatus("failed");
        for (const waiter of this.#waiters) waiter.reject(this.#terminalError);
        this.#waiters.clear();
      } else {
        const delay = calculateReconnectDelay(this.#attempts, this.#retry);
        this.#setStatus("waiting_reconnect");
        this.#scheduleReconnect(delay);
      }
    } finally {
      if (this.#attemptAbort === controller) this.#attemptAbort = null;
      this.#attemptInFlight = false;
    }
  }

  #handleConnectionLoss(client: ZaptunnelClient): void {
    if (client !== this.#client || this.#stopped) return;
    this.#lastError =
      client.lastTransportError ??
      new ZaptunnelError("the active Lightning connection closed", {
        code: "connection_closed",
        requestId: client.requestId
      });
    this.#dropClient();
    this.#attempts = 0;
    this.#setStatus("waiting_reconnect");
    this.#scheduleReconnect(this.#retry.minDelayMs);
  }

  #resumeAfterLifecycleEvent(): void {
    if (
      !this.#started ||
      this.#stopped ||
      this.#client ||
      this.#attemptInFlight ||
      this.#terminalError ||
      !browserIsOnline()
    ) {
      return;
    }

    this.#scheduleReconnect(this.#retry.minDelayMs);
  }

  #dropClient(): void {
    const client = this.#client;
    this.#client = null;
    this.#clientStatusCleanup?.();
    this.#clientStatusCleanup = undefined;
    this.#sessionAbort?.abort();
    this.#sessionAbort = null;
    client?.disconnect();
  }

  #scheduleReconnect(delayMs: number, replace = false): void {
    if (this.#stopped || this.#client) return;
    if (replace) this.#clearRetryTimer();
    if (this.#retryTimer !== undefined) return;

    this.#nextRetryAt = Date.now() + delayMs;
    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = undefined;
      this.#nextRetryAt = null;
      this.#emitState();
      void this.#attemptConnection();
    }, delayMs);
    this.#emitState();
  }

  #clearRetryTimer(): void {
    if (this.#retryTimer !== undefined) clearTimeout(this.#retryTimer);
    this.#retryTimer = undefined;
    if (this.#nextRetryAt !== null) {
      this.#nextRetryAt = null;
      this.#emitState();
    }
  }

  async #waitForClient(signal?: AbortSignal): Promise<ZaptunnelClient> {
    if (this.#client) return this.#client;
    if (this.#stopped) throw managerStoppedError();
    if (this.#terminalError) throw this.#terminalError;
    if (signal?.aborted) {
      throw new ZaptunnelError("connection wait aborted", { code: "request_aborted" });
    }

    if (!this.#started) {
      this.#started = true;
      this.#attachBrowserLifecycle();
      this.#scheduleReconnect(0);
    }

    return await new Promise<ZaptunnelClient>((resolve, reject) => {
      const abort = () => {
        this.#waiters.delete(waiter);
        reject(new ZaptunnelError("connection wait aborted", { code: "request_aborted" }));
      };
      const cleanup = () => signal?.removeEventListener("abort", abort);
      const waiter: ConnectionWaiter = {
        resolve: (client) => {
          cleanup();
          resolve(client);
        },
        reject: (error) => {
          cleanup();
          reject(error);
        }
      };

      this.#waiters.add(waiter);
      signal?.addEventListener("abort", abort, { once: true });
    });
  }

  async #loadIdentity(): Promise<void> {
    if (this.#identityLoaded) return;
    this.#identityLoaded = true;
    if (this.#privateKey || !this.#identityStore) return;

    try {
      this.#privateKey = await this.#identityStore.loadPrivateKey(this.nodeId);
      this.#savedPrivateKey = this.#privateKey;
    } catch {
      this.#options.logger?.warn("Could not load the persisted Zaptunnel browser identity");
    }
  }

  async #saveIdentity(privateKey: string): Promise<void> {
    if (!this.#identityStore || this.#savedPrivateKey === privateKey) return;

    try {
      await this.#identityStore.savePrivateKey(this.nodeId, privateKey);
      this.#savedPrivateKey = privateKey;
    } catch {
      this.#options.logger?.warn("Could not save the Zaptunnel browser identity");
    }
  }

  #setStatus(status: ZaptunnelManagerStatus): void {
    if (status === this.#status) {
      this.#emitState();
      return;
    }
    this.#status = status;
    for (const listener of this.#listeners) this.#notifyListener(listener, status);
    this.#emitState();
  }

  #emitState(): void {
    const state = this.connectionState;
    for (const listener of this.#stateListeners) this.#notifyStateListener(listener, state);
  }

  #notifyStateListener(
    listener: (state: ZaptunnelManagerState) => void,
    state: ZaptunnelManagerState
  ): void {
    try {
      listener(state);
    } catch {
      this.#options.logger?.error("Zaptunnel connection-state listener failed");
    }
  }

  #notifyListener(
    listener: (status: ZaptunnelManagerStatus) => void,
    status: ZaptunnelManagerStatus
  ): void {
    try {
      listener(status);
    } catch {
      this.#options.logger?.error("Zaptunnel connection-status listener failed");
    }
  }

  #attachBrowserLifecycle(): void {
    globalThis.addEventListener?.("online", this.#onlineListener);
    if (typeof document !== "undefined") {
      document.addEventListener("visibilitychange", this.#visibilityListener);
    }
  }

  #detachBrowserLifecycle(): void {
    globalThis.removeEventListener?.("online", this.#onlineListener);
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", this.#visibilityListener);
    }
  }
}

export function createConnectionManager(options: ConnectionManagerOptions): ZaptunnelConnectionManager {
  return new ZaptunnelConnectionManager(options);
}

/** Calculate the jittered delay after a one-based consecutive failure count. */
export function calculateReconnectDelay(
  failureCount: number,
  policy: ReconnectPolicy = {},
  random: () => number = Math.random
): number {
  const normalized = normalizeReconnectPolicy(policy);
  const exponent = Math.max(0, failureCount - 1);
  const base = Math.min(normalized.maxDelayMs, normalized.minDelayMs * normalized.multiplier ** exponent);
  const variation = base * normalized.jitter;
  const jittered = base - variation + random() * variation * 2;
  return Math.min(normalized.maxDelayMs, Math.max(0, Math.round(jittered)));
}

/** Encode a BOLT 7 filter that requests no relayed historical or future gossip. */
export function encodeRestrictiveGossipTimestampFilter(chainHash: string): Uint8Array {
  validateChainHash(chainHash);

  const message = new Uint8Array(42);
  const view = new DataView(message.buffer);
  view.setUint16(0, GOSSIP_TIMESTAMP_FILTER_MESSAGE_TYPE);
  message.set(hexToBytes(chainHash), 2);
  view.setUint32(34, NO_GOSSIP_FIRST_TIMESTAMP);
  view.setUint32(38, NO_GOSSIP_TIMESTAMP_RANGE);
  return message;
}

/** Extract the first BOLT `networks` chain hash from an init message, if present. */
export function extractInitChainHash(message: Uint8Array): string | null {
  if (readUint16(message, 0) !== INIT_MESSAGE_TYPE) return null;

  let offset = 2;
  const globalFeaturesLength = readUint16(message, offset);
  if (globalFeaturesLength === null) return null;
  offset += 2 + globalFeaturesLength;

  const localFeaturesLength = readUint16(message, offset);
  if (localFeaturesLength === null) return null;
  offset += 2 + localFeaturesLength;

  while (offset < message.length) {
    const type = readBigSize(message, offset);
    if (!type) return null;
    offset = type.nextOffset;

    const length = readBigSize(message, offset);
    if (!length || length.value > Number.MAX_SAFE_INTEGER) return null;
    offset = length.nextOffset;

    const end = offset + Number(length.value);
    if (end > message.length) return null;

    if (type.value === 1n) {
      if (length.value < 32n || length.value % 32n !== 0n) return null;
      return bytesToHex(message.subarray(offset, offset + 32));
    }

    offset = end;
  }

  return null;
}

async function requestAdmission(
  relay: URL,
  options: Pick<ConnectOptions, "nodeId" | "address" | "signal" | "payment" | "paymentLease">,
  fetcher: typeof fetch
): Promise<AdmissionResponse> {
  type PaymentBody = Partial<AdmissionResponse> & {
    amount_sats?: number;
    claim_path?: string;
    claim_token?: string;
    error?: string;
    expires_at?: number;
    invoice?: string;
    payment_hash?: string;
    protocol?: string;
    quote_id?: string;
    retry_after_ms?: number;
  };

  const send = async (
    authorization?: string,
    lease: string | undefined = options.paymentLease
  ): Promise<{ response: Response; body: PaymentBody }> => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (authorization) headers.authorization = authorization;
    if (lease) headers["x-zaptunnel-lease"] = lease;

    const response = await fetcher(new URL("/v1/connections", relay), {
      method: "POST",
      headers,
      body: JSON.stringify({ node_id: options.nodeId.toLowerCase(), address: options.address }),
      signal: options.signal
    });

    return { response, body: (await response.json().catch(() => ({}))) as PaymentBody };
  };

  let attempt: { response: Response; body: PaymentBody };
  let recoveredLease = options.paymentLease;

  if (options.payment?.store && !options.paymentLease) {
    const savedClaim = await options.payment.store.loadClaim(options.nodeId.toLowerCase());

    if (savedClaim && validSavedClaim(savedClaim, relay, options.nodeId)) {
      options.payment.onStatus?.("waiting_settlement", savedClaim.challenge);

      try {
        const recovered = await pollPaymentClaim(savedClaim, options.signal, fetcher);
        recoveredLease = recovered.lease;
        options.payment.onStatus?.("settled", savedClaim.challenge);
      } catch (error) {
        if (
          !(error instanceof ZaptunnelError) ||
          !["payment_expired", "invalid_claim"].includes(error.code)
        ) {
          throw error;
        }

        await options.payment.store.clearClaim(options.nodeId.toLowerCase());
      }
    } else if (savedClaim) {
      await options.payment.store.clearClaim(options.nodeId.toLowerCase());
    }
  }

  try {
    attempt = await send(undefined, recoveredLease);
  } catch (error) {
    if (options.signal?.aborted) {
      throw new ZaptunnelError("the relay admission request was aborted", {
        code: "request_aborted",
        cause: error
      });
    }

    throw new ZaptunnelError("could not reach the Zaptunnel relay", {
      code: "relay_unreachable",
      cause: error
    });
  }

  if (attempt.response.status === 402 && attempt.body.error === "payment_required") {
    const challenge = parsePaymentChallenge(attempt.body);
    const requestId = relayRequestId(attempt.body.request_id, attempt.response.headers);

    if (!options.payment) throw new ZaptunnelPaymentRequiredError(challenge, { requestId });
    const issuedClaim = parsePaymentClaim(relay, options.nodeId, challenge, attempt.body);

    await options.payment.store?.saveClaim(options.nodeId.toLowerCase(), issuedClaim);
    options.payment.onStatus?.("paying", challenge);

    try {
      await options.payment.payInvoice(challenge);
    } catch (error) {
      throw new ZaptunnelError("the wallet did not complete the connection payment", {
        code: "payment_failed",
        requestId,
        cause: error
      });
    }

    options.payment.onStatus?.("waiting_settlement", challenge);
    const claimed = await pollPaymentClaim(issuedClaim, options.signal, fetcher);
    options.payment.onStatus?.("settled", challenge);
    attempt = await send(undefined, claimed.lease);
  }

  return parseAdmissionAttempt(attempt, relay);
}

function parseAdmissionAttempt(attempt: {
  response: Response;
  body: Partial<AdmissionResponse> & { error?: string };
}, relay: URL): AdmissionResponse {
  const { response, body } = attempt;
  const requestId = relayRequestId(body.request_id, response.headers);

  if (!response.ok) {
    const code = typeof body.error === "string" ? body.error : "admission_failed";
    throw new ZaptunnelError(`Zaptunnel admission failed: ${code}`, {
      code,
      status: response.status,
      requestId
    });
  }

  if (!validWebsocketPath(body.websocket_path, relay)) {
    throw new ZaptunnelError("the relay returned an invalid admission response", {
      code: "invalid_relay_response",
      status: response.status,
      requestId
    });
  }

  return {
    websocket_path: body.websocket_path,
    request_id: requestId,
    lease: typeof body.lease === "string" ? body.lease : undefined,
    lease_expires_at: typeof body.lease_expires_at === "number" ? body.lease_expires_at : undefined
  };
}

function validWebsocketPath(path: unknown, relay: URL): path is string {
  if (
    typeof path !== "string" ||
    !path.startsWith("/") ||
    path.startsWith("//") ||
    /[\\\u0000-\u0020\u007f]/.test(path)
  ) {
    return false;
  }

  try {
    return new URL(path, relay).origin === relay.origin;
  } catch {
    return false;
  }
}

function relayRequestId(bodyValue: unknown, headers: Headers): string | undefined {
  const candidate = typeof bodyValue === "string" ? bodyValue : headers.get("x-request-id");
  return candidate && /^zt_[A-Za-z0-9_-]{16}$/.test(candidate) ? candidate : undefined;
}

function parsePaymentChallenge(body: {
  amount_sats?: number;
  expires_at?: number;
  invoice?: string;
  payment_hash?: string;
  protocol?: string;
  quote_id?: string;
}): ZaptunnelPaymentChallenge {
  if (
    !Number.isSafeInteger(body.amount_sats) ||
    (body.amount_sats ?? 0) <= 0 ||
    !Number.isSafeInteger(body.expires_at) ||
    typeof body.invoice !== "string" ||
    !body.invoice.startsWith("lni") ||
    !/^[0-9a-f]{64}$/.test(body.payment_hash ?? "") ||
    typeof body.quote_id !== "string" ||
    body.protocol !== "bolt12"
  ) {
    throw new ZaptunnelError("the relay returned an invalid payment challenge", {
      code: "invalid_relay_response",
      status: 402
    });
  }

  return Object.freeze({
    amountSats: body.amount_sats!,
    expiresAt: body.expires_at!,
    invoice: body.invoice,
    paymentHash: body.payment_hash!,
    protocol: "bolt12",
    quoteId: body.quote_id
  });
}

function parsePaymentClaim(
  relay: URL,
  nodeId: string,
  challenge: ZaptunnelPaymentChallenge,
  body: {
    claim_path?: string;
    claim_token?: string;
    expires_at?: number;
    quote_id?: string;
  }
): ZaptunnelPaymentClaim {
  if (
    typeof body.claim_path !== "string" ||
    !body.claim_path.startsWith("/") ||
    body.claim_path.startsWith("//") ||
    typeof body.claim_token !== "string" ||
    body.claim_token.length < 32 ||
    !Number.isSafeInteger(body.expires_at) ||
    typeof body.quote_id !== "string"
  ) {
    throw new ZaptunnelError("the relay returned an invalid payment claim", {
      code: "invalid_relay_response",
      status: 402
    });
  }

  return Object.freeze({
    relay: relay.origin,
    nodeId: nodeId.toLowerCase(),
    quoteId: body.quote_id,
    claimPath: body.claim_path,
    claimToken: body.claim_token,
    expiresAt: body.expires_at!,
    challenge
  });
}

function validSavedClaim(claim: ZaptunnelPaymentClaim, relay: URL, nodeId: string): boolean {
  return (
    claim.relay === relay.origin &&
    claim.nodeId === nodeId.toLowerCase() &&
    claim.claimPath.startsWith("/") &&
    !claim.claimPath.startsWith("//") &&
    claim.claimToken.length >= 32 &&
    claim.challenge?.quoteId === claim.quoteId
  );
}

async function pollPaymentClaim(
  claim: ZaptunnelPaymentClaim,
  signal: AbortSignal | undefined,
  fetcher: typeof fetch
): Promise<{ lease: string; leaseExpiresAt: number }> {
  const claimUrl = new URL(claim.claimPath, claim.relay);

  if (claimUrl.origin !== new URL(claim.relay).origin) {
    throw new ZaptunnelError("the saved payment claim points outside its relay", {
      code: "invalid_claim"
    });
  }

  while (true) {
    let response: Response;

    try {
      response = await fetcher(claimUrl, {
        method: "POST",
        headers: { authorization: `ZaptunnelClaim ${claim.claimToken}` },
        signal
      });
    } catch (error) {
      if (signal?.aborted) {
        throw new ZaptunnelError("payment settlement polling was aborted", {
          code: "request_aborted",
          cause: error
        });
      }

      throw new ZaptunnelError("could not poll the payment settlement", {
        code: "relay_unreachable",
        cause: error
      });
    }

    const body = (await response.json().catch(() => ({}))) as {
      error?: string;
      lease?: string;
      lease_expires_at?: number;
    };
    const requestId = relayRequestId(undefined, response.headers);

    if (response.status === 202 || response.status === 429) {
      const retrySeconds = Number(response.headers.get("retry-after") ?? "2");
      const retryMs = Number.isFinite(retrySeconds)
        ? Math.min(Math.max(retrySeconds * 1_000, 250), 30_000)
        : 2_000;
      await waitForPaymentPoll(retryMs, signal);
      continue;
    }

    if (response.ok) {
      if (typeof body.lease !== "string" || !Number.isSafeInteger(body.lease_expires_at)) {
        throw new ZaptunnelError("the relay returned an invalid paid claim", {
          code: "invalid_relay_response",
          status: response.status,
          requestId
        });
      }

      return { lease: body.lease, leaseExpiresAt: body.lease_expires_at! };
    }

    const code = body.error ?? "payment_status_unavailable";
    throw new ZaptunnelError(`Zaptunnel payment claim failed: ${code}`, {
      code,
      status: response.status,
      requestId
    });
  }
}

async function waitForPaymentPoll(delayMs: number, signal?: AbortSignal): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(new ZaptunnelError("payment settlement polling was aborted", { code: "request_aborted" }));
      return;
    }

    const timer = setTimeout(finish, delayMs);
    signal?.addEventListener("abort", abort, { once: true });

    function finish() {
      signal?.removeEventListener("abort", abort);
      resolve();
    }

    function abort() {
      clearTimeout(timer);
      reject(new ZaptunnelError("payment settlement polling was aborted", { code: "request_aborted" }));
    }
  });
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

function normalizeReconnectPolicy(policy: ReconnectPolicy = {}): NormalizedReconnectPolicy {
  const normalized = {
    minDelayMs: policy.minDelayMs ?? DEFAULT_RECONNECT_POLICY.minDelayMs,
    maxDelayMs: policy.maxDelayMs ?? DEFAULT_RECONNECT_POLICY.maxDelayMs,
    multiplier: policy.multiplier ?? DEFAULT_RECONNECT_POLICY.multiplier,
    jitter: policy.jitter ?? DEFAULT_RECONNECT_POLICY.jitter,
    maxAttempts: policy.maxAttempts ?? DEFAULT_RECONNECT_POLICY.maxAttempts
  };

  if (!Number.isSafeInteger(normalized.minDelayMs) || normalized.minDelayMs < 0) {
    throw invalidManagerOption("retry.minDelayMs must be a non-negative safe integer");
  }
  if (!Number.isSafeInteger(normalized.maxDelayMs) || normalized.maxDelayMs < normalized.minDelayMs) {
    throw invalidManagerOption("retry.maxDelayMs must be a safe integer at least retry.minDelayMs");
  }
  if (!Number.isFinite(normalized.multiplier) || normalized.multiplier < 1) {
    throw invalidManagerOption("retry.multiplier must be a finite number at least 1");
  }
  if (!Number.isFinite(normalized.jitter) || normalized.jitter < 0 || normalized.jitter > 1) {
    throw invalidManagerOption("retry.jitter must be between 0 and 1");
  }
  if (
    normalized.maxAttempts !== Number.POSITIVE_INFINITY &&
    (!Number.isSafeInteger(normalized.maxAttempts) || normalized.maxAttempts < 1)
  ) {
    throw invalidManagerOption("retry.maxAttempts must be a positive safe integer or Infinity");
  }

  return normalized;
}

function invalidManagerOption(message: string): ZaptunnelError {
  return new ZaptunnelError(message, { code: "invalid_option" });
}

function browserIsOnline(): boolean {
  return typeof navigator === "undefined" || navigator.onLine !== false;
}

function managerStoppedError(): ZaptunnelError {
  return new ZaptunnelError("the Zaptunnel connection manager is stopped", {
    code: "manager_stopped"
  });
}

function safeMessage(error: unknown): string {
  return error instanceof Error ? error.message : "unknown error";
}

function linkAbortSignals(
  ...signals: Array<AbortSignal | undefined>
): { signal: AbortSignal; cleanup: () => void } {
  const controller = new AbortController();
  const active = signals.filter((signal): signal is AbortSignal => signal !== undefined);
  const abort = () => controller.abort();

  for (const signal of active) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener("abort", abort, { once: true });
  }

  return {
    signal: controller.signal,
    cleanup: () => {
      for (const signal of active) signal.removeEventListener("abort", abort);
    }
  };
}

function parseRelay(relay: string, allowInsecure: boolean): URL {
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

  const loopback = parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]";
  if (parsed.protocol !== "https:" && !loopback && !allowInsecure) {
    throw new ZaptunnelError("relay must use HTTPS outside a loopback development environment", {
      code: "insecure_relay"
    });
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

function validateChainHash(chainHash: string): void {
  if (!/^[0-9a-f]{64}$/i.test(chainHash)) {
    throw new ZaptunnelError("chainHash must be a 32-byte hexadecimal BOLT chain hash", {
      code: "invalid_chain_hash"
    });
  }
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);

  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }

  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function readUint16(bytes: Uint8Array, offset: number): number | null {
  if (offset < 0 || offset + 2 > bytes.length) return null;
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint16(offset);
}

function readBigSize(
  bytes: Uint8Array,
  offset: number
): { value: bigint; nextOffset: number } | null {
  if (offset < 0 || offset >= bytes.length) return null;

  const prefix = bytes[offset];
  if (prefix < 0xfd) return { value: BigInt(prefix), nextOffset: offset + 1 };

  const width = prefix === 0xfd ? 2 : prefix === 0xfe ? 4 : 8;
  if (offset + 1 + width > bytes.length) return null;

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let value = 0n;
  for (let index = 0; index < width; index += 1) {
    value = (value << 8n) | BigInt(view.getUint8(offset + 1 + index));
  }

  const minimum = width === 2 ? 0xfdn : width === 4 ? 0x1_0000n : 0x1_0000_0000n;
  if (value < minimum) return null;

  return { value, nextOffset: offset + 1 + width };
}

export function parseClnVersion(raw: string): ClnVersion | null {
  const match = raw.trim().match(/^v?(\d+)\.(\d+)(?:\.(\d+))?(.*)$/);
  if (!match) return null;

  return {
    raw,
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3] ?? 0),
    suffix: match[4] ?? ""
  };
}

export function compareClnVersions(
  actual: string | ClnVersion,
  required: string | ClnVersion
): number {
  const left = typeof actual === "string" ? parseClnVersion(actual) : actual;
  const right = typeof required === "string" ? parseClnVersion(required) : required;

  if (!left || !right) {
    throw new ZaptunnelError("CLN version must look like v24.02 or v24.02.1", {
      code: "invalid_cln_version"
    });
  }

  for (const key of ["major", "minor", "patch"] as const) {
    if (left[key] !== right[key]) return left[key] < right[key] ? -1 : 1;
  }

  return 0;
}

function validateCallControls(options: RpcCallOptions): void {
  validateNonNegativeInteger(options.timeoutMs, "timeoutMs");
}

function validateNonNegativeInteger(value: number | undefined, name: string): void {
  if (value !== undefined && (!Number.isSafeInteger(value) || value < 0)) {
    throw new ZaptunnelError(`${name} must be a non-negative safe integer`, {
      code: "invalid_option"
    });
  }
}

async function controlConnectionOperation(
  operation: Promise<boolean>,
  signal: AbortSignal | undefined,
  timeoutMs: number,
  disconnect: () => void,
  requestId?: string
): Promise<boolean> {
  return await new Promise<boolean>((resolve, reject) => {
    let settled = false;
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      callback();
    };
    const abort = () => {
      disconnect();
      finish(() =>
        reject(
          new ZaptunnelError("the Lightning connection attempt was aborted", {
            code: "request_aborted",
            requestId
          })
        )
      );
    };
    const timer = setTimeout(() => {
      disconnect();
      finish(() =>
        reject(
          new ZaptunnelError(`the Lightning connection exceeded its ${timeoutMs}ms timeout`, {
            code: "connection_timeout",
            requestId
          })
        )
      );
    }, timeoutMs);

    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) {
      abort();
      return;
    }

    operation.then(
      (connected) => finish(() => resolve(connected)),
      (error) => finish(() => reject(error))
    );
  });
}

async function controlRpcOperation<T>(
  operation: Promise<T>,
  method: string,
  options: Pick<RpcCallOptions, "signal" | "timeoutMs">,
  transportSignal?: AbortSignal,
  transportError?: () => ZaptunnelError | undefined
): Promise<T> {
  return await new Promise<T>((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      options.signal?.removeEventListener("abort", abort);
      transportSignal?.removeEventListener("abort", transportClosed);
      callback();
    };

    const abort = () =>
      finish(() => reject(requestControlError(method, "request_aborted", "the CLN RPC request was aborted")));

    const transportClosed = () =>
      finish(() =>
        reject(
          transportError?.() ??
            new ZaptunnelRpcError("the Lightning transport closed during the RPC request", {
              code: "connection_closed",
              method
            })
        )
      );

    options.signal?.addEventListener("abort", abort, { once: true });
    transportSignal?.addEventListener("abort", transportClosed, { once: true });
    if (transportSignal?.aborted) {
      transportClosed();
      return;
    }

    const timeoutMs = options.timeoutMs ?? DEFAULT_RPC_TIMEOUT_MS;
    if (timeoutMs !== undefined) {
      timer = setTimeout(
        () =>
          finish(() =>
            reject(
              requestControlError(
                method,
                "request_timeout",
                `the CLN RPC request exceeded its ${timeoutMs}ms timeout`
              )
            )
          ),
        timeoutMs
      );
    }

    operation.then(
      (result) => finish(() => resolve(result)),
      (error) => finish(() => reject(normalizeRpcError(method, error)))
    );
  });
}

function requestControlError(method: string, code: string, message: string): ZaptunnelRpcError {
  return new ZaptunnelRpcError(message, { code, method });
}

function normalizeTransportError(
  error: { code?: string; message?: string } | unknown,
  requestId?: string
): ZaptunnelError {
  const transportCode = typeof error === "object" && error !== null && "code" in error ? error.code : undefined;
  const message =
    transportCode === "decrypt_failure"
      ? "received Lightning ciphertext failed authenticated decryption"
      : "the Lightning transport reported a fatal protocol error";

  return new ZaptunnelError(message, {
    code: transportCode === "decrypt_failure" ? "transport_integrity_failure" : "connection_failed",
    requestId,
    cause: error
  });
}

function normalizeConnectionAttemptError(error: unknown): ZaptunnelError {
  if (error instanceof ZaptunnelError) return error;

  return new ZaptunnelError("failed to establish the Lightning connection", {
    code: "connection_failed",
    cause: error
  });
}

function normalizeRpcError(method: string, error: unknown): ZaptunnelError {
  if (error instanceof ZaptunnelError) return error;

  const rpcError = asRpcError(error);

  if (!rpcError) {
    return new ZaptunnelRpcError(`CLN RPC ${method} failed`, {
      code: "rpc_failed",
      method,
      cause: error
    });
  }

  const code =
    rpcError.code === -32601
      ? "method_not_found"
      : rpcError.code === -32602
        ? "invalid_params"
        : rpcError.code === 19537
          ? "rune_not_authorized"
          : rpcError.code === 904 || rpcError.code === 2000
            ? "rpc_timeout"
            : rpcError.code === 2
              ? "connection_failed"
              : "rpc_failed";

  return new ZaptunnelRpcError(rpcError.message, {
    code,
    method,
    rpcCode: rpcError.code,
    data: rpcError.data,
    cause: error
  });
}

function asRpcError(error: unknown): { code: number; message: string; data?: unknown } | null {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "number" &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return {
      code: error.code,
      message: error.message,
      data: "data" in error ? error.data : undefined
    };
  }

  return null;
}

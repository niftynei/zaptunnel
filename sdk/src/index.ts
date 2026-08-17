import Lnmessage from "lnmessage";

export type RpcParams = unknown[] | Record<string, unknown>;

export type RpcCallOptions = {
  /** Override the client's default rune for this call. */
  rune?: string;
  /** Reject locally if the request has not completed within this many milliseconds. */
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
  /** Ask CLN to end the long poll after this many seconds. Omit to wait indefinitely. */
  waitTimeoutSeconds?: number;
};

export type PaidInvoiceStreamOptions = Omit<WaitAnyInvoiceOptions, "timeoutMs" | "waitTimeoutSeconds"> & {
  /** Finite CLN long-poll duration. Defaults to 30 seconds so cancellation is bounded. */
  waitTimeoutSeconds?: number;
  /** Local grace period after CLN's long-poll timeout. Defaults to 5 seconds. */
  timeoutGraceMs?: number;
};

export const DEFAULT_RELAY = "https://relay.zapptunnel.com";
export const BITCOIN_MAINNET_CHAIN_HASH =
  "6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000";

const INIT_MESSAGE_TYPE = 16;
const GOSSIP_TIMESTAMP_FILTER_MESSAGE_TYPE = 265;
const NO_GOSSIP_FIRST_TIMESTAMP = 0xffff_ffff;
const NO_GOSSIP_TIMESTAMP_RANGE = 0;

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
  /**
   * BOLT wire-order chain hash used by the restrictive gossip filter. The SDK
   * normally learns this from the node's init message and otherwise defaults
   * to Bitcoin mainnet. Set this for non-mainnet nodes that omit init networks.
   */
  chainHash?: string;
  /** @deprecated Relay tickets are single-use; use createConnectionManager() instead. */
  reconnect?: boolean;
  logger?: ZaptunnelLogger;
  signal?: AbortSignal;
};

export type ConnectionManagerOptions = Omit<ConnectOptions, "reconnect" | "signal"> & {
  retry?: ReconnectPolicy;
  identityStore?: ZaptunnelIdentityStore;
};

type AdmissionResponse = {
  websocket_path: string;
  request_id?: string;
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
  readonly privateKey: string;
  readonly requestId?: string;

  #rune?: string;
  #transport: Lnmessage;
  #disconnectCleanup?: () => void;

  constructor(
    transport: Lnmessage,
    options: Pick<ConnectOptions, "nodeId" | "address" | "rune">,
    disconnectCleanup?: () => void,
    requestId?: string
  ) {
    this.#transport = transport;
    this.#rune = options.rune;
    this.#disconnectCleanup = disconnectCleanup;
    this.nodeId = options.nodeId;
    this.address = options.address;
    this.publicKey = transport.publicKey;
    this.privateKey = transport.privateKey;
    this.requestId = requestId;
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

    const operation = this.#transport.commando({ method, params, rune }) as Promise<T>;
    return await controlRpcOperation(operation, method, options);
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

    const params: Record<string, number> = {};
    if (options.lastPayIndex !== undefined) params.lastpay_index = options.lastPayIndex;
    if (options.waitTimeoutSeconds !== undefined) params.timeout = options.waitTimeoutSeconds;

    const timeoutMs =
      options.timeoutMs ??
      (options.waitTimeoutSeconds === undefined ? undefined : options.waitTimeoutSeconds * 1_000 + 5_000);

    return await this.call<PaidInvoice>("waitanyinvoice", params, {...options, timeoutMs});
  }

  async *paidInvoices(options: PaidInvoiceStreamOptions = {}): AsyncGenerator<PaidInvoice, void, void> {
    const waitTimeoutSeconds = options.waitTimeoutSeconds ?? 30;
    const timeoutGraceMs = options.timeoutGraceMs ?? 5_000;
    let lastPayIndex = options.lastPayIndex ?? 0;

    validateNonNegativeInteger(lastPayIndex, "lastPayIndex");
    validateNonNegativeInteger(waitTimeoutSeconds, "waitTimeoutSeconds");
    validateNonNegativeInteger(timeoutGraceMs, "timeoutGraceMs");

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
          continue;
        }

        throw error;
      }
    }
  }

  disconnect(): void {
    this.#disconnectCleanup?.();
    this.#disconnectCleanup = undefined;
    this.#transport.disconnect();
  }

  /** Observe the stable, high-level state of the underlying Lightning connection. */
  onConnectionStatus(listener: (status: ZaptunnelConnectionStatus) => void): () => void {
    const subscription = this.#transport.connectionStatus$.subscribe(listener);
    return () => subscription.unsubscribe();
  }
}

/** Request admission and establish an end-to-end BOLT-8 session with CLN. */
export async function connect(options: ConnectOptions): Promise<ZaptunnelClient> {
  validateNodeId(options.nodeId);
  if (options.chainHash !== undefined) validateChainHash(options.chainHash);
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
  const abortConnection = () => transport.disconnect();
  options.signal?.addEventListener("abort", abortConnection, { once: true });

  let gossipFilterError: unknown;
  const gossipSubscription = transport.decryptedMsgs$.subscribe((message) => {
    if (readUint16(message, 0) !== INIT_MESSAGE_TYPE) return;

    const chainHash =
      options.chainHash?.toLowerCase() ?? extractInitChainHash(message) ?? BITCOIN_MAINNET_CHAIN_HASH;

    try {
      const BufferConstructor = message.constructor as unknown as {
        from(bytes: Uint8Array): typeof message;
      };
      const plaintext = BufferConstructor.from(encodeRestrictiveGossipTimestampFilter(chainHash));
      const encrypted = transport.noise.encryptMessage(plaintext);

      if (!transport.socket) throw new Error("the Lightning socket is not available");
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
    const connected = await transport.connect(false);

    if (!connected) {
      throw new ZaptunnelError("the Lightning connection closed during its BOLT-8 handshake", {
        code: "connection_closed",
        requestId: admission.request_id
      });
    }

    if (gossipFilterError) {
      throw new ZaptunnelError("failed to configure the Lightning gossip filter", {
        code: "gossip_filter_failed",
        requestId: admission.request_id,
        cause: gossipFilterError
      });
    }

    return new ZaptunnelClient(
      transport,
      options,
      () => gossipSubscription.unsubscribe(),
      admission.request_id
    );
  } catch (error) {
    gossipSubscription.unsubscribe();
    transport.disconnect();

    if (error instanceof ZaptunnelError) throw error;
    throw new ZaptunnelError("failed to establish the Lightning connection", {
      code: "connection_failed",
      requestId: admission.request_id,
      cause: error
    });
  } finally {
    options.signal?.removeEventListener("abort", abortConnection);
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
  #started = false;
  #stopped = false;
  #status: ZaptunnelManagerStatus = "idle";
  #lastError?: unknown;
  #terminalError?: ZaptunnelError;
  #listeners = new Set<(status: ZaptunnelManagerStatus) => void>();
  #waiters = new Set<ConnectionWaiter>();
  #onlineListener = () => this.retryNow();
  #visibilityListener = () => {
    if (typeof document === "undefined" || document.visibilityState === "visible") this.retryNow();
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
      this.#privateKey = client.privateKey;

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

      this.#lastError = error;
      if (this.#attempts >= this.#retry.maxAttempts) {
        this.#terminalError = new ZaptunnelError("connection retry attempts were exhausted", {
          code: "reconnect_exhausted",
          requestId: error instanceof ZaptunnelError ? error.requestId : undefined,
          cause: error
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
    this.#dropClient();
    this.#attempts = 0;
    this.#setStatus("waiting_reconnect");
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

    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = undefined;
      void this.#attemptConnection();
    }, delayMs);
  }

  #clearRetryTimer(): void {
    if (this.#retryTimer !== undefined) clearTimeout(this.#retryTimer);
    this.#retryTimer = undefined;
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
    } catch (error) {
      this.#options.logger?.warn(`Could not load the persisted Zaptunnel browser identity: ${safeMessage(error)}`);
    }
  }

  async #saveIdentity(privateKey: string): Promise<void> {
    if (!this.#identityStore || this.#savedPrivateKey === privateKey) return;

    try {
      await this.#identityStore.savePrivateKey(this.nodeId, privateKey);
      this.#savedPrivateKey = privateKey;
    } catch (error) {
      this.#options.logger?.warn(`Could not save the Zaptunnel browser identity: ${safeMessage(error)}`);
    }
  }

  #setStatus(status: ZaptunnelManagerStatus): void {
    if (status === this.#status) return;
    this.#status = status;
    for (const listener of this.#listeners) this.#notifyListener(listener, status);
  }

  #notifyListener(
    listener: (status: ZaptunnelManagerStatus) => void,
    status: ZaptunnelManagerStatus
  ): void {
    try {
      listener(status);
    } catch (error) {
      this.#options.logger?.error(`Zaptunnel connection-status listener failed: ${safeMessage(error)}`);
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

  const body = (await response.json().catch(() => ({}))) as Partial<AdmissionResponse> & {
    error?: string;
  };
  const requestId = body.request_id ?? response.headers.get("x-request-id") ?? undefined;

  if (!response.ok) {
    const code = body.error ?? "admission_failed";
    throw new ZaptunnelError(`Zaptunnel admission failed: ${code}`, {
      code,
      status: response.status,
      requestId
    });
  }

  if (typeof body.websocket_path !== "string" || !body.websocket_path.startsWith("/")) {
    throw new ZaptunnelError("the relay returned an invalid admission response", {
      code: "invalid_relay_response",
      status: response.status,
      requestId
    });
  }

  return { websocket_path: body.websocket_path, request_id: requestId };
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

async function controlRpcOperation<T>(
  operation: Promise<T>,
  method: string,
  options: Pick<RpcCallOptions, "signal" | "timeoutMs">
): Promise<T> {
  return await new Promise<T>((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      options.signal?.removeEventListener("abort", abort);
      callback();
    };

    const abort = () =>
      finish(() => reject(requestControlError(method, "request_aborted", "the CLN RPC request was aborted")));

    options.signal?.addEventListener("abort", abort, { once: true });

    if (options.timeoutMs !== undefined) {
      timer = setTimeout(
        () =>
          finish(() =>
            reject(
              requestControlError(
                method,
                "request_timeout",
                `the CLN RPC request exceeded its ${options.timeoutMs}ms timeout`
              )
            )
          ),
        options.timeoutMs
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

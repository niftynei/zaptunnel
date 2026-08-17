import assert from "node:assert/strict";
import test from "node:test";

import {
  BITCOIN_MAINNET_CHAIN_HASH,
  ClnCapabilities,
  calculateReconnectDelay,
  compareClnVersions,
  connect,
  diagnoseZaptunnelError,
  encodeRestrictiveGossipTimestampFilter,
  extractInitChainHash,
  parseAddress,
  parseClnVersion,
  ZaptunnelClient,
  ZaptunnelConnectionManager,
  ZaptunnelError,
  ZaptunnelRpcError
} from "../dist/lib/index.js";

const nodeId = "03" + "33".repeat(32);

function clientWith(commando, rune = "default-rune") {
  const listeners = new Set();
  return new ZaptunnelClient(
    {
      publicKey: "02" + "11".repeat(32),
      privateKey: "22".repeat(32),
      connectionStatus$: {
        subscribe(listener) {
          listeners.add(listener);
          listener("connected");
          return { unsubscribe: () => listeners.delete(listener) };
        }
      },
      commando,
      disconnect() {}
    },
    { nodeId, address: "node.example.com:9735", rune: rune ?? undefined }
  );
}

class FakeManagedClient {
  constructor({ privateKey = "44".repeat(32), call, invoices = [] } = {}) {
    this.publicKey = "02" + "55".repeat(32);
    this.privateKey = privateKey;
    this.callImpl = call ?? (async () => ({}));
    this.invoices = invoices;
    this.listeners = new Set();
    this.invoiceOptions = [];
    this.disconnected = false;
  }

  onConnectionStatus(listener) {
    this.listeners.add(listener);
    listener("connected");
    return () => this.listeners.delete(listener);
  }

  emit(status) {
    for (const listener of this.listeners) listener(status);
  }

  disconnect() {
    this.disconnected = true;
  }

  call(method, params, options) {
    return this.callImpl(method, params, options);
  }

  getCapabilities() {
    return Promise.resolve(new ClnCapabilities("v24.02", ["getinfo"]));
  }

  async *paidInvoices(options) {
    this.invoiceOptions.push(options);
    for (const invoice of this.invoices) yield invoice;

    if (options.signal?.aborted) return;
    await new Promise((resolve) => options.signal?.addEventListener("abort", resolve, { once: true }));
  }
}

class FakeConnectionManager extends ZaptunnelConnectionManager {
  constructor(options, connectionAttempts) {
    super(options);
    this.connectionAttempts = connectionAttempts;
    this.receivedOptions = [];
  }

  async establishConnection(options) {
    this.receivedOptions.push(options);
    const attempt = this.connectionAttempts.shift();
    if (attempt instanceof Error) throw attempt;
    if (!attempt) throw new Error("unexpected connection attempt");
    return attempt;
  }
}

function paidInvoice(payIndex, label = `paid-${payIndex}`) {
  return {
    label,
    payment_hash: "aa".repeat(32),
    status: "paid",
    pay_index: payIndex,
    amount_received_msat: 1000,
    paid_at: 1,
    payment_preimage: "bb".repeat(32),
    expires_at: 2
  };
}

function managedOptions(overrides = {}) {
  return {
    nodeId,
    address: "node.example.com:9735",
    rune: "readonly",
    retry: { minDelayMs: 0, maxDelayMs: 1, jitter: 0 },
    ...overrides
  };
}

test("reconnect delay is bounded exponential backoff with deterministic jitter", () => {
  const policy = { minDelayMs: 100, maxDelayMs: 1_000, multiplier: 2, jitter: 0.25 };

  assert.equal(calculateReconnectDelay(1, policy, () => 0.5), 100);
  assert.equal(calculateReconnectDelay(3, policy, () => 0.5), 400);
  assert.equal(calculateReconnectDelay(9, policy, () => 0.5), 1_000);
  assert.equal(calculateReconnectDelay(9, policy, () => 1), 1_000);
  assert.equal(calculateReconnectDelay(1, policy, () => 0), 75);
  assert.equal(calculateReconnectDelay(1, policy, () => 1), 125);
});

test("troubleshooting diagnostics map stable errors to actionable stages", () => {
  const diagnostic = diagnoseZaptunnelError(
    new ZaptunnelError("relay rejected the endpoint", {
      code: "endpoint_unverified",
      requestId: "zt_request_123"
    })
  );

  assert.equal(diagnostic.code, "endpoint_unverified");
  assert.equal(diagnostic.stage, "endpoint_verification");
  assert.equal(diagnostic.title, "Lightning endpoint could not be verified");
  assert.equal(diagnostic.retryable, true);
  assert.equal(diagnostic.requestId, "zt_request_123");
  assert.ok(diagnostic.suggestions.some((item) => item.includes("node ID")));
});

test("troubleshooting diagnostics preserve the underlying error after retries exhaust", () => {
  const underlying = new ZaptunnelError("relay could not reach the node", {
    code: "endpoint_unverified",
    requestId: "zt_request_nested"
  });
  const diagnostic = diagnoseZaptunnelError(
    new ZaptunnelError("connection retries exhausted", {
      code: "reconnect_exhausted",
      cause: underlying
    })
  );

  assert.equal(diagnostic.code, "reconnect_exhausted");
  assert.equal(diagnostic.causeCode, "endpoint_unverified");
  assert.equal(diagnostic.stage, "endpoint_verification");
  assert.equal(diagnostic.title, "Connection retries exhausted");
  assert.equal(diagnostic.requestId, "zt_request_nested");
  assert.ok(diagnostic.suggestions.some((item) => item.includes("retryNow")));
  assert.ok(diagnostic.suggestions.some((item) => item.includes("node ID")));
});

test("troubleshooting diagnostics safely handle unknown errors", () => {
  const diagnostic = diagnoseZaptunnelError(new Error("internal detail that should not be exposed"));

  assert.equal(diagnostic.code, "unknown_error");
  assert.equal(diagnostic.stage, "unknown");
  assert.equal(diagnostic.retryable, false);
  assert.equal(diagnostic.summary.includes("internal detail"), false);
});

test("manager exposes retry timing and diagnostic state", async () => {
  const manager = new FakeConnectionManager(
    managedOptions({ retry: { minDelayMs: 1_000, maxDelayMs: 1_000, jitter: 0 } }),
    [
      new ZaptunnelError("relay rejected the endpoint", {
        code: "endpoint_unverified",
        requestId: "zt_manager_request"
      })
    ]
  );
  const states = [];
  const unsubscribe = manager.onConnectionState((state) => states.push(state));
  const pending = manager.start();
  pending.catch(() => {});

  await new Promise((resolve) => setTimeout(resolve, 10));
  const state = manager.connectionState;
  assert.equal(state.status, "waiting_reconnect");
  assert.equal(state.attempt, 1);
  assert.equal(state.diagnostic?.stage, "endpoint_verification");
  assert.equal(state.requestId, "zt_manager_request");
  assert.equal(typeof state.nextRetryAt, "number");
  assert.ok(state.retryInMs >= 0 && state.retryInMs <= 1_000);
  assert.ok(states.some((item) => item.status === "connecting"));
  assert.ok(states.some((item) => item.nextRetryAt !== null));

  unsubscribe();
  manager.stop();
  await assert.rejects(pending, (error) => error.code === "manager_stopped");
});

test("manager retries with fresh sessions and preserves the generated browser identity", async () => {
  const first = new FakeManagedClient({ privateKey: "66".repeat(32) });
  const second = new FakeManagedClient({ privateKey: "66".repeat(32) });
  const saves = [];
  const manager = new FakeConnectionManager(
    managedOptions({
      identityStore: {
        loadPrivateKey: async () => undefined,
        savePrivateKey: async (savedNodeId, privateKey) => saves.push([savedNodeId, privateKey])
      }
    }),
    [new Error("relay temporarily unavailable"), first, second]
  );
  const statuses = [];
  manager.onConnectionStatus((status) => statuses.push(status));

  assert.equal(await manager.start(), first);
  assert.equal(manager.receivedOptions.length, 2);
  assert.equal(manager.receivedOptions[0].reconnect, false);
  assert.equal(manager.receivedOptions[0].privateKey, undefined);
  assert.deepEqual(saves, [[nodeId, "66".repeat(32)]]);

  first.emit("disconnected");
  assert.equal(await manager.start(), second);
  assert.equal(manager.receivedOptions.length, 3);
  assert.equal(manager.receivedOptions[2].privateKey, "66".repeat(32));
  assert.ok(statuses.includes("waiting_reconnect"));
  assert.equal(statuses.at(-1), "connected");
  manager.stop();
});

test("manager loads a persisted browser identity before first admission", async () => {
  const storedKey = "77".repeat(32);
  const client = new FakeManagedClient({ privateKey: storedKey });
  let saves = 0;
  const manager = new FakeConnectionManager(
    managedOptions({
      identityStore: {
        loadPrivateKey: async (loadedNodeId) => {
          assert.equal(loadedNodeId, nodeId);
          return storedKey;
        },
        savePrivateKey: async () => {
          saves += 1;
        }
      }
    }),
    [client]
  );

  await manager.start();
  assert.equal(manager.receivedOptions[0].privateKey, storedKey);
  assert.equal(manager.privateKey, storedKey);
  assert.equal(manager.publicKey, client.publicKey);
  assert.equal(saves, 0);
  manager.stop();
});

test("manager never replays an ordinary RPC after it fails", async () => {
  let calls = 0;
  const client = new FakeManagedClient({
    call: async () => {
      calls += 1;
      throw new Error("connection disappeared during invoice");
    }
  });
  const manager = new FakeConnectionManager(managedOptions(), [client]);

  await assert.rejects(manager.invoice({ amount_msat: 1000 }), /connection disappeared/);
  assert.equal(calls, 1);
  assert.equal(manager.receivedOptions.length, 1);
  manager.stop();
});

test("paid invoice stream resumes from its cursor on a fresh session", async () => {
  const first = new FakeManagedClient({ invoices: [paidInvoice(8)] });
  const second = new FakeManagedClient({ invoices: [paidInvoice(9)] });
  const manager = new FakeConnectionManager(managedOptions(), [first, second]);
  const invoices = manager.paidInvoices({ lastPayIndex: 7, waitTimeoutSeconds: 1 });

  assert.equal((await invoices.next()).value.pay_index, 8);
  first.emit("failed");
  assert.equal((await invoices.next()).value.pay_index, 9);
  assert.equal(first.invoiceOptions[0].lastPayIndex, 7);
  assert.equal(second.invoiceOptions[0].lastPayIndex, 8);

  await invoices.return();
  manager.stop();
});

test("finite retry exhaustion is stable and can be retried explicitly", async () => {
  const recovered = new FakeManagedClient();
  const manager = new FakeConnectionManager(
    managedOptions({ retry: { minDelayMs: 0, maxDelayMs: 0, jitter: 0, maxAttempts: 1 } }),
    [new Error("offline"), recovered]
  );

  await assert.rejects(
    manager.start(),
    (error) => error instanceof ZaptunnelError && error.code === "reconnect_exhausted"
  );
  assert.equal(manager.status, "failed");

  manager.retryNow();
  assert.equal(await manager.start(), recovered);
  manager.stop();
});

test("manager validates retry policy before starting network work", () => {
  assert.throws(
    () => new FakeConnectionManager(managedOptions({ retry: { maxAttempts: 0 } }), []),
    (error) => error instanceof ZaptunnelError && error.code === "invalid_option"
  );
  assert.throws(
    () =>
      new FakeConnectionManager(
        managedOptions({ retry: { minDelayMs: 10, maxDelayMs: 5 } }),
        []
      ),
    (error) => error instanceof ZaptunnelError && error.code === "invalid_option"
  );
});

test("stopping a manager aborts connection waiters and is terminal", async () => {
  let finishAttempt;
  class PendingManager extends ZaptunnelConnectionManager {
    establishConnection() {
      return new Promise((resolve) => {
        finishAttempt = resolve;
      });
    }
  }

  const manager = new PendingManager(managedOptions());
  const pending = manager.start();
  await new Promise((resolve) => setTimeout(resolve, 0));
  manager.stop();

  await assert.rejects(
    pending,
    (error) => error instanceof ZaptunnelError && error.code === "manager_stopped"
  );
  await assert.rejects(
    manager.start(),
    (error) => error instanceof ZaptunnelError && error.code === "manager_stopped"
  );

  const lateClient = new FakeManagedClient();
  finishAttempt(lateClient);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(lateClient.disconnected, true);
});

test("connection status is exposed without leaking lnmessage internals", () => {
  const client = clientWith(async () => ({}));
  const statuses = [];
  const unsubscribe = client.onConnectionStatus((status) => statuses.push(status));

  assert.deepEqual(statuses, ["connected"]);
  assert.equal(typeof unsubscribe, "function");
  unsubscribe();
});

test("relay admission failures carry their correlation request id", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(JSON.stringify({ error: "endpoint_unverified", request_id: "zt_1234567890abcdef" }), {
      status: 422,
      headers: { "content-type": "application/json", "x-request-id": "zt_header_should_not_win" }
    });

  try {
    await assert.rejects(
      connect({ nodeId, address: "node.example.com:9735", rune: "readonly" }),
      (error) =>
        error instanceof ZaptunnelError &&
        error.code === "endpoint_unverified" &&
        error.status === 422 &&
        error.requestId === "zt_1234567890abcdef"
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("restrictive gossip filter uses the BOLT 7 no-gossip timestamp range", () => {
  const message = encodeRestrictiveGossipTimestampFilter(BITCOIN_MAINNET_CHAIN_HASH);
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);

  assert.equal(message.length, 42);
  assert.equal(view.getUint16(0), 265);
  assert.equal(Buffer.from(message.subarray(2, 34)).toString("hex"), BITCOIN_MAINNET_CHAIN_HASH);
  assert.equal(view.getUint32(34), 0xffff_ffff);
  assert.equal(view.getUint32(38), 0);
  assert.throws(
    () => encodeRestrictiveGossipTimestampFilter("not-a-chain-hash"),
    (error) => error instanceof ZaptunnelError && error.code === "invalid_chain_hash"
  );
});

test("chain hash is learned from the BOLT init networks TLV", () => {
  const regtestChainHash = "0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206";
  const init = Buffer.concat([
    Buffer.from([0, 16]),
    Buffer.from([0, 0]),
    Buffer.from([0, 0]),
    Buffer.from([1, 32]),
    Buffer.from(regtestChainHash, "hex")
  ]);

  assert.equal(extractInitChainHash(init), regtestChainHash);
  assert.equal(extractInitChainHash(Buffer.from([0, 18, 0, 0, 0, 0])), null);
  assert.equal(extractInitChainHash(Buffer.from([0, 16, 0, 0, 0, 0, 1, 31])), null);
});

test("parseAddress accepts DNS, IPv4, and bracketed IPv6 endpoints", () => {
  assert.deepEqual(parseAddress("node.example.com:9735"), { host: "node.example.com", port: 9735 });
  assert.deepEqual(parseAddress("127.0.0.1:19735"), { host: "127.0.0.1", port: 19735 });
  assert.deepEqual(parseAddress("[2001:db8::1]:9735"), { host: "[2001:db8::1]", port: 9735 });
});

test("parseAddress returns stable errors for invalid addresses", () => {
  for (const address of ["node.example.com", "node.example.com:0", "https://node.example.com:9735"]) {
    assert.throws(
      () => parseAddress(address),
      (error) => error instanceof ZaptunnelError && error.code === "invalid_address"
    );
  }
});

test("client calls Commando with its default rune and supports an override", async () => {
  const calls = [];
  const client = clientWith(async (request) => {
    calls.push(request);
    return { id: "node" };
  });

  assert.deepEqual(await client.getInfo(), { id: "node" });
  await client.call("invoice", { amount_msat: 1000 }, { rune: "invoice-rune" });
  assert.deepEqual(calls, [
    { method: "getinfo", params: [], rune: "default-rune" },
    { method: "invoice", params: { amount_msat: 1000 }, rune: "invoice-rune" }
  ]);
});

test("client refuses RPC calls without a rune", async () => {
  const client = clientWith(
    async () => {
      assert.fail("commando should not be called");
    },
    null
  );

  await assert.rejects(
    client.getInfo(),
    (error) => error instanceof ZaptunnelError && error.code === "rune_required"
  );
});

test("RPC errors expose stable SDK codes and preserve CLN details", async () => {
  const client = clientWith(async () => {
    throw { code: 19537, message: "Not permitted: method is not allowed", data: { reason: "rune" } };
  });

  await assert.rejects(
    client.getinfo(),
    (error) =>
      error instanceof ZaptunnelRpcError &&
      error.code === "rune_not_authorized" &&
      error.method === "getinfo" &&
      error.rpcCode === 19537 &&
      error.data.reason === "rune"
  );
});

test("calls support stable local timeout and abort errors", async () => {
  const never = () => new Promise(() => {});
  const client = clientWith(never);

  await assert.rejects(
    client.call("waitanyinvoice", {}, { timeoutMs: 1 }),
    (error) => error instanceof ZaptunnelRpcError && error.code === "request_timeout"
  );

  const controller = new AbortController();
  const pending = client.call("waitanyinvoice", {}, { signal: controller.signal });
  controller.abort();
  await assert.rejects(
    pending,
    (error) => error instanceof ZaptunnelRpcError && error.code === "request_aborted"
  );
});

test("CLN versions and runtime capabilities can be inspected", async () => {
  assert.deepEqual(parseClnVersion("v24.02.1-modded"), {
    raw: "v24.02.1-modded",
    major: 24,
    minor: 2,
    patch: 1,
    suffix: "-modded"
  });
  assert.equal(compareClnVersions("v24.02", "23.11.2"), 1);
  assert.equal(compareClnVersions("v24.02", "24.02.0"), 0);

  const client = clientWith(async ({ method }) => {
    if (method === "getinfo") return { version: "v24.02.1" };
    if (method === "help") {
      return { help: [{ command: "getinfo" }, { command: "waitanyinvoice [lastpay_index] [timeout]" }] };
    }
    assert.fail(`unexpected method ${method}`);
  });
  const capabilities = await client.getCapabilities();

  assert.ok(capabilities instanceof ClnCapabilities);
  assert.equal(capabilities.supports("waitanyinvoice"), true);
  assert.equal(capabilities.supports("wait"), false);
  assert.equal(capabilities.isVersionAtLeast("v23.11"), true);
  assert.throws(() => capabilities.require("wait"), (error) => error.code === "unsupported_method");
});

test("paidInvoices resumes after CLN long-poll timeouts and advances its cursor", async () => {
  const calls = [];
  const responses = [
    Promise.reject({ code: 904, message: "Invoice wait timed out" }),
    Promise.resolve({
      label: "paid-1",
      payment_hash: "aa".repeat(32),
      status: "paid",
      pay_index: 8,
      amount_received_msat: 1000,
      paid_at: 1,
      payment_preimage: "bb".repeat(32),
      expires_at: 2
    }),
    Promise.resolve({
      label: "paid-2",
      payment_hash: "cc".repeat(32),
      status: "paid",
      pay_index: 9,
      amount_received_msat: 2000,
      paid_at: 3,
      payment_preimage: "dd".repeat(32),
      expires_at: 4
    })
  ];
  const client = clientWith(async (request) => {
    calls.push(request);
    return await responses.shift();
  });
  const invoices = client.paidInvoices({ lastPayIndex: 7, waitTimeoutSeconds: 0 });

  assert.equal((await invoices.next()).value.label, "paid-1");
  assert.equal((await invoices.next()).value.label, "paid-2");
  await invoices.return();
  assert.deepEqual(
    calls.map(({ params }) => params.lastpay_index),
    [7, 7, 8]
  );
});

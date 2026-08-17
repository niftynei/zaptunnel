import assert from "node:assert/strict";
import test from "node:test";

import {
  ClnCapabilities,
  compareClnVersions,
  parseAddress,
  parseClnVersion,
  ZaptunnelClient,
  ZaptunnelError,
  ZaptunnelRpcError
} from "../dist/lib/index.js";

const nodeId = "03" + "33".repeat(32);

function clientWith(commando, rune = "default-rune") {
  return new ZaptunnelClient(
    {
      publicKey: "02" + "11".repeat(32),
      privateKey: "22".repeat(32),
      commando,
      disconnect() {}
    },
    { nodeId, address: "node.example.com:9735", rune: rune ?? undefined }
  );
}

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

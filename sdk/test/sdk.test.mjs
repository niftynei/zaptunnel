import assert from "node:assert/strict";
import test from "node:test";

import { parseAddress, ZaptunnelClient, ZaptunnelError } from "../dist/lib/index.js";

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
  const transport = {
    publicKey: "02" + "11".repeat(32),
    privateKey: "22".repeat(32),
    commando: async (request) => {
      calls.push(request);
      return { id: "node" };
    },
    disconnect() {}
  };
  const client = new ZaptunnelClient(transport, {
    nodeId: "03" + "33".repeat(32),
    address: "node.example.com:9735",
    rune: "default-rune"
  });

  assert.deepEqual(await client.getInfo(), { id: "node" });
  await client.call("invoice", { amount_msat: 1000 }, { rune: "invoice-rune" });
  assert.deepEqual(calls, [
    { method: "getinfo", params: [], rune: "default-rune" },
    { method: "invoice", params: { amount_msat: 1000 }, rune: "invoice-rune" }
  ]);
});

test("client refuses RPC calls without a rune", async () => {
  const transport = {
    publicKey: "02" + "11".repeat(32),
    privateKey: "22".repeat(32),
    async commando() {
      assert.fail("commando should not be called");
    },
    disconnect() {}
  };
  const client = new ZaptunnelClient(transport, {
    nodeId: "03" + "33".repeat(32),
    address: "node.example.com:9735"
  });

  await assert.rejects(
    client.getInfo(),
    (error) => error instanceof ZaptunnelError && error.code === "rune_required"
  );
});

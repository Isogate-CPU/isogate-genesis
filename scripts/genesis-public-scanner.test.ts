import assert from "node:assert/strict";
import test from "node:test";
import { requireIndexedReconciliation } from "./genesis-public-scanner.js";

test("live launch cannot report complete when authoritative reconciliation is pending", () => {
  assert.throws(
    () => requireIndexedReconciliation({
      status: "pending_indexing",
      onChain: "verified",
      sourcify: { token: "exact_match", hook: "exact_match" },
      scanners: [{ name: "audit", token: "pending", hook: "exact_match" }],
    }),
    /source indexing is still pending/,
  );
});

test("live launch accepts only a completed indexed launch response", () => {
  const completed = {
    chainId: 4663,
    tokenAddress: "0x0000000000000000000000000000000000000001",
    launchTxHash: `0x${"11".repeat(32)}`,
  };
  assert.equal(requireIndexedReconciliation(completed), completed);
  assert.throws(() => requireIndexedReconciliation({ status: "indexed" }));
});
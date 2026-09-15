import assert from "node:assert/strict";
import test from "node:test";
import { parseCreate2Salt, requireSuccessfulReceipts, requireTransactionTarget } from "./genesis-verification-helpers.js";

test("CREATE2 salt accepts decimal and hexadecimal uint256 values", () => {
  assert.equal(parseCreate2Salt("0"), 0n);
  assert.equal(parseCreate2Salt("123456"), 123456n);
  assert.equal(parseCreate2Salt("0xabcdef"), 0xabcdefn);
  assert.equal(parseCreate2Salt(`0x${"f".repeat(64)}`), (1n << 256n) - 1n);
});

test("CREATE2 salt rejects malformed and out-of-range values", () => {
  for (const value of ["-1", "0x", "0xgg", "01", `0x1${"0".repeat(64)}`]) {
    assert.throws(() => parseCreate2Salt(value));
  }
});

test("verification rejects wrong or failed successful-transaction bindings", () => {
  assert.doesNotThrow(() => requireSuccessfulReceipts([{ status: "success" }, { status: "success" }], 2));
  assert.throws(() => requireSuccessfulReceipts([{ status: "success" }, { status: "reverted" }], 2));
  assert.throws(() => requireSuccessfulReceipts([{ status: "success" }], 2));
  assert.doesNotThrow(() => requireTransactionTarget("0xAa", "0xaa", "factory"));
  assert.throws(() => requireTransactionTarget("0xbb", "0xaa", "factory"));
});
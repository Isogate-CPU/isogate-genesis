import type { Hash } from "viem";

const UINT256_MAX = (1n << 256n) - 1n;

export function parseCreate2Salt(value: string): bigint {
  if (!/^(?:0|[1-9][0-9]*|0[xX][0-9a-fA-F]+)$/.test(value)) {
    throw new Error("CREATE2 salt must be decimal or 0x-prefixed hexadecimal");
  }
  const salt = BigInt(value);
  if (salt < 0n || salt > UINT256_MAX) throw new Error("CREATE2 salt is outside uint256 range");
  return salt;
}

export function requireSuccessfulReceipts(
  receipts: readonly { status: string }[],
  expectedCount: number,
): void {
  if (receipts.length !== expectedCount || receipts.some((receipt) => receipt.status !== "success")) {
    throw new Error("Transaction binding requires the expected successful receipts");
  }
}

export function requireTransactionTarget(actual: string | null, expected: string, label: string): void {
  if (!actual || actual.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`${label} transaction target does not match trusted target`);
  }
}

export function equalTransactionHash(actual: Hash, expected: Hash): boolean {
  return actual.toLowerCase() === expected.toLowerCase();
}
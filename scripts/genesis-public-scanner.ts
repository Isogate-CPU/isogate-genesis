type Json = Record<string, unknown>;

export function requireIndexedReconciliation(result: Json): Json {
  if (result.status === "pending_indexing") {
    throw new Error("Genesis launch is on-chain verified but public source indexing is still pending");
  }
  if (result.chainId !== 4663
    || typeof result.tokenAddress !== "string"
    || typeof result.launchTxHash !== "string") {
    throw new Error("Genesis reconciliation did not return a completed indexed launch");
  }
  return result;
}
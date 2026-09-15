import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const address = (name: string): string => {
  const value = process.env[name];
  if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new Error(`${name} must be an explicit 20-byte address`);
  }
  return value;
};

const hash = (name: string): string => {
  const value = process.env[name];
  if (!value || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`${name} must be an explicit 32-byte hash`);
  }
  return value;
};

/** Write offline inputs only; no RPC, key, transaction, or explorer API. */
async function main() {
  const outputDirectory = resolve(process.env.GENESIS_VERIFY_OUTPUT_DIRECTORY ?? "verification/local");
  const output = {
    schemaVersion: 1,
    submitted: false,
    network: process.env.GENESIS_VERIFY_NETWORK ?? "unspecified",
    chainId: process.env.GENESIS_VERIFY_CHAIN_ID ?? "unspecified",
    contract: process.env.GENESIS_VERIFY_CONTRACT ?? "IsogateGenesisToken",
    address: address("GENESIS_VERIFY_ADDRESS"),
    creationTransaction: hash("GENESIS_VERIFY_CREATION_TX"),
    sourceCommit: process.env.GENESIS_VERIFY_SOURCE_COMMIT ?? "unspecified",
    note: "Local input record only; no verification or deployment is performed.",
  };
  await mkdir(outputDirectory, { recursive: true });
  const outputPath = join(outputDirectory, "inputs.json");
  await writeFile(outputPath, `${JSON.stringify(output, null, 2)}\n`, "utf8");
  console.log(`Wrote ${outputPath}`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : "Unable to prepare verification inputs");
  process.exitCode = 1;
});

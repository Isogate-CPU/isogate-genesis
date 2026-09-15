import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";

const SUPPLY = 1_000_000_000n * 10n ** 18n;
const BURN = 1_000_000n * 10n ** 18n;
const POST_BURN = SUPPLY - BURN;
const CID = `ipfs://Qm${"1".repeat(44)}`;
const HOOK_PERMISSION_MASK = 0x2000n;

async function mineHookSalt(
  publicClient: any,
  coordinator: `0x${string}`,
  token: `0x${string}`,
): Promise<bigint> {
  const abi = [
    {
      type: "function",
      name: "findHookSalt",
      stateMutability: "view",
      inputs: [
        { name: "token", type: "address" },
        { name: "start", type: "uint256" },
        { name: "attempts", type: "uint256" },
      ],
      outputs: [
        { name: "salt", type: "uint256" },
        { name: "predicted", type: "address" },
      ],
    },
  ] as const;
  // The loop executes only inside eth_call. The state-changing launch validates
  // one supplied salt and executes CREATE2 once.
  for (let base = 0n; base < 1_048_576n; base += 8_192n) {
    try {
      const [salt, predicted] = await publicClient.readContract({
        address: coordinator,
        abi,
        functionName: "findHookSalt",
        args: [token, base, 8_192n],
      });
      assert.equal((BigInt(predicted) & 0x3fffn), HOOK_PERMISSION_MASK);
      return salt;
    } catch {
      // Try the next bounded read-only batch.
    }
  }
  throw new Error("unable to mine hook salt");
}

describe("Isogate Genesis suite", async () => {
  const { viem } = await network.connect();
  const [creator, protocol, other] = await viem.getWalletClients();
  const publicClient = await viem.getPublicClient();

  const proofTypes = {
    IdentityProof: [
      { name: "providerJobRef", type: "bytes32" },
      { name: "providerRef", type: "bytes32" },
      { name: "creator", type: "address" },
      { name: "factory", type: "address" },
      { name: "protocol", type: "address" },
      { name: "name", type: "string" },
      { name: "symbol", type: "string" },
      { name: "descriptionHash", type: "bytes32" },
      { name: "engineHash", type: "bytes32" },
      { name: "seedHash", type: "bytes32" },
      { name: "cpuDigest", type: "bytes32" },
      { name: "imageDigest", type: "bytes32" },
      { name: "logoUri", type: "string" },
      { name: "expiry", type: "uint256" },
      { name: "nonce", type: "uint256" },
    ],
  } as const;

  async function signedProof(
    registry: { address: `0x${string}` },
    factory: `0x${string}`,
    job: string,
    nonce = 1n,
  ) {
    const proof = {
      providerJobRef: `0x${job.repeat(64).slice(0, 64)}` as `0x${string}`,
      providerRef: `0x${"aa".repeat(32)}` as `0x${string}`,
      creator: creator.account.address,
      factory,
      protocol: protocol.account.address,
      name: "Genesis",
      symbol: "GEN",
      descriptionHash: `0x${"bb".repeat(32)}` as `0x${string}`,
      engineHash: `0x${"cc".repeat(32)}` as `0x${string}`,
      seedHash: `0x${"dd".repeat(32)}` as `0x${string}`,
      cpuDigest: `0x${"ee".repeat(32)}` as `0x${string}`,
      imageDigest: `0x${"ff".repeat(32)}` as `0x${string}`,
      logoUri: CID,
      expiry: 9_999_999_999n,
      nonce,
    };
    const signature = await protocol.signTypedData({
      domain: {
        name: "Isogate Genesis Identity",
        version: "1",
        chainId: await publicClient.getChainId(),
        verifyingContract: registry.address,
      },
      types: proofTypes,
      primaryType: "IdentityProof",
      message: proof,
    });
    return { proof, signature };
  }

  async function deploySystem(job = "launch", nonce = 1n) {
    const weth = await viem.deployContract("GenesisMockWETH");
    const poolManager = await viem.deployContract("GenesisMockPoolManager");
    const permit2 = await viem.deployContract("GenesisMockPermit2");
    const positionManager = await viem.deployContract("GenesisMockPositionManager", [
      poolManager.address,
      permit2.address,
      weth.address,
    ]);
    const registry = await viem.deployContract("IsogateGenesisIdentityRegistry", [
      protocol.account.address,
    ]);
    const factory = await viem.deployContract("IsogateGenesisFactory", [
      registry.address,
      protocol.account.address,
      weth.address,
    ]);
    const coordinator = await viem.deployContract("IsogateGenesisLaunchCoordinator", [
      poolManager.address,
      positionManager.address,
      permit2.address,
      weth.address,
      factory.address,
    ]);
    await factory.write.configureLaunchCoordinator([coordinator.address], {
      account: protocol.account,
    });
    const { proof, signature } = await signedProof(
      registry,
      factory.address,
      job,
      nonce,
    );
    const digest = await registry.read.identityDigest([proof]);
    await registry.write.approveIdentity([proof, signature], {
      account: creator.account,
    });
    await factory.write.deployGenesis([digest], { account: creator.account });
    const tokenAddress = await factory.read.tokenByGenesisDigest([digest]);
    const vaultAddress = await factory.read.feeVaultOf([tokenAddress]);
    return {
      weth,
      poolManager,
      permit2,
      positionManager,
      registry,
      factory,
      coordinator,
      token: await viem.getContractAt("IsogateGenesisToken", tokenAddress),
      vault: await viem.getContractAt("IsogateGenesisFeeVault", vaultAddress),
    };
  }

  it("creates exactly the fixed supply and immutable identity", async () => {
    const token = await viem.deployContract("IsogateGenesisToken", [
      "Genesis",
      "GEN",
      creator.account.address,
      `0x${"11".repeat(32)}`,
      CID,
      other.account.address,
    ]);
    assert.equal(await token.read.totalSupply(), POST_BURN);
    assert.equal(await token.read.balanceOf([creator.account.address]), 0n);
    assert.equal(await token.read.balanceOf([other.account.address]), POST_BURN);
    assert.equal(
      await token.read.balanceOf(["0x000000000000000000000000000000000000dEaD"]),
      0n,
    );
    assert.equal(await token.read.owner(), "0x0000000000000000000000000000000000000000");
    const ownershipLogs = await publicClient.getLogs({
      address: token.address,
      event: {
        type: "event",
        name: "OwnershipTransferred",
        inputs: [
          { indexed: true, name: "previousOwner", type: "address" },
          { indexed: true, name: "newOwner", type: "address" },
        ],
      },
      fromBlock: 0n,
      toBlock: "latest",
    });
    assert.ok(ownershipLogs.some((log) => log.args.newOwner === "0x0000000000000000000000000000000000000000"));
    const burnLogs = await publicClient.getLogs({
      address: token.address,
      event: {
        type: "event",
        name: "Transfer",
        inputs: [
          { indexed: true, name: "from", type: "address" },
          { indexed: true, name: "to", type: "address" },
          { indexed: false, name: "value", type: "uint256" },
        ],
      },
      fromBlock: 0n,
      toBlock: "latest",
    });
    assert.ok(burnLogs.some((log) =>
      log.args.from?.toLowerCase() === other.account.address.toLowerCase()
      && log.args.to === "0x0000000000000000000000000000000000000000"
      && log.args.value === BURN,
    ));
    assert.equal(
      (await token.read.creator()).toLowerCase(),
      creator.account.address.toLowerCase(),
    );
    assert.equal(
      await token.read.logo(),
      CID,
    );
    assert.equal(
      token.abi.some(
        (item) =>
          item.type === "function" &&
          (item.name === "mint" || item.name === "burn" || item.name === "admin"),
      ),
      false,
    );
  });

  it("rejects noncanonical logo URIs", async () => {
    for (const logo of [
      "https://gateway.pinata.cloud/ipfs/Qmfoo",
      "ipfs://Qmfoo/path",
      "isogate://rgb565/Qmfoo",
    ]) {
      await assert.rejects(
        viem.deployContract("IsogateGenesisToken", [
          "Genesis",
          "GEN",
          creator.account.address,
          `0x${"12".repeat(32)}`,
          logo,
          creator.account.address,
        ]),
      );
    }
  });

  it("launches one native/token position with fixed price and asymmetric range", async () => {
    const system = await deploySystem("51");
    const hookSalt = await mineHookSalt(
      publicClient,
      system.coordinator.address,
      system.token.address,
    );
    let invalidSalt = hookSalt + 1n;
    while (
      (BigInt(
        await system.coordinator.read.predictHookAddress([
          system.token.address,
          invalidSalt,
        ]),
      ) &
        0x3fffn) === HOOK_PERMISSION_MASK
    ) {
      invalidSalt += 1n;
    }
    await assert.rejects(
      system.factory.write.launchGenesis([system.token.address, invalidSalt], {
        account: creator.account,
        value: 2n * 10n ** 18n,
      }),
    );
    await system.factory.write.launchGenesis([system.token.address, hookSalt], {
      account: creator.account,
      value: 2n * 10n ** 18n,
    });

    assert.equal(await system.poolManager.read.initialized(), true);
    assert.equal(
      await system.poolManager.read.sqrtPriceX96(),
      34_500n * 2n ** 96n,
    );
    assert.equal(await system.poolManager.read.fee(), 10_000);
    assert.equal(await system.poolManager.read.tickSpacing(), 200);
    assert.equal(await system.poolManager.read.currency0(), "0x0000000000000000000000000000000000000000");
    assert.equal(
      (await system.poolManager.read.currency1()).toLowerCase(),
      system.token.address.toLowerCase(),
    );
    assert.equal(
      (await system.poolManager.read.hooks()).toLowerCase(),
      (await system.coordinator.read.hookOf([system.token.address])).toLowerCase(),
    );
    // (34,500 Q96)^2 / Q192 = 1,190,250,000 token per native.
    assert.equal(34_500n * 34_500n, 1_190_250_000n);
    assert.equal(
      (await system.coordinator.read.OFFICIAL_POOL_MANAGER()).toLowerCase(),
      "0x8366a39cc670b4001a1121b8f6a443a643e40951",
    );
    assert.equal(
      (await system.coordinator.read.OFFICIAL_POSITION_MANAGER()).toLowerCase(),
      "0x58daec3116aae6d93017baaea7749052e8a04fa7",
    );
    assert.equal(
      (await system.coordinator.read.OFFICIAL_WETH()).toLowerCase(),
      "0x0bd7d308f8e1639fab988df18a8011f41eacad73",
    );
    assert.equal(
      await system.token.read.balanceOf([system.factory.address]),
      0n,
    );
    const tokenDust = await system.coordinator.read.tokenDustOf([system.token.address]);
    const pooledTokens = await system.token.read.balanceOf([system.positionManager.address]);
    const burnedDust = await system.token.read.balanceOf([
      "0x000000000000000000000000000000000000dEaD",
    ]);
    assert.ok(tokenDust > 0n);
    assert.equal(burnedDust, tokenDust);
    assert.equal(pooledTokens + tokenDust, POST_BURN);
    assert.equal(await system.token.read.balanceOf([creator.account.address]), 0n);

    const lockAddress = await system.coordinator.read.positionLockOf([
      system.token.address,
    ]);
    const lock = await viem.getContractAt("IsogateGenesisPositionLock", lockAddress);
    assert.equal(
      (await system.positionManager.read.ownerOf([1n])).toLowerCase(),
      lockAddress.toLowerCase(),
    );
    assert.equal(
      (await lock.read.feeVault()).toLowerCase(),
      system.vault.address.toLowerCase(),
    );

    const tickLower = await system.positionManager.read.positionTickLower();
    const tickUpper = await system.positionManager.read.positionTickUpper();
    assert.equal(tickLower, -887_200);
    assert.equal(tickUpper, 209_000);
    assert.ok(tickLower < 0 && tickUpper > 0);
    assert.ok(
      (await system.positionManager.read.mintedAmount0()) <= 2n * 10n ** 18n,
    );
    assert.ok(
      (await system.positionManager.read.mintedAmount1()) <= POST_BURN,
    );
    assert.equal(
      await system.token.read.allowance([
        system.coordinator.address,
        system.permit2.address,
      ]),
      0n,
    );
    assert.equal(
      await system.permit2.read.allowance([
        system.token.address,
        system.coordinator.address,
        system.positionManager.address,
      ]),
      0n,
    );
  });

  it("allows only the approved creator to launch, exactly once", async () => {
    const system = await deploySystem("52");
    await assert.rejects(
      system.factory.write.launchGenesis([system.token.address, 0n], {
        account: other.account,
        value: 2n * 10n ** 18n,
      }),
    );
    const hookSalt = await mineHookSalt(
      publicClient,
      system.coordinator.address,
      system.token.address,
    );
    await system.factory.write.launchGenesis([system.token.address, hookSalt], {
      account: creator.account,
      value: 2n * 10n ** 18n,
    });
    await assert.rejects(
      system.factory.write.launchGenesis([system.token.address, hookSalt], {
        account: creator.account,
        value: 2n * 10n ** 18n,
      }),
    );
  });

  it("keeps the NFT and principal locked and exposes only fee collection", async () => {
    const system = await deploySystem("53");
    const hookSalt = await mineHookSalt(
      publicClient,
      system.coordinator.address,
      system.token.address,
    );
    await system.factory.write.launchGenesis([system.token.address, hookSalt], {
      account: creator.account,
      value: 2n * 10n ** 18n,
    });
    const lockAddress = await system.coordinator.read.positionLockOf([
      system.token.address,
    ]);
    const lock = await viem.getContractAt("IsogateGenesisPositionLock", lockAddress);
    const lockFunctionNames = lock.abi
      .filter((item) => item.type === "function")
      .map((item) => item.name);
    assert.deepEqual(lockFunctionNames.sort(), [
      "collectFees",
      "currency0",
      "currency1",
      "feeVault",
      "genesisToken",
      "positionManager",
      "tokenId",
    ]);
    assert.equal(
      (await system.positionManager.read.ownerOf([1n])).toLowerCase(),
      lockAddress.toLowerCase(),
    );
  });

  it("permissionlessly collects native and token fees into exact 70/30 vault dues", async () => {
    const system = await deploySystem("54");
    const hookSalt = await mineHookSalt(
      publicClient,
      system.coordinator.address,
      system.token.address,
    );
    await system.factory.write.launchGenesis([system.token.address, hookSalt], {
      account: creator.account,
      value: 2n * 10n ** 18n,
    });
    const lockAddress = await system.coordinator.read.positionLockOf([
      system.token.address,
    ]);
    const lock = await viem.getContractAt("IsogateGenesisPositionLock", lockAddress);
    const nativeFees = 101n;
    const tokenFees = 1_001n;
    await system.positionManager.write.seedNativeFees([], {
      account: creator.account,
      value: nativeFees,
    });
    await system.positionManager.write.seedTokenFees(
      [system.token.address, tokenFees],
      { account: creator.account },
    );
    await lock.write.collectFees({ account: other.account });
    assert.equal(await system.vault.read.creatorNativeDue(), 70n);
    assert.equal(await system.vault.read.protocolNativeDue(), 31n);
    assert.equal(await system.vault.read.creatorGenesisTokenDue(), 700n);
    assert.equal(await system.vault.read.protocolGenesisTokenDue(), 301n);
  });

  it("accounts native, WETH, and genesis token deposits with exact 70/30 rounding", async () => {
    const weth = await viem.deployContract("GenesisTestWETH");
    const vault = await viem.deployContract("IsogateGenesisFeeVault", [
      creator.account.address,
      protocol.account.address,
      weth.address,
    ]);
    await creator.sendTransaction({ to: vault.address, value: 101n });
    await creator.sendTransaction({ to: vault.address, value: 1n });
    assert.equal(await vault.read.creatorNativeDue(), 70n);
    assert.equal(await vault.read.protocolNativeDue(), 32n);

    await weth.write.mint([other.account.address, 1_001n], { account: other.account });
    await weth.write.approve([vault.address, 1_001n], { account: other.account });
    await vault.write.depositWETH([1_001n], { account: other.account });
    assert.equal(await vault.read.creatorWethDue(), 700n);
    assert.equal(await vault.read.protocolWethDue(), 301n);
    await vault.write.claimCreator({ account: creator.account });
    await vault.write.claimProtocol({ account: protocol.account });
    assert.equal(await vault.read.creatorNativeDue(), 0n);
    assert.equal(await vault.read.protocolWethDue(), 0n);
  });

  it("fails closed for wrong dependency/configuration wiring", async () => {
    const weth = await viem.deployContract("GenesisMockWETH");
    const pool = await viem.deployContract("GenesisMockPoolManager");
    const otherPool = await viem.deployContract("GenesisMockPoolManager");
    const permit = await viem.deployContract("GenesisMockPermit2");
    const posm = await viem.deployContract("GenesisMockPositionManager", [
      pool.address,
      permit.address,
      weth.address,
    ]);
    await assert.rejects(
      viem.deployContract("IsogateGenesisLaunchCoordinator", [
        otherPool.address,
        posm.address,
        permit.address,
        weth.address,
        creator.account.address,
      ]),
    );
    await assert.rejects(
      viem.deployContract("IsogateGenesisLaunchCoordinator", [
        pool.address,
        posm.address,
        "0x0000000000000000000000000000000000000000",
        weth.address,
        creator.account.address,
      ]),
    );

    const registry = await viem.deployContract("IsogateGenesisIdentityRegistry", [
      protocol.account.address,
    ]);
    const factory = await viem.deployContract("IsogateGenesisFactory", [
      registry.address,
      protocol.account.address,
      weth.address,
    ]);
    const wrongCoordinator = await viem.deployContract("IsogateGenesisLaunchCoordinator", [
      pool.address,
      posm.address,
      permit.address,
      weth.address,
      other.account.address,
    ]);
    await assert.rejects(
      factory.write.configureLaunchCoordinator([wrongCoordinator.address], {
        account: protocol.account,
      }),
    );
  });
});
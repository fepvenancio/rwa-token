// SPDX-License-Identifier: UNLICENSED
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import {
  encodeFunctionData,
  getAddress,
  hashTypedData,
  keccak256,
  parseEther,
  toHex,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
} from "viem";

import { ROLES } from "../../ignition/modules/roles.js";
import { DEMO_VALIDITY, deployStack, QUALS, REASONS, revertOf, STATUS, verify, type Stack } from "./fixtures.js";

const ICREDENTIAL_REGISTRY_ID = "0xd224eb70";
const IIDENTITY_REGISTRY_ID = "0xb9209e33";

/** The EIP-712 type the attester signs: `ICredentialRegistry.Credential`. */
const CREDENTIAL_TYPES = {
  Credential: [
    { name: "subject", type: "address" },
    { name: "validUntil", type: "uint64" },
    { name: "quals", type: "uint32" },
    { name: "issuedAt", type: "uint64" },
    { name: "attester", type: "uint8" },
  ],
} as const;

describe("credentials: the registry and the rule through the real deployment", async function () {
  const connection = await network.create();
  const { networkHelpers } = connection;
  const stack = () => deployStack(connection);

  let saltCounter = 0;
  /** Governance proposes on the main timelock; the guardian can cancel there. */
  async function schedule(s: Stack, target: Address, data: Hex) {
    const delay = await s.timelock.read.getMinDelay();
    const args = [target, 0n, data, zeroHash, keccak256(toHex(`credential-op-${saltCounter++}`))] as const;
    await s.timelock.write.schedule([...args, delay], { account: s.wallets.governance.account });
    return {
      id: await s.timelock.read.hashOperation(args),
      execute: () => s.timelock.write.execute(args, { account: s.wallets.governance.account }),
      delay,
    };
  }
  /** Governance proposes on the recovery timelock; no one can cancel there. */
  async function scheduleRecovery(s: Stack, target: Address, data: Hex) {
    const delay = await s.recoveryTimelock.read.getMinDelay();
    const salt = keccak256(toHex(`credential-recovery-${saltCounter++}`));
    await s.recoveryTimelock.write.scheduleBatch([[target], [0n], [data], zeroHash, salt, delay], {
      account: s.wallets.governance.account,
    });
    return {
      id: await s.recoveryTimelock.read.hashOperationBatch([[target], [0n], [data], zeroHash, salt]),
      execute: () =>
        s.recoveryTimelock.write.executeBatch([[target], [0n], [data], zeroHash, salt], { account: s.wallets.governance.account }),
      delay,
    };
  }
  const encode = (c: { abi: unknown }, functionName: string, args: readonly unknown[]) =>
    encodeFunctionData({ abi: c.abi as Abi, functionName, args } as never);

  const mintTo = (s: Stack, to: Address, amount: bigint) => s.token.write.mint([to, amount], { account: s.wallets.minter.account });
  const standing = async (s: Stack, who: Address) => (await s.credentials.read.profileOf([who]))[0];

  it("is wired by the deployment: the roles, the one attester, ERC-165, and a policy on every token", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const { credentials } = s;
    assert.equal(await credentials.read.hasRole([ROLES.DEFAULT_ADMIN, s.timelock.address]), true);
    assert.equal(await credentials.read.hasRole([ROLES.DEFAULT_ADMIN, s.wallets.deployer.account.address]), false);
    assert.equal(await credentials.read.hasRole([ROLES.RECOVERY, s.recoveryTimelock.address]), true);
    assert.equal(await credentials.read.hasRole([ROLES.GUARDIAN, s.wallets.guardian.account.address]), true);
    assert.equal(await credentials.read.supportsInterface([ICREDENTIAL_REGISTRY_ID]), true);
    assert.equal(await credentials.read.supportsInterface([IIDENTITY_REGISTRY_ID]), true);

    const attester = await credentials.read.attesterAt([0]);
    assert.equal(getAddress(attester.account), getAddress(s.wallets.kyc.account.address));
    assert.equal(attester.allowedQuals, 1023, "the demo provider may assert the ten named bits");

    const alice = s.holders.alice.account.address;
    assert.deepEqual(await credentials.read.profileOf([alice]), [STATUS.ACTIVE, QUALS.KYC, 0]);
    // The escrow is the token's own address, so the vault needs no credential for its own shares.
    assert.deepEqual(await credentials.read.profileOf([s.vault7540.address]), [STATUS.NONE, 0, 0]);
    assert.equal(await credentials.read.isVerified([alice]), true);
    assert.equal(await s.rules.credentialRule.read.ruleId(), keccak256(toHex("CredentialRule.v1")));
  });

  it("an address with a credential receives and one without does not, and the token's probes and pre-flight say so", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const eve = s.holders.eve.account.address;
    assert.equal(await s.token.read.canReceive([eve]), false);
    assert.deepEqual(await s.token.read.canTransferWithReason([zeroAddress, eve, 1n]), [false, REASONS.RECEIVER_NOT_VERIFIED]);
    const refused = await revertOf(s.token.simulate.mint([eve, 1n], { account: s.wallets.minter.account.address }), s.token.abi);
    assert.deepEqual(refused, { errorName: "ERC8473PolicyRejected", args: [REASONS.RECEIVER_NOT_VERIFIED] });

    await verify(s, s.holders.eve);
    assert.equal(await s.token.read.canReceive([eve]), true);
    assert.deepEqual(await s.token.read.canTransferWithReason([zeroAddress, eve, 1n]), [true, REASONS.TRANSFER_OK]);
    await mintTo(s, eve, parseEther("1"));
    assert.equal(await s.token.read.balanceOf([eve]), parseEther("1"));
  });

  it("a credential the attester signed with viem, submitted by a stranger, makes an address eligible; a replay and a forgery do not", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const eve = s.holders.eve.account.address;
    const stranger = s.holders.bob.account;
    const now = (await s.publicClient.getBlock()).timestamp;
    const credential = { subject: eve, validUntil: now + DEMO_VALIDITY, quals: QUALS.KYC, issuedAt: now, attester: 0 };
    const [, name, version, chainId, verifyingContract] = await s.credentials.read.eip712Domain();
    const domain = { name, version, chainId, verifyingContract };
    const message = { ...credential };
    const sign = (wallet: Stack["wallets"]["kyc"] | Stack["holders"]["alice"]) =>
      wallet.signTypedData({ domain, types: CREDENTIAL_TYPES, primaryType: "Credential", message });

    // The digest viem computes off chain is the one the registry computes on chain.
    assert.equal(await s.credentials.read.credentialHash([credential]), hashTypedData({ domain, types: CREDENTIAL_TYPES, primaryType: "Credential", message }));

    const forged = await revertOf(s.credentials.simulate.register([credential, await sign(s.holders.alice)], { account: stranger.address }), s.credentials.abi);
    assert.equal(forged?.errorName, "CredentialRegistry_BadSignature");

    const sig = await sign(s.wallets.kyc);
    await s.credentials.write.register([credential, sig], { account: stranger });
    assert.equal(await s.token.read.canReceive([eve]), true);
    assert.deepEqual(await s.credentials.read.profileOf([eve]), [STATUS.ACTIVE, QUALS.KYC, 0]);

    const replay = await revertOf(s.credentials.simulate.register([credential, sig], { account: stranger.address }), s.credentials.abi);
    assert.equal(replay?.errorName, "CredentialRegistry_StaleCredential");
  });

  it("a credential lapses on the real clock: the holder can still send, but cannot receive until it is renewed", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const dave = s.holders.dave.account;
    const bob = s.holders.bob.account.address;
    await mintTo(s, dave.address, parseEther("5"));
    await verify(s, s.holders.dave, { validFor: 3_600n });
    assert.equal(await standing(s, dave.address), STATUS.ACTIVE);

    await networkHelpers.time.increase(3_601n);
    assert.equal(await standing(s, dave.address), STATUS.LAPSED);
    assert.equal(await s.token.read.canSend([dave.address]), true);
    assert.equal(await s.token.read.canReceive([dave.address]), false);
    await s.token.write.transfer([bob, parseEther("1")], { account: dave });
    const refused = await revertOf(s.token.simulate.mint([dave.address, 1n], { account: s.wallets.minter.account.address }), s.token.abi);
    assert.deepEqual(refused, { errorName: "ERC8473PolicyRejected", args: [REASONS.CREDENTIAL_EXPIRED] });

    await verify(s, s.holders.dave);
    assert.equal(await s.token.read.canReceive([dave.address]), true);
  });

  it("the guardian blocks at once; only the recovery timelock can lift it, because the guardian can cancel on the main one", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const guardian = s.wallets.guardian.account;
    const alice = s.holders.alice.account;
    const recovery = s.wallets.recovery.account.address;
    await mintTo(s, alice.address, parseEther("10"));

    await s.credentials.write.blockSubject([alice.address], { account: guardian });
    assert.equal(await standing(s, alice.address), STATUS.BLOCKED);
    assert.equal(await s.token.read.canSend([alice.address]), false);
    const refused = await revertOf(s.token.simulate.transfer([recovery, 1n], { account: alice.address }), s.token.abi);
    assert.deepEqual(refused, { errorName: "ERC8473PolicyRejected", args: [REASONS.SENDER_NOT_ELIGIBLE] });
    // Enforcement is not blocked by the block: the agent takes the tokens to a credentialed account.
    await s.token.write.forcedTransfer([alice.address, recovery, parseEther("1")], { account: s.wallets.agent.account });
    assert.equal(await s.token.read.balanceOf([recovery]), parseEther("1"));

    // The main timelock's unblock is vetoed by the guardian, which holds CANCELLER_ROLE there.
    const clear = encode(s.credentials, "clearGuardianBlock", [alice.address]);
    const viaMain = await schedule(s, s.credentials.address, clear);
    await s.timelock.write.cancel([viaMain.id], { account: guardian });

    // Nobody can cancel on the recovery timelock, so it lifts the block after its delay.
    const viaRecovery = await scheduleRecovery(s, s.credentials.address, clear);
    await networkHelpers.time.increase(viaRecovery.delay);
    await viaRecovery.execute();
    assert.equal(await standing(s, alice.address), STATUS.ACTIVE);
    await s.token.write.transfer([recovery, parseEther("1")], { account: alice });
  });

  it("killing the attester leaves its holders able to exit and not to receive; the recovery timelock revives it", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const alice = s.holders.alice.account.address;
    await s.credentials.write.killAttester([0], { account: s.wallets.guardian.account });
    assert.equal((await s.credentials.read.attesterAt([0])).killed, true);
    assert.equal(await standing(s, alice), STATUS.EXIT_ONLY);
    assert.equal(await s.token.read.canSend([alice]), true);
    assert.equal(await s.token.read.canReceive([alice]), false);
    const writes = await revertOf(
      s.credentials.simulate.set([s.holders.eve.account.address, 1n << 40n, QUALS.KYC], { account: s.wallets.kyc.account.address }),
      s.credentials.abi,
    );
    assert.deepEqual(writes, { errorName: "CredentialRegistry_AttesterKilled", args: [0] });

    const revival = await scheduleRecovery(s, s.credentials.address, encode(s.credentials, "reviveAttester", [0]));
    await networkHelpers.time.increase(revival.delay);
    await revival.execute();
    assert.equal(await standing(s, alice), STATUS.ACTIVE);
    assert.equal(await s.token.read.canReceive([alice]), true);
  });

  it("a token's policy is its timelock's to change, and then the holder's type decides who may receive", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const alice = s.holders.alice.account.address;
    const bob = s.holders.bob.account.address;
    await mintTo(s, alice, parseEther("5"));
    const professionals = [QUALS.KYC, QUALS.PROFESSIONAL | QUALS.INFRA, 0, 1n] as const;

    const outsider = await revertOf(
      s.rules.credentialRule.simulate.setPolicy([s.token.address, ...professionals], { account: s.wallets.governance.account.address }),
      s.rules.credentialRule.abi,
    );
    assert.equal(outsider?.errorName, "CredentialRule_OnlyTokenAdmin");

    const change = await schedule(s, s.rules.credentialRule.address, encode(s.rules.credentialRule, "setPolicy", [s.token.address, ...professionals]));
    await networkHelpers.time.increase(change.delay);
    await change.execute();

    // Everyone in the demo holds KYC only, so no one is eligible to receive this token now; holders can still leave.
    assert.deepEqual(await s.token.read.canTransferWithReason([alice, bob, 1n]), [false, REASONS.RECEIVER_NOT_ELIGIBLE]);
    assert.equal(await s.token.read.canSend([alice]), true);
    await verify(s, s.holders.bob, { quals: QUALS.KYC | QUALS.PROFESSIONAL });
    assert.deepEqual(await s.token.read.canTransferWithReason([alice, bob, 1n]), [true, REASONS.TRANSFER_OK]);
    // The other tokens keep their own policy.
    assert.equal(await s.vault4626.read.canReceive([s.holders.carol.account.address]), true);
  });

  it("the registry's events decode with their arguments", async function () {
    const s = await networkHelpers.loadFixture(stack);
    const eve = s.holders.eve.account.address;
    await verify(s, s.holders.eve, { quals: QUALS.KYC | QUALS.CUSTOMER, validFor: 86_400n });
    const set = await s.publicClient.getContractEvents({ address: s.credentials.address, abi: s.credentials.abi, eventName: "CredentialSet", fromBlock: 0n });
    const last = set.at(-1)!;
    assert.equal(getAddress(last.args._subject!), getAddress(eve));
    assert.equal(last.args._attester, 0);
    assert.equal(last.args._quals, QUALS.KYC | QUALS.CUSTOMER);

    await s.credentials.write.blockSubject([eve], { account: s.wallets.guardian.account });
    const blocked = await s.publicClient.getContractEvents({ address: s.credentials.address, abi: s.credentials.abi, eventName: "SubjectBlocked", fromBlock: 0n });
    assert.deepEqual(
      [getAddress(blocked.at(-1)!.args._subject!), getAddress(blocked.at(-1)!.args._guardian!)],
      [getAddress(eve), getAddress(s.wallets.guardian.account.address)],
    );
  });
});

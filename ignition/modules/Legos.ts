import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import type { NamedArtifactContractDeploymentFuture } from "@nomicfoundation/ignition-core";
import { keccak256, toHex, zeroAddress, zeroHash } from "viem";

import { activeProduct, assertUsable, type Product } from "../profiles.js";

/** Whether a product has anything for this module to deploy. */
export const hasLegos = (product: Product) =>
  product.nav !== undefined || product.portfolio !== undefined || product.fees !== undefined;

/**
 * Once per product that has legos, before its `Product` module, run by the operations account. A lego names its vault, so
 * it is built before the vault exists: `ProxyDeployer.predict(symbol, implementation)` gives the address. The council then
 * attests the portfolio, the adapters, the validators and the fee model, because the vault-side plugs refuse what is not
 * attested and `Product` plugs them in. `NavDesk` is not attested: it holds no money, and it acts by the role `Product`
 * grants it, which the hand-over check pins.
 *
 * Every setting of an attested lego is a constructor argument, so its codehash covers it. A desk with no portfolio names
 * its custodian's account here; one with a portfolio is told so by `Product`, while the operations account is the admin.
 */
export function legosModule(product: Product) {
  assertUsable(product);

  return buildModule(`Legos_${product.key}`, (m) => {
    const p = (name: string) => m.getParameter<string>(name);
    const vault = p("vault");
    const legos: Record<string, NamedArtifactContractDeploymentFuture<string>> = {};

    if (product.portfolio !== undefined) {
      const portfolio = m.contract("Portfolio", [vault, p("asset"), product.template === "Gated7540Vault"]);
      legos.portfolio = portfolio;
      for (const { key, maxPerCall } of product.portfolio.custodians ?? []) {
        // Each custodian is its own risk, so each has its own caps.
        legos[`account_${key}`] = m.contract("GuardedAccount", [portfolio, keccak256(toHex(`custodian:${key}`)), zeroHash], {
          id: `account_${key}`,
        });
        legos[`validator_${key}`] = m.contract("ERC20CallValidator", [p(`custodian_${key}`), maxPerCall], { id: `validator_${key}` });
      }
      for (const { key } of product.portfolio.targets ?? []) {
        legos[`adapter_${key}`] = m.contract("ERC4626Adapter", [portfolio, p(`target_${key}`), zeroHash], { id: `adapter_${key}` });
      }
    }
    if (product.nav !== undefined) {
      const { periodLength, cooldown, maxReportAge } = product.nav;
      const cash = product.portfolio === undefined ? p("custodianAccount") : zeroAddress;
      legos.navDesk = m.contract("NavDesk", [vault, cash, periodLength, cooldown, maxReportAge]);
    }
    if (product.fees !== undefined) {
      const { managementBps, performanceBps, hurdleBps, softHurdle } = product.fees;
      legos.feeModel = m.contract("FeeModel", [p("feeRecipient"), managementBps, performanceBps, hurdleBps, softHurdle]);
    }
    return legos;
  });
}

export default legosModule(activeProduct());

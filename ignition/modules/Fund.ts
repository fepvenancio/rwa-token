// SPDX-License-Identifier: UNLICENSED
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { activeFund } from "../profiles.js";

/**
 * Once per fund, run by the operations account: a `Fund` with the `FundHoldersRule` that points at it. An issuer has as many
 * as it has funds, each with its own investor cap. The rule's codehash covers the fund's address and not the fund's code,
 * so the council reads the fund's code and its owner before attesting the rule, which every class needs before it can
 * list it.
 */
export function fundModule(key: string) {
  return buildModule(`Fund_${key}`, (m) => {
    const fund = m.contract("Fund", [m.getParameter<string>("operations"), m.getParameter<string>("registry")]);
    const rule = m.contract("FundHoldersRule", [fund]);
    return { fund, rule };
  });
}

export default fundModule(activeFund());

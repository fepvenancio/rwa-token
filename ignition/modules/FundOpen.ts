// SPDX-License-Identifier: UNLICENSED
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import { activeFund, activeProfile, classesOf } from "../profiles.js";

/**
 * Once per fund, run by the operations account once its first classes are placed: install the rule, set the cap, register
 * the classes in the order given (a chain, so the numbering never depends on scheduling), and hand the fund to the
 * timelock. Registration refuses a hook that does not list the rule and a token that has supply.
 *
 * From here a later class or a rule change is a timelock operation, because either can change the room existing investors
 * have under the cap. A later class launches through `Product` like any other and is inert until the timelock registers it.
 */
export function fundOpenModule(key: string, classes: readonly string[]) {
  return buildModule(`FundOpen_${key}`, (m) => {
    const fund = m.contractAt("Fund", m.getParameter<string>("fundContract"));
    const ruleSet = m.call(fund, "setRule", [m.getParameter<string>("fundHoldersRule")]);
    const capSet = m.call(fund, "setHolderCap", [m.getParameter<bigint>("holderCap")]);

    let previous: ReturnType<typeof m.call>[] = [ruleSet, capSet];
    for (const name of classes) {
      const registration = m.call(fund, "registerClass", [m.getParameter<string>(`class_${name}`)], {
        id: `${name}_register`,
        after: previous,
      });
      previous = [registration];
    }
    m.call(fund, "transferOwnership", [m.getParameter<string>("timelock")], { after: previous });
    return {};
  });
}

export default fundOpenModule(activeFund(), classesOf(activeProfile(), activeFund()));

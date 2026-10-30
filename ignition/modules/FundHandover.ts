import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Once per fund, run by the operations account after its first classes are in. From here a later class or a rule change
 * is a timelock operation, because either can change the room existing investors have under the cap.
 */
export default buildModule("FundHandover", (m) => {
  const fund = m.contractAt("Fund", m.getParameter<string>("fundContract"));
  m.call(fund, "transferOwnership", [m.getParameter<string>("timelock")]);
  return {};
});

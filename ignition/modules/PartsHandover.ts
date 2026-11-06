// SPDX-License-Identifier: UNLICENSED
import { activeProfile, missingParts } from "../profiles.js";
import { coreHas, partsHandoverModule } from "../parts.js";

/**
 * The hand-over of the parts `CoreParts` added, run by the account that ran it, with the same `CORE_HAS`: the core's parts
 * before `CoreParts`, so the parts it computes are the ones that were added.
 */
export default partsHandoverModule(missingParts(activeProfile(), coreHas()));

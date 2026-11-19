// SPDX-License-Identifier: UNLICENSED
import { activeProfile, missingParts } from "../profiles.js";
import { corePartsModule, coreHas } from "../parts.js";

/**
 * Adds to a running core what the profile's products, or its signed entry or signed exit, need and the core lacks. `CORE_HAS` must list
 * the core's parts exactly, by key, separated by commas: the module deploys every part of the profile it does not list.
 * Then the council attests the new rules and implementations, then `PartsHandover` with the same `CORE_HAS`.
 */
export default corePartsModule(missingParts(activeProfile(), coreHas()), coreHas());

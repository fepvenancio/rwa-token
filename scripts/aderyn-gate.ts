// Aderyn CI gate: run with `npm run aderyn`. Aderyn has no fail-on-findings flag, so this reads its JSON report and
// fails on any high or low issue left after the exclusions in aderyn.toml and the inline suppressions.
import { execSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";

const report = "aderyn-report.json";
rmSync(report, { force: true });
execSync(`npx aderyn . -o ${report}`, { stdio: ["ignore", "ignore", "inherit"] });
const { issue_count: count, high_issues: high, low_issues: low } = JSON.parse(readFileSync(report, "utf8"));
const issues = [...high.issues, ...low.issues];
if (issues.length > 0) {
  for (const issue of issues) {
    for (const at of issue.instances) console.error(`${issue.detector_name}  ${at.contract_path}:${at.line_no}`);
  }
  console.error(`Aderyn: ${count.high} high, ${count.low} low. Fix, or suppress inline with the reason on the line above.`);
  process.exit(1);
}
console.log("Aderyn: 0 findings.");

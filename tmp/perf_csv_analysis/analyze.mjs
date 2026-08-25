import fs from "node:fs/promises";
import { Workbook } from "@oai/artifact-tool";

const csvPath = process.argv[2];
if (!csvPath) throw new Error("csv path required");
const csvText = await fs.readFile(csvPath, "utf8");
const workbook = await Workbook.fromCSV(csvText, { sheetName: "Perf" });
const sheet = workbook.worksheets.getItem("Perf");
const values = sheet.getUsedRange(true).values;
const headers = values[0].map(String);
const patterns = /bio|vision|border|fog|evidence|observation/i;
const selected = [];
for (let col = 0; col < headers.length; col++) {
  const name = headers[col];
  if (!patterns.test(name)) continue;
  const nums = values.slice(1).map(row => Number(row[col])).filter(Number.isFinite);
  const nonzero = nums.filter(value => value !== 0);
  const sorted = [...nums].sort((a, b) => a - b);
  const percentile = p => sorted.length ? sorted[Math.min(sorted.length - 1,
    Math.ceil(p * sorted.length) - 1)] : null;
  selected.push({
    name,
    rows: nums.length,
    nonzero_rows: nonzero.length,
    median: percentile(0.5),
    p95: percentile(0.95),
    max: sorted.length ? sorted[sorted.length - 1] : null,
  });
}
const inspect = await workbook.inspect({
  kind: "sheet,table",
  maxChars: 1200,
  tableMaxRows: 2,
  tableMaxCols: 4,
});
console.log(JSON.stringify({
  row_count: values.length - 1,
  column_count: headers.length,
  workbook_inspect: inspect.ndjson,
  metrics: selected,
}, null, 2));

import fs from "node:fs/promises";
import { Workbook } from "@oai/artifact-tool";

const files = process.argv.slice(2);
for (const file of files) {
  const handle = await fs.open(file, "r");
  const buffer = Buffer.alloc(2 * 1024 * 1024);
  const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
  await handle.close();
  const text = buffer.subarray(0, bytesRead).toString("utf8");
  let end = 0;
  for (let lines = 0; lines < 20 && end < text.length; ++end) {
    if (text.charCodeAt(end) === 10) ++lines;
  }
  const workbook = await Workbook.fromCSV(text.slice(0, end), { sheetName: "Perf" });
  const inspection = await workbook.inspect({
    kind: "sheet,table",
    sheetId: "Perf",
    range: "A1:BZ6",
    maxChars: 8000,
    tableMaxRows: 6,
    tableMaxCols: 78,
  });
  process.stdout.write(`${file}\n${inspection.ndjson}\n`);
}

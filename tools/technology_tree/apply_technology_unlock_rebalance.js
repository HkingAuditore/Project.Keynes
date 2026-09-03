#!/usr/bin/env node

"use strict";

const replacement = [
  "This generator has been retired.",
  "It created paid application shells and rewrote Godot resources with regular expressions.",
  "Run the schema-v4 technology-industry v2 generator instead:",
  "  godot --headless --path Project/project-keynes --script res://tools/migrate_technology_industry_v2.gd",
].join("\n");

console.error(replacement);
process.exitCode = 1;

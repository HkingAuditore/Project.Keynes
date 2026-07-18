'use strict';

const fs = require('node:fs');
const path = require('node:path');
const SC = require('./parser.js');

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--repo-root') args.repoRoot = argv[++i];
    else if (argv[i] === '--output') args.output = argv[++i];
    else if (argv[i] === '--stdout') args.stdout = true;
    else if (argv[i] === '--help' || argv[i] === '-h') args.help = true;
    else throw new Error(`未知参数: ${argv[i]}`);
  }
  return args;
}

function walk(directory, callback) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(fullPath, callback);
    else if (entry.isFile() && entry.name.endsWith('.tres')) callback(fullPath, entry.name);
  }
}

function compile(repoRoot) {
  const projectRoot = path.join(repoRoot, 'Project', 'project-keynes');
  const dataRoot = path.join(projectRoot, 'data');
  const taxonomyPath = path.join(projectRoot, 'scripts', 'economy', 'technology_taxonomy.gd');
  const registryPath = path.join(projectRoot, 'scripts', 'data', 'resource_profile_registry.gd');
  if (!fs.existsSync(dataRoot) || !fs.existsSync(taxonomyPath)) {
    throw new Error(`不是有效的 Project.Keynes 仓库根目录: ${repoRoot}`);
  }

  const data = {
    buildings: [], goods: [], resources: [], professions: [], plans: [], needs: [], economies: []
  };
  walk(dataRoot, (fullPath, filename) => {
    const parsed = SC.classifyAndParse(filename, fs.readFileSync(fullPath, 'utf8'));
    if (parsed && parsed.error) throw new Error(`${fullPath}: ${parsed.error}`);
    if (parsed && parsed.record) {
      parsed.record._file = path.relative(repoRoot, fullPath).replace(/\\/g, '/');
      data[SC.collectionKey(parsed.type)].push(parsed.record);
    }
  });
  data.eras = SC.parseEraFile(fs.readFileSync(taxonomyPath, 'utf8'));
  const registry = fs.readFileSync(registryPath, 'utf8');
  const scaleMatch = registry.match(/CELL_AREA_RESOURCE_SCALE\s*:\s*float\s*=\s*([0-9.]+)/);
  data.resourceQuantityScale = scaleMatch ? Number(scaleMatch[1]) : 100;

  const model = SC.buildModel(data);
  const compiled = SC.compileAnalyticalModel(model);
  compiled.source = {
    repo_root: path.resolve(repoRoot),
    project_data: path.relative(repoRoot, dataRoot).replace(/\\/g, '/'),
    entity_counts: {
      buildings: compiled.buildings.length,
      goods: compiled.goods.length,
      resources: compiled.resources.length,
      professions: compiled.professions.length,
      plans: compiled.plans.length,
      needs: compiled.needs.length
    }
  };
  return compiled;
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log('用法: node export_model.js [--repo-root PATH] [--output FILE] [--stdout]');
    return;
  }
  const repoRoot = path.resolve(args.repoRoot || path.join(__dirname, '..', '..'));
  const compiled = compile(repoRoot);
  const json = JSON.stringify(compiled, null, 2) + '\n';
  if (args.stdout) process.stdout.write(json);
  if (args.output) {
    const output = path.resolve(args.output);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, json, 'utf8');
    console.error(JSON.stringify({ output, ...compiled.source.entity_counts }));
  }
  if (!args.stdout && !args.output) process.stdout.write(json);
}

if (require.main === module) main();
module.exports = { compile, parseArgs };

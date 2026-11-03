// Syntax parsing only. Apple SDK availability and Swift type checking require Xcode.
const { Parser, Language } = require('web-tree-sitter');
const fs = require('node:fs');
const path = require('node:path');

async function main() {
  await Parser.init();
  const language = await Language.load(require.resolve('tree-sitter-wasms/out/tree-sitter-swift.wasm'));
  const parser = new Parser();
  parser.setLanguage(language);
  const invalid = parser.parse('func broken( {');
  if (!invalid.rootNode.hasError) throw new Error('Parser self-check failed to reject invalid Swift');
  invalid.delete();
  const root = path.resolve(__dirname, '../..');
  const project = require('xcode').project(path.join(root, 'PaperStudio.xcodeproj/project.pbxproj'));
  project.parseSync();
  const objects = project.hash.project.objects;
  const app = Object.values(objects).find(object => object.isa === 'PBXNativeTarget' && object.name === 'PaperStudio');
  if (!app) throw new Error('Application target missing');
  const phases = app.buildPhases.map(id => objects[id]);
  if (phases[0].isa !== 'PBXShellScriptBuildPhase' || !phases[0].shellScript.includes('build-mupdf-xcode.sh')) {
    throw new Error('MuPDF build must precede compilation and linking');
  }
  const appSources = phases.find(phase => phase.isa === 'PBXSourcesBuildPhase').files.map(id => objects[objects[id].fileRef].path);
  if (!appSources.includes('Native/PSPDFEngine.c')) throw new Error('Production C bridge missing from application sources');
  const resources = phases.find(phase => phase.isa === 'PBXResourcesBuildPhase').files.map(id => objects[objects[id].fileRef].path);
  if (!resources.includes('PaperStudio/Legal')) throw new Error('License resources missing from bundle');
  console.log('Xcode project parsed; C bridge, build ordering and legal resources verified.');
  let failures = 0;
  let count = 0;
  for (const folder of ['PaperStudio', 'PaperStudioTests']) {
    for (const name of fs.readdirSync(path.join(root, folder)).filter(name => name.endsWith('.swift'))) {
      count++;
      const source = fs.readFileSync(path.join(root, folder, name), 'utf8');
      const tree = parser.parse(source);
      if (tree.rootNode.hasError) {
        failures++;
        function visit(node) {
          if (node.type === 'ERROR' || node.isMissing) {
            console.error(`${folder}/${name}:${node.startPosition.row + 1}:${node.startPosition.column + 1}: ${node.type} ${node.text.slice(0, 100)}`);
          }
          for (const child of node.children) visit(child);
        }
        visit(tree.rootNode);
      }
      tree.delete();
    }
  }
  parser.delete();
  if (!count) throw new Error('No Swift source files found');
  console.log(`${count} Swift files parsed; ${failures} syntax failures. Apple SDK type checking and XCTest have NOT run.`);
  process.exitCode = failures ? 1 : 0;
}
main().catch(error => { console.error(error); process.exitCode = 1; });

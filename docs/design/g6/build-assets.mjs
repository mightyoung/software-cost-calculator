import {readFile,writeFile,mkdir,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const here=path.dirname(fileURLToPath(import.meta.url));
const target=path.resolve(here,'../../../apps/supplier_app/assets/ontology_graph');
const read=name=>readFile(path.join(here,name),'utf8');
const cleanModule=source=>source.replace(/^import .*;\n/gm,'').replace(/^export /gm,'');
const safeInline=source=>source.replace(/<\/script/gi,'<\\/script');
const catalog=JSON.parse(await read('../icons/catalog.json'));
const css=await read('style.css');
const code=(await Promise.all(['graph-model.mjs','host-model.mjs','app.mjs'].map(read))).map(cleanModule).join('\n');
const html=(await read('index.html'))
  .replace('<title>数据关系 · G6 交互小样</title>','<title>数据中心 · 对象与关系</title>')
  .replace('<link rel="stylesheet" href="style.css">',`<style>${css}</style>`)
  .replace('<script src="node_modules/@antv/g6/dist/g6.min.js"></script><script type="module" src="app.mjs"></script>',
    `<script src="g6.min.js"></script><script>window.ONTOLOGY_ASSETS=${safeInline(JSON.stringify({catalog}))};\n(()=>{\n${safeInline(code)}\n})();</script>`);
// Ship notices for every installed production dependency; do not drop transitive attribution.
const notices=['Offline ontology graph. Bundled @antv/g6 5.1.1.\nGenerated from the pinned package-lock.json.\n'];
const packageDirs=[];
for(const entry of (await readdir(path.join(here,'node_modules'),{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))){
  if(!entry.isDirectory() || entry.name.startsWith('.'))continue;
  if(entry.name.startsWith('@'))for(const sub of (await readdir(path.join(here,'node_modules',entry.name))).sort())packageDirs.push(`${entry.name}/${sub}`);
  else packageDirs.push(entry.name);
}
for(const dir of packageDirs){
  const root=path.join(here,'node_modules',dir);
  const pkg=JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
  const licenses=(await readdir(root)).filter(f=>/^(licen[cs]e|notice|copyright)(\.|$)/i.test(f)).sort();
  notices.push(`\n=== ${pkg.name}@${pkg.version} (${pkg.license || 'see package metadata'}) ===\n`);
  for(const file of licenses)notices.push(`${file}\n${await readFile(path.join(root,file),'utf8')}\n`);
}
const outputs={'index.html':html,'g6.min.js':await read('node_modules/@antv/g6/dist/g6.min.js'),'THIRD_PARTY_NOTICES.txt':notices.join('\n')};
const check=process.argv.includes('--check');
if(!check)await mkdir(target,{recursive:true});
for(const [name,content] of Object.entries(outputs)){
  const dest=path.join(target,name);
  if(check){if(await readFile(dest,'utf8')!==content)throw new Error(`Stale packaged asset: ${name}`);}
  else await writeFile(dest,content);
}
console.log(`${check?'Verified':'Built'} ${Object.keys(outputs).length} deterministic offline assets`);

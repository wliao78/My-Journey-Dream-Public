import fs from "node:fs";
import path from "node:path";
import {execFileSync} from "node:child_process";
const repo = path.resolve(process.argv[2] ?? ".");
const dirs = ["MyJourneyPlan", "TravelCompanion", "AITourGuide", "MyJourneyDream"];
const dir = dirs.find(d => fs.existsSync(path.join(repo, d, "en.lproj")));
if (!dir) throw new Error("App source directory not found");
const read = language => JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", path.join(repo, dir, language + ".lproj", "Localizable.strings")], {encoding:"utf8"}));
const en = read("en"), zh = read("zh-Hans"), problems=[];
const placeholders = s => (s.match(/%(?:[0-9]+\$)?(?:lld|ld|d|@|(?:\.[0-9]+)?f)/g) ?? []).map(s=>s.replace(/%[0-9]+\$/,"%")).sort().join("|");
for(const [key,value] of Object.entries(en)) {
 if(/[\u3400-\u9fff]/u.test(value)) problems.push("Chinese in English translation: "+key);
 if(!(key in zh)) problems.push("Missing Chinese translation: "+key);
 if(placeholders(key)!==placeholders(value)) problems.push("Format placeholders differ: "+key);
}
for(const key of Object.keys(zh)) if(!(key in en)) problems.push("Missing English translation: "+key);
function walk(folder) {return fs.readdirSync(folder,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(path.join(folder,e.name)):e.name.endsWith(".swift")?[path.join(folder,e.name)]:[])}
const files = walk(path.join(repo, dir));
const core = path.join(repo, "TravelCore", "Sources");
if (fs.existsSync(core)) files.push(...walk(core));
for(const file of files) {
 const source=fs.readFileSync(file,"utf8");
 for(const match of source.matchAll(/(?:String\(localized:\s*|NSLocalizedString\(\s*)("(?:[^"\\]|\\.)*")/g)) {
  let key;try {key=JSON.parse(match[1])}catch{continue}
  if(/[\u3400-\u9fff]/u.test(key) && !key.includes("\\(") && !(key in en)) problems.push("Missing UI key "+path.relative(repo,file)+": "+key);
 }
}
if(problems.length){console.error(problems.join("\n"));process.exit(1)}
console.log("PASS: "+Object.keys(en).length+" bilingual keys; no Chinese English values, missing keys or format mismatches.");

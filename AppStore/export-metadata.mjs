import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(base, 'metadata.md'), 'utf8');
const locales = ['zh-Hans', 'en-US'];
const failures = [];
const mappings = {
  Name: ['name', 30], Subtitle: ['subtitle', 30],
  'Promotional text': ['promotional_text', 170], Keywords: ['keywords', 100]
};
const results = [];
for (const locale of locales) {
  const section = source.split(`## ${locale}\n`)[1]?.split('\n## ')[0];
  if (!section) throw new Error(`Missing locale: ${locale}`);
  const values = {};
  for (const [label, [field, limit]] of Object.entries(mappings)) {
    const value = section.split('\n').find(line => line.startsWith(`${label}: `))?.slice(label.length + 2);
    if (!value) throw new Error(`Missing ${locale} ${label}`);
    const size = field === 'keywords' ? Buffer.byteLength(value, 'utf8') : Array.from(value).length;
    if (size > limit) failures.push(`${locale} ${field}: ${size} > ${limit}`);
    values[field] = value;
  }
  values.description = section.split('Description:\n')[1]?.trim();
  if (!values.description || Array.from(values.description).length > 4000) {
    failures.push(`${locale} description missing or exceeds 4000 characters`);
  }
  values.support_url = 'https://wliao78.github.io/My-Journey-Support/#support';
  values.privacy_url = `https://wliao78.github.io/My-Journey-Support/#privacy-${locale === 'zh-Hans' ? 'zh' : 'en'}`;
  results.push({ locale, values });
}
if (failures.length) throw new Error(failures.join('\n'));
for (const { locale, values } of results) {
  const destination = join(base, 'metadata', locale);
  mkdirSync(destination, { recursive: true });
  for (const [field, value] of Object.entries(values)) {
    writeFileSync(join(destination, `${field}.txt`), `${value}\n`);
  }
  console.log(`${locale}: validated ${Object.keys(values).length} metadata fields`);
}

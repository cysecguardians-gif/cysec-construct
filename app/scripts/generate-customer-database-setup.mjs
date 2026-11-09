import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationDir = path.resolve(appDir, '..', 'supabase', 'migrations');
const outputDir = path.join(appDir, 'src', 'generated');
const outputFile = path.join(outputDir, 'customerDatabaseSetup.json');

const migrationFiles = (await fs.readdir(migrationDir))
  .filter((file) => /^\d+.*\.sql$/i.test(file))
  .sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));

const sections = [];
for (const file of migrationFiles) {
  const source = await fs.readFile(path.join(migrationDir, file), 'utf8');
  sections.push(`-- CySec Construct database setup\n-- Internal migration: ${file}\n-- This file is bundled into the desktop application for customer database initialization.\n\n${source.trim()}`);
}

const sql = [
  '-- CySec Construct — Customer Database Setup',
  '-- Generated automatically from the version-controlled migrations during the application build.',
  '-- Run this complete script once in the customer-owned Supabase SQL Editor.',
  '-- Do not place a service-role key or database password in the desktop application.',
  '',
  ...sections,
  '',
  '-- End of CySec Construct database setup',
  '',
].join('\n\n');

await fs.mkdir(outputDir, { recursive: true });
await fs.writeFile(outputFile, `${JSON.stringify(sql, null, 2)}\n`, 'utf8');

const upgradeFile = '0030_client_company_legacy_columns.sql';
const upgradeSource = await fs.readFile(path.join(migrationDir, upgradeFile), 'utf8');
const upgradeSql = [
  '-- CySec Construct — Customer Database Upgrade',
  '-- Apply this migration when upgrading an existing schema v29 database to v30.',
  '',
  `-- Internal migration: ${upgradeFile}`,
  upgradeSource.trim(),
  '',
].join('\n\n');
await fs.writeFile(path.join(outputDir, 'customerDatabaseUpgrade.json'), `${JSON.stringify(upgradeSql, null, 2)}\n`, 'utf8');
console.log(`Generated customer database setup SQL: ${outputFile}`);

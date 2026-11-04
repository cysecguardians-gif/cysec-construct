import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationDir = path.resolve(appDir, '..', 'supabase', 'migrations');
const outputDir = path.join(appDir, 'src', 'generated');
const outputFile = path.join(outputDir, 'customerDatabaseSetup.json');
const upgradeOutputFile = path.join(outputDir, 'constructionWorkflowUpgrade.json');
const settlementUpgradeOutputFile = path.join(outputDir, 'contractorSettlementUpgrade.json');

const migrationFiles = [
  '0001_initial_schema.sql',
  '0002_transactional_operations.sql',
  '0003_bootstrap_and_connection.sql',
  '0004_customer_operations.sql',
  '0005_invoice_security_and_helpers.sql',
  '0006_material_stock_threshold.sql',
  '0007_access_control_and_audit.sql',
  '0008_login_session_tracking.sql',
  '0009_app_status_security.sql',
  '0010_staff_membership_management.sql',
  '0011_first_admin_lock_and_imports.sql',
  '0012_import_integrity.sql',
  '0013_construction_workflow_foundation.sql',
  '0014_construction_transactional_operations.sql',
  '0015_client_contract_finance.sql',
  '0016_allow_replacement_cancelled_settlements.sql',
];

const upgradeMigrationFiles = migrationFiles.filter(file => /^001[3-5]_/.test(file));
const sections = [];
const upgradeSections = [];
for (const file of migrationFiles) {
  const source = await fs.readFile(path.join(migrationDir, file), 'utf8');
  const section = `-- Material Management System database setup
-- Internal migration: ${file}
-- This file is bundled into the desktop application for customer database initialization.

${source.trim()}`;
  sections.push(section);
  if (upgradeMigrationFiles.includes(file)) upgradeSections.push(section);
}

const sql = [
  '-- Material Management System — Customer Database Setup',
  '-- Generated automatically from the version-controlled migrations during the application build.',
  '-- Run this complete script once in the customer-owned Supabase SQL Editor.',
  '-- Do not place a service-role key or database password in the desktop application.',
  '',
  ...sections,
  '',
  '-- End of Material Management System database setup',
  '',
].join('\n\n');

await fs.mkdir(outputDir, { recursive: true });
await fs.writeFile(outputFile, `${JSON.stringify(sql, null, 2)}\n`, 'utf8');
const upgradeSql = [
  '-- Material Management System — Construction Workflow Upgrade',
  '-- For existing databases at schema version 12. Run migrations 0013, 0014 and 0015 in order.',
  '-- Do not rerun migrations 0001–0012 on an existing customer database.',
  '',
  ...upgradeSections,
  '',
  '-- End of construction workflow upgrade',
  '',
].join('\n\n');

await fs.writeFile(upgradeOutputFile, `${JSON.stringify(upgradeSql, null, 2)}\n`, 'utf8');

const settlementMigration = '0016_allow_replacement_cancelled_settlements.sql';
const settlementSource = await fs.readFile(path.join(migrationDir, settlementMigration), 'utf8');
const settlementUpgradeSql = [
  '-- Material Management System — Contractor Settlement Upgrade',
  '-- For existing databases at schema version 15. Run migration 0016 only.',
  '-- Do not rerun migrations 0013, 0014 or 0015, and do not rerun the original database setup SQL.',
  '',
  `-- Internal migration: ${settlementMigration}`,
  settlementSource.trim(),
  '',
  '-- End of contractor settlement upgrade',
  '',
].join('\n\n');

await fs.writeFile(settlementUpgradeOutputFile, `${JSON.stringify(settlementUpgradeSql, null, 2)}\n`, 'utf8');
console.log(`Generated customer database setup SQL: ${outputFile}`);
console.log(`Generated construction workflow upgrade SQL: ${upgradeOutputFile}`);
console.log(`Generated contractor settlement upgrade SQL: ${settlementUpgradeOutputFile}`);

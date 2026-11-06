import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationDir = path.resolve(appDir, '..', 'supabase', 'migrations');
const outputDir = path.join(appDir, 'src', 'generated');
const outputFile = path.join(outputDir, 'customerDatabaseSetup.json');

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
  '0013_construction_domain_foundation.sql',
  '0014_construction_transactional_operations.sql',
  '0015_construction_workflow_controls.sql',
  '0016_stock_import_and_zero_settlement.sql',
  '0017_historical_payment_import_idempotency.sql',
  '0018_historical_invoice_rounding_validation.sql',
  '0019_contractor_recovery_collection.sql',
  '0020_financial_reference_deduplication.sql',
  '0021_contractor_advance_settlement_locking.sql',
  '0022_contractor_recovery_completion_gate.sql',
  '0023_financial_reference_update_guard.sql',
  '0024_recovery_after_payable_paid.sql',
  '0025_zero_payable_recovery_closure.sql',
  '0026_material_purchase_status_compatibility.sql',
  '0027_idempotent_material_import.sql',
  '0028_contract_completion_date_compatibility.sql',
  '0029_client_customer_unification.sql',
  '0030_client_company_legacy_columns.sql',
];

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

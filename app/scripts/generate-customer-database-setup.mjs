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
];

const sections = [];
for (const file of migrationFiles) {
  const source = await fs.readFile(path.join(migrationDir, file), 'utf8');
  sections.push(`-- Material Management System database setup\n-- Internal migration: ${file}\n-- This file is bundled into the desktop application for customer database initialization.\n\n${source.trim()}`);
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
console.log(`Generated customer database setup SQL: ${outputFile}`);

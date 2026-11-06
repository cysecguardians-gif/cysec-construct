# CySec Construct — Product Overview

## Purpose

CySec Construct is a reusable construction business application for companies that buy, store, sell, and distribute physical materials or goods. It is not limited to construction materials.

## Initial modules

1. Dashboard
2. User authentication and session tracking
3. User and role administration
4. Material catalogue and categories
5. Units of measure
6. Stock balance and stock movement history
7. Customer management
8. Invoice creation and invoice history
9. Payment recording and customer outstanding balances
10. Reports and audit history
11. Company profile and application configuration

## Core workflows

### Materials and stock

Users maintain a catalogue of materials with identifiers, names, categories, units, purchase cost, selling price, reorder thresholds, and active status.

Every stock change must create a stock movement record. Current stock must not be changed through an untraceable overwrite. Purchases/receipts, invoice issues, returns, and adjustments should be represented as explicit movement types.

### Customers

Users can create and update customer profiles, including contact, billing, tax, and address information. A customer view should summarize invoice totals, payments received, and outstanding balances.

### Invoices

Users select a customer and add material line items. The application calculates line totals, subtotal, discount, and final total. The database must validate and commit invoice creation and stock deduction atomically.

Invoice line items must preserve the description, unit, and unit price used at the time of sale so later catalogue edits do not alter historical invoices.

### Payments

Support multiple payments against one invoice. Invoice balance and status are derived from the invoice total and valid recorded payments, not maintained as independent editable facts.

Expected statuses include Draft, Issued, Partially Paid, Paid, and Cancelled. Exact status transitions will be specified in the data model.

### Employee sessions

Record sign-in and sign-out/session events. Session duration is calculated from recorded timestamps. Session tracking should be robust to app crashes, computer shutdowns, and network loss; a missing sign-out must not be mistaken for a completed session.

## Initial deployment assumptions

- Initial client: one business using three Windows PCs.
- Each customer deployment has its own Supabase project.
- The product source and SQL migrations remain in the vendor's private GitHub repository.
- Initial database provisioning is documented and manually applied in the customer's Supabase SQL Editor.
- The initial deployment is online-first; offline writes and conflict reconciliation are out of scope until explicitly designed.

## Product boundaries

The first release focuses on stock, customers, invoices, payments, user access, and essential reports. Advanced accounting, GST return filing, purchase-order workflows, supplier management, barcode hardware, multi-warehouse transfers, and payment-gateway integration are not assumed to be in the initial release.

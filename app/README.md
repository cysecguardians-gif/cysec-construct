# Desktop Application

The desktop client is a Tauri v2 + React + TypeScript + Vite application.

## Structure

- `src/` — React application
- `src/lib/config.ts` — customer-owned Supabase connection settings
- `src/lib/supabase.ts` — Supabase client factory
- `src/pages/MaterialsPage.tsx` — materials catalog and stock operations
- `src/App.tsx` — first-run, authentication, organization setup, and application shell
- `src/styles.css` — application styling

## Local development

From this directory:

```bash
npm install
npm run dev
```

For the Tauri desktop window, install the Rust/Tauri prerequisites and run:

```bash
npm install
npm run tauri dev
```

## Connection model

Each customer supplies their own Supabase Project URL and publishable/anon key during first-run setup. The values are stored locally on that Windows machine. The desktop client must never contain a service-role key or database password.

The first-run flow is:

1. Configure the customer's Supabase project.
2. Sign in with Supabase Auth.
3. Check the application schema/status.
4. If the signed-in user has no organization, create the first organization through `bootstrap_organization()` and initialize standard units.
5. Enter the application shell.

## Current business module

The first operational module is **Materials & Stock**. It supports:

- Material name and description.
- HSN/SAC code.
- GST rate.
- Selling price in INR.
- Unit selection.
- Optional category.
- Opening stock.
- Material activation/deactivation.
- Search.
- Positive or negative stock adjustments.
- Stock changes through the transactional `adjust_stock()` database function.

Stock is not silently overwritten when an adjustment is made; the database records a stock movement for the change.

The next business modules will build on this foundation: customers, invoices, payments, and reporting.

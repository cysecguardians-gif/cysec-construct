# Desktop Application

The desktop client is a Tauri v2 + React + TypeScript + Vite application.

## Structure

- `src/` — React application
- `src/lib/config.ts` — customer-owned Supabase connection settings
- `src/lib/supabase.ts` — Supabase client factory
- `src/App.tsx` — first-run, authentication and application shell
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
4. If the signed-in user has no organization, create the first organization through `bootstrap_organization()`.
5. Enter the application shell.

Business modules will be added incrementally after this foundation.

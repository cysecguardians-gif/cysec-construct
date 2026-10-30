# Tauri Desktop Shell

The desktop shell uses Tauri v2 and Rust. The React frontend is built from `app/` and loaded by the Tauri window.

## Development

From `app/`:

```bash
npm install
npm run tauri dev
```

The Tauri configuration expects the Vite development server on port `1420` and the production frontend at `app/dist`.

## Security boundary

The desktop layer must not contain service-role credentials, database passwords, or other privileged Supabase secrets. Customer Supabase URL and publishable/anon key are supplied at first run by the customer.

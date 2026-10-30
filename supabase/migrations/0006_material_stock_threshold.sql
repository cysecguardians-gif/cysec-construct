-- Material Management System
-- Stock threshold support
-- Apply manually in each customer's Supabase SQL Editor after 0005.

begin;

alter table public.materials
  add column if not exists minimum_stock_quantity numeric(14,3) not null default 0
  check (minimum_stock_quantity >= 0);

commit;

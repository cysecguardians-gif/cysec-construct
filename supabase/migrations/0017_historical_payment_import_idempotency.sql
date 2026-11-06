-- CySec Construct
-- Prevent accidental re-import of an identical historical payment batch.
-- Payment rows remain separate transactions; the fingerprint only makes a
-- repeated identical upload idempotently reject instead of duplicating money.

begin;

create table if not exists public.historical_import_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  import_type text not null check (import_type = 'payments'),
  payload_fingerprint text not null check (length(payload_fingerprint) = 32),
  imported_count integer not null default 0 check (imported_count >= 0),
  imported_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, import_type, payload_fingerprint)
);

alter table public.historical_import_batches enable row level security;
revoke all on public.historical_import_batches from anon, authenticated;

create or replace function public.import_historical_payments(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_invoice uuid;
  v_number text;
  v_amount numeric;
  v_amount_paise bigint;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_method public.payment_method;
  v_existing bigint;
  v_total bigint;
  v_fingerprint text;
  v_batch_id uuid;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows_must_be_array';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'payment_import_rows_required';
  end if;

  -- jsonb canonicalizes object key order; array order remains significant.
  -- This fingerprint is an idempotency key, not an authentication mechanism.
  v_fingerprint := md5(p_rows::text);
  insert into public.historical_import_batches(
    organization_id, import_type, payload_fingerprint, imported_by
  ) values (
    p_organization_id, 'payments', v_fingerprint, v_user
  )
  on conflict (organization_id, import_type, payload_fingerprint) do nothing
  returning id into v_batch_id;

  if v_batch_id is null then
    raise exception 'duplicate_payment_import_batch';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'invalid_payment_import_row';
    end if;

    v_number := nullif(trim(v_row->>'invoice_number'), '');
    v_amount := nullif(trim(v_row->>'amount'), '')::numeric;

    if v_number is null or v_amount is null
       or v_amount::text in ('NaN', 'Infinity', '-Infinity')
       or v_amount <= 0 then
      raise exception 'invalid_payment_import_row';
    end if;

    if v_amount > 92233720368547758.07 then
      raise exception 'payment_amount_exceeds_supported_range';
    end if;

    v_amount_paise := round(v_amount * 100);
    if v_amount_paise <= 0 then
      raise exception 'payment_amount_below_one_paise';
    end if;

    select id, grand_total_paise
      into v_invoice, v_total
    from public.invoices
    where organization_id = p_organization_id
      and invoice_number = v_number
    for update;

    if v_invoice is null then
      raise exception 'invoice_not_found_for_payment_import: %', v_number;
    end if;

    select coalesce(sum(amount_paise), 0)::bigint
      into v_existing
    from public.payments
    where organization_id = p_organization_id
      and invoice_id = v_invoice;

    if v_existing > v_total - v_amount_paise then
      raise exception 'payment_import_exceeds_invoice_balance: %', v_number;
    end if;

    v_method := case lower(coalesce(nullif(trim(v_row->>'payment_method'), ''), 'other'))
      when 'cash' then 'cash'::public.payment_method
      when 'upi' then 'upi'::public.payment_method
      when 'bank_transfer' then 'bank_transfer'::public.payment_method
      when 'bank transfer' then 'bank_transfer'::public.payment_method
      when 'cheque' then 'cheque'::public.payment_method
      when 'card' then 'card'::public.payment_method
      else 'other'::public.payment_method
    end;

    insert into public.payments(
      organization_id, invoice_id, amount_paise, payment_date,
      payment_method, reference_number, notes, created_by
    ) values (
      p_organization_id, v_invoice, v_amount_paise,
      coalesce(nullif(v_row->>'payment_date', '')::date, current_date),
      v_method, nullif(trim(v_row->>'reference_number'), ''),
      nullif(trim(v_row->>'notes'), ''), v_user
    );
    v_count := v_count + 1;
  end loop;

  update public.historical_import_batches
  set imported_count = v_count
  where id = v_batch_id;

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, details
  ) values (
    p_organization_id, v_user, 'historical_import', 'payments',
    jsonb_build_object(
      'count', v_count,
      'batch_id', v_batch_id,
      'payload_fingerprint', v_fingerprint
    )
  );

  return jsonb_build_object(
    'imported', v_count,
    'batch_id', v_batch_id,
    'duplicate_protection', 'enabled'
  );
end;
$$;

grant execute on function public.import_historical_payments(uuid, jsonb) to authenticated;
revoke execute on function public.import_historical_payments(uuid, jsonb) from anon;

insert into public.app_schema_version(version) values (17)
on conflict (version) do nothing;

commit;

-- Material Management System
-- Transactional business operations
-- Apply after 0001_initial_schema.sql.
-- These functions are the safe write path for money/stock operations from the desktop app.

begin;

-- ============================================================
-- Helpers
-- ============================================================

create or replace function public.current_financial_year(target_date date default current_date)
returns text
language sql
immutable
as $$
  select case
    when extract(month from target_date) >= 4
      then extract(year from target_date)::int::text || '-' || lpad(((extract(year from target_date)::int + 1) % 100)::text, 2, '0')
    else (extract(year from target_date)::int - 1)::text || '-' || lpad((extract(year from target_date)::int % 100)::text, 2, '0')
  end;
$$;

create or replace function public.require_org_member(target_org uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_org_member(target_org) then
    raise exception 'Not authorized for this organization' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.require_org_admin(target_org uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_org_admin(target_org) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
end;
$$;

-- ============================================================
-- Invoice number generation
-- Indian financial year: Apr-Mar, e.g. 2026-27.
-- The row lock guarantees unique sequential numbers under concurrency.
-- ============================================================

create or replace function public.next_invoice_number(target_org uuid, target_date date default current_date)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  fy text;
  prefix text;
  number_value bigint;
begin
  perform public.require_org_member(target_org);

  select invoice_prefix into prefix
  from public.organizations
  where id = target_org;

  if prefix is null then
    raise exception 'Organization not found';
  end if;

  fy := public.current_financial_year(target_date);

  insert into public.invoice_sequences(organization_id, financial_year, next_number)
  values (target_org, fy, 2)
  on conflict (organization_id, financial_year)
  do update set next_number = public.invoice_sequences.next_number + 1
  returning next_number - 1 into number_value;

  return prefix || '/' || fy || '/' || lpad(number_value::text, 4, '0');
end;
$$;

-- ============================================================
-- Issue invoice + deduct stock atomically
-- p_items format:
-- [
--   {
--     "material_id": "uuid",
--     "quantity": 2.000,
--     "unit_price_paise": 50000,
--     "discount_amount_paise": 0
--   }
-- ]
--
-- Discount is optional. GST is optional. When GST is enabled,
-- intra-state sales use CGST+SGST and inter-state sales use IGST.
-- ============================================================

create or replace function public.issue_invoice(
  p_organization_id uuid,
  p_customer_id uuid,
  p_invoice_date date default current_date,
  p_items jsonb default '[]'::jsonb,
  p_discount_enabled boolean default false,
  p_discount_type text default null,
  p_discount_value numeric default null,
  p_gst_enabled boolean default false,
  p_place_of_supply_state text default null,
  p_place_of_supply_state_code text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice_id uuid;
  v_invoice_number text;
  v_org_state_code text;
  v_subtotal bigint := 0;
  v_discount bigint := 0;
  v_taxable bigint := 0;
  v_cgst bigint := 0;
  v_sgst bigint := 0;
  v_igst bigint := 0;
  v_total_gst bigint := 0;
  v_grand_total bigint := 0;
  v_item jsonb;
  v_material public.materials%rowtype;
  v_customer public.customers%rowtype;
  v_qty numeric(14,3);
  v_unit_price bigint;
  v_item_discount bigint;
  v_line_subtotal bigint;
  v_line_taxable bigint;
  v_rate numeric(5,2);
  v_line_cgst bigint;
  v_line_sgst bigint;
  v_line_igst bigint;
  v_line_total bigint;
  v_same_state boolean;
begin
  perform public.require_org_member(p_organization_id);

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one invoice item is required';
  end if;

  if p_discount_enabled then
    if p_discount_type not in ('percentage', 'fixed') then
      raise exception 'Discount type must be percentage or fixed';
    end if;
    if p_discount_value is null or p_discount_value < 0 then
      raise exception 'Discount value must be zero or greater';
    end if;
    if p_discount_type = 'percentage' and p_discount_value > 100 then
      raise exception 'Percentage discount cannot exceed 100';
    end if;
  elsif p_discount_type is not null or coalesce(p_discount_value, 0) <> 0 then
    raise exception 'Discount values supplied while discount is disabled';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id
    and organization_id = p_organization_id
    and is_active = true;

  if not found then
    raise exception 'Customer not found or inactive';
  end if;

  select state_code into v_org_state_code
  from public.organizations
  where id = p_organization_id;

  if v_org_state_code is null then
    raise exception 'Organization state code is required';
  end if;

  if p_gst_enabled and nullif(trim(coalesce(p_place_of_supply_state_code, '')), '') is null then
    raise exception 'Place of supply state code is required when GST is enabled';
  end if;

  v_same_state := p_place_of_supply_state_code = v_org_state_code;

  -- Lock each material row while validating and calculating stock.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    select * into v_material
    from public.materials
    where id = (v_item->>'material_id')::uuid
      and organization_id = p_organization_id
      and is_active = true
    for update;

    if not found then
      raise exception 'Material not found or inactive: %', v_item->>'material_id';
    end if;

    v_qty := (v_item->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantity must be greater than zero';
    end if;

    v_unit_price := coalesce((v_item->>'unit_price_paise')::bigint, v_material.selling_price_paise);
    if v_unit_price < 0 then
      raise exception 'Unit price cannot be negative';
    end if;

    v_item_discount := coalesce((v_item->>'discount_amount_paise')::bigint, 0);
    if v_item_discount < 0 then
      raise exception 'Item discount cannot be negative';
    end if;

    v_line_subtotal := round(v_qty * v_unit_price);
    if v_item_discount > v_line_subtotal then
      raise exception 'Item discount cannot exceed item value';
    end if;

    v_line_taxable := v_line_subtotal - v_item_discount;
    v_rate := case when p_gst_enabled then v_material.gst_rate else 0 end;

    if p_gst_enabled then
      if v_same_state then
        v_line_cgst := round(v_line_taxable * v_rate / 200);
        v_line_sgst := round(v_line_taxable * v_rate / 200);
        v_line_igst := 0;
      else
        v_line_cgst := 0;
        v_line_sgst := 0;
        v_line_igst := round(v_line_taxable * v_rate / 100);
      end if;
    else
      v_line_cgst := 0;
      v_line_sgst := 0;
      v_line_igst := 0;
    end if;

    v_line_total := v_line_taxable + v_line_cgst + v_line_sgst + v_line_igst;

    v_subtotal := v_subtotal + v_line_subtotal;
    v_taxable := v_taxable + v_line_taxable;
    v_cgst := v_cgst + v_line_cgst;
    v_sgst := v_sgst + v_line_sgst;
    v_igst := v_igst + v_line_igst;
  end loop;

  if p_discount_enabled then
    if p_discount_type = 'percentage' then
      v_discount := round(v_subtotal * p_discount_value / 100);
    else
      v_discount := round(p_discount_value);
    end if;
    if v_discount > v_subtotal then
      v_discount := v_subtotal;
    end if;
  end if;

  -- The item-level discounts are authoritative for taxable value.
  -- Invoice-level discount is applied proportionally across the taxable base.
  -- For the first release, invoice-level discount is therefore added to the
  -- aggregate and GST is recalculated on the resulting taxable value.
  if p_discount_enabled then
    v_taxable := greatest(v_taxable - v_discount, 0);
    if p_gst_enabled then
      -- Reset all tax aggregates before recalculating either intra-state or
      -- inter-state GST on the discounted taxable base.
      v_cgst := 0; v_sgst := 0; v_igst := 0;
      if v_same_state then
        for v_item in select value from jsonb_array_elements(p_items) loop
          select * into v_material from public.materials where id = (v_item->>'material_id')::uuid and organization_id = p_organization_id;
          v_qty := (v_item->>'quantity')::numeric;
          v_unit_price := coalesce((v_item->>'unit_price_paise')::bigint, v_material.selling_price_paise);
          v_item_discount := coalesce((v_item->>'discount_amount_paise')::bigint, 0);
          v_line_subtotal := round(v_qty * v_unit_price);
          v_line_taxable := greatest(v_line_subtotal - v_item_discount, 0);
          -- Apply the invoice discount proportionally to each item's taxable base.
          if v_taxable + v_discount > 0 then
            v_line_taxable := round(v_line_taxable * v_taxable / (v_taxable + v_discount));
          end if;
          if v_same_state then
            v_cgst := v_cgst + round(v_line_taxable * v_material.gst_rate / 200);
            v_sgst := v_sgst + round(v_line_taxable * v_material.gst_rate / 200);
          else
            v_igst := v_igst + round(v_line_taxable * v_material.gst_rate / 100);
          end if;
        end loop;
      end if;
    end if;
  end if;

  v_total_gst := v_cgst + v_sgst + v_igst;
  v_grand_total := v_taxable + v_total_gst;

  v_invoice_number := public.next_invoice_number(p_organization_id, p_invoice_date);

  insert into public.invoices (
    organization_id, customer_id, invoice_number, invoice_date,
    place_of_supply_state, place_of_supply_state_code, status,
    discount_enabled, discount_type, discount_value, discount_amount_paise,
    gst_enabled, cgst_amount_paise, sgst_amount_paise, igst_amount_paise,
    subtotal_paise, taxable_value_paise, total_gst_paise, grand_total_paise,
    notes, created_by
  ) values (
    p_organization_id, p_customer_id, v_invoice_number, p_invoice_date,
    p_place_of_supply_state, p_place_of_supply_state_code, 'issued',
    p_discount_enabled, case when p_discount_enabled then p_discount_type end,
    case when p_discount_enabled then p_discount_value else null end, v_discount,
    p_gst_enabled, v_cgst, v_sgst, v_igst,
    v_subtotal, v_taxable, v_total_gst, v_grand_total,
    p_notes, auth.uid()
  ) returning id into v_invoice_id;

  -- Insert item snapshots and deduct stock in the same transaction.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    select * into v_material
    from public.materials
    where id = (v_item->>'material_id')::uuid
      and organization_id = p_organization_id
    for update;

    v_qty := (v_item->>'quantity')::numeric;
    v_unit_price := coalesce((v_item->>'unit_price_paise')::bigint, v_material.selling_price_paise);
    v_item_discount := coalesce((v_item->>'discount_amount_paise')::bigint, 0);
    v_line_subtotal := round(v_qty * v_unit_price);
    v_line_taxable := greatest(v_line_subtotal - v_item_discount, 0);
    v_rate := case when p_gst_enabled then v_material.gst_rate else 0 end;

    -- Recalculate item tax for its snapshot. Invoice-level discount is distributed proportionally.
    if p_discount_enabled and (v_taxable + v_discount) > 0 then
      v_line_taxable := round(v_line_taxable * v_taxable / (v_taxable + v_discount));
    end if;

    if p_gst_enabled then
      if v_same_state then
        v_line_cgst := round(v_line_taxable * v_rate / 200);
        v_line_sgst := round(v_line_taxable * v_rate / 200);
        v_line_igst := 0;
      else
        v_line_cgst := 0;
        v_line_sgst := 0;
        v_line_igst := round(v_line_taxable * v_rate / 100);
      end if;
    else
      v_line_cgst := 0; v_line_sgst := 0; v_line_igst := 0;
    end if;

    v_line_total := v_line_taxable + v_line_cgst + v_line_sgst + v_line_igst;

    if v_material.current_quantity < v_qty then
      raise exception 'Insufficient stock for material: % (available %, requested %)', v_material.name, v_material.current_quantity, v_qty;
    end if;

    update public.materials
    set current_quantity = current_quantity - v_qty,
        updated_at = now()
    where id = v_material.id;

    insert into public.stock_movements (
      organization_id, material_id, movement_type, quantity,
      reference_type, reference_id, notes, created_by
    ) values (
      p_organization_id, v_material.id, 'sale', v_qty,
      'invoice', v_invoice_id, 'Stock deducted for invoice ' || v_invoice_number, auth.uid()
    );

    insert into public.invoice_items (
      invoice_id, material_id, description, hsn_sac_code, unit_name,
      quantity, unit_price_paise, discount_amount_paise, taxable_value_paise,
      gst_rate, cgst_amount_paise, sgst_amount_paise, igst_amount_paise, line_total_paise
    ) values (
      v_invoice_id, v_material.id, v_material.name, v_material.hsn_sac_code,
      (select u.name from public.units u where u.id = v_material.unit_id),
      v_qty, v_unit_price, v_item_discount, v_line_taxable,
      v_rate, v_line_cgst, v_line_sgst, v_line_igst, v_line_total
    );
  end loop;

  insert into public.audit_log (
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'invoice_issued', 'invoice', v_invoice_id,
    jsonb_build_object('invoice_number', v_invoice_number, 'grand_total_paise', v_grand_total)
  );

  return v_invoice_id;
end;
$$;

-- ============================================================
-- Stock adjustment
-- Positive quantity adds stock; negative quantity removes stock.
-- ============================================================

create or replace function public.adjust_stock(
  p_organization_id uuid,
  p_material_id uuid,
  p_quantity numeric,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_material public.materials%rowtype;
  v_movement_id uuid;
  v_type public.stock_movement_type;
begin
  perform public.require_org_member(p_organization_id);

  if p_quantity = 0 then
    raise exception 'Stock adjustment cannot be zero';
  end if;

  select * into v_material
  from public.materials
  where id = p_material_id
    and organization_id = p_organization_id
    and is_active = true
  for update;

  if not found then
    raise exception 'Material not found or inactive';
  end if;

  if p_quantity < 0 and v_material.current_quantity < abs(p_quantity) then
    raise exception 'Insufficient stock for adjustment';
  end if;

  if p_quantity > 0 then
    v_type := 'adjustment_in';
  else
    v_type := 'adjustment_out';
  end if;

  update public.materials
  set current_quantity = current_quantity + p_quantity,
      updated_at = now()
  where id = p_material_id;

  insert into public.stock_movements (
    organization_id, material_id, movement_type, quantity, notes, created_by
  ) values (
    p_organization_id, p_material_id, v_type, abs(p_quantity), p_notes, auth.uid()
  ) returning id into v_movement_id;

  return v_movement_id;
end;
$$;

-- ============================================================
-- Record payment atomically and prevent overpayment.
-- ============================================================

create or replace function public.record_payment(
  p_organization_id uuid,
  p_invoice_id uuid,
  p_amount_paise bigint,
  p_payment_date date default current_date,
  p_payment_method public.payment_method default 'other',
  p_reference_number text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice public.invoices%rowtype;
  v_paid bigint;
  v_payment_id uuid;
begin
  perform public.require_org_member(p_organization_id);

  if p_amount_paise <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  select * into v_invoice
  from public.invoices
  where id = p_invoice_id
    and organization_id = p_organization_id
  for update;

  if not found then
    raise exception 'Invoice not found';
  end if;

  if v_invoice.status = 'cancelled' then
    raise exception 'Cannot pay a cancelled invoice';
  end if;

  select coalesce(sum(amount_paise), 0)::bigint into v_paid
  from public.payments
  where invoice_id = p_invoice_id;

  if v_paid + p_amount_paise > v_invoice.grand_total_paise then
    raise exception 'Payment exceeds invoice balance';
  end if;

  insert into public.payments (
    organization_id, invoice_id, amount_paise, payment_date,
    payment_method, reference_number, notes, created_by
  ) values (
    p_organization_id, p_invoice_id, p_amount_paise, p_payment_date,
    p_payment_method, p_reference_number, p_notes, auth.uid()
  ) returning id into v_payment_id;

  insert into public.audit_log (
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'payment_recorded', 'payment', v_payment_id,
    jsonb_build_object('invoice_id', p_invoice_id, 'amount_paise', p_amount_paise)
  );

  return v_payment_id;
end;
$$;

-- ============================================================
-- Cancel invoice
-- Does not delete financial history. Stock is restored in the same transaction.
-- ============================================================

create or replace function public.cancel_invoice(
  p_organization_id uuid,
  p_invoice_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice public.invoices%rowtype;
  v_item record;
  v_material public.materials%rowtype;
  v_paid bigint;
begin
  perform public.require_org_admin(p_organization_id);

  select * into v_invoice
  from public.invoices
  where id = p_invoice_id
    and organization_id = p_organization_id
  for update;

  if not found then
    raise exception 'Invoice not found';
  end if;

  if v_invoice.status = 'cancelled' then
    return;
  end if;

  select coalesce(sum(amount_paise), 0)::bigint into v_paid
  from public.payments
  where invoice_id = p_invoice_id;

  if v_paid > 0 then
    raise exception 'Paid invoices cannot be cancelled until payments are reversed';
  end if;

  for v_item in
    select material_id, quantity
    from public.invoice_items
    where invoice_id = p_invoice_id
      and material_id is not null
  loop
    select * into v_material
    from public.materials
    where id = v_item.material_id
      and organization_id = p_organization_id
    for update;

    if found then
      update public.materials
      set current_quantity = current_quantity + v_item.quantity,
          updated_at = now()
      where id = v_item.material_id;

      insert into public.stock_movements (
        organization_id, material_id, movement_type, quantity,
        reference_type, reference_id, notes, created_by
      ) values (
        p_organization_id, v_item.material_id, 'return_in', v_item.quantity,
        'invoice', p_invoice_id, coalesce(p_reason, 'Stock restored after invoice cancellation'), auth.uid()
      );
    end if;
  end loop;

  update public.invoices
  set status = 'cancelled',
      notes = case when p_reason is null then notes else coalesce(notes || E'\n', '') || 'Cancellation: ' || p_reason end,
      updated_at = now()
  where id = p_invoice_id;

  insert into public.audit_log (
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'invoice_cancelled', 'invoice', p_invoice_id,
    jsonb_build_object('reason', p_reason)
  );
end;
$$;

-- ============================================================
-- Grants
-- RPCs are callable by authenticated users, but each function
-- performs organization membership/role checks internally.
-- ============================================================

grant execute on function public.current_financial_year(date) to authenticated;
grant execute on function public.next_invoice_number(uuid, date) to authenticated;
grant execute on function public.issue_invoice(uuid, uuid, date, jsonb, boolean, text, numeric, boolean, text, text, text) to authenticated;
grant execute on function public.adjust_stock(uuid, uuid, numeric, text) to authenticated;
grant execute on function public.record_payment(uuid, uuid, bigint, date, public.payment_method, text, text) to authenticated;
grant execute on function public.cancel_invoice(uuid, uuid, text) to authenticated;

commit;

-- Correct inter-state GST after an invoice-level discount.
-- Reset all GST aggregates before the discounted per-line recalculation.
begin;

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

insert into public.app_schema_version(version)
values (36)
on conflict (version) do nothing;

commit;

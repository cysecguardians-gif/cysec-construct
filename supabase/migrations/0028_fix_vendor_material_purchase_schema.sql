-- Fix vendor material receiving for the live material_purchase_items schema.
-- The live schema uses description_snapshot, unit_cost_paise,
-- line_subtotal_paise and line_gst_paise (not the older snapshot/rate names).
-- Stock, purchase items, totals and audit entry are committed atomically.

begin;

create or replace function public.receive_material_purchase(
  p_organization_id uuid,
  p_vendor_id uuid,
  p_purchase_number text,
  p_vendor_invoice_number text,
  p_purchase_date date,
  p_items jsonb,
  p_other_charges_paise bigint default 0,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_purchase uuid;
  v_item jsonb;
  v_material uuid;
  v_qty numeric;
  v_rate bigint;
  v_gst numeric;
  v_line bigint;
  v_line_gst bigint;
  v_subtotal bigint := 0;
  v_gst_total bigint := 0;
  v_name text;
  v_unit text;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;

  if not exists (
    select 1 from public.vendors
    where id = p_vendor_id
      and organization_id = p_organization_id
      and is_active
  ) then
    raise exception 'active_vendor_not_found';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'purchase_items_required';
  end if;

  if coalesce(p_other_charges_paise, 0) < 0 then
    raise exception 'other_charges_cannot_be_negative';
  end if;

  insert into public.material_purchases (
    organization_id, vendor_id, purchase_number, vendor_invoice_number,
    purchase_date, status, other_charges_paise, notes, created_by
  ) values (
    p_organization_id, p_vendor_id,
    nullif(trim(p_purchase_number), ''),
    nullif(trim(p_vendor_invoice_number), ''),
    coalesce(p_purchase_date, current_date),
    'received', coalesce(p_other_charges_paise, 0), p_notes, auth.uid()
  )
  returning id into v_purchase;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_material := (v_item->>'material_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_rate := (v_item->>'unit_purchase_price_paise')::bigint;
    v_gst := coalesce((v_item->>'gst_rate')::numeric, 0);

    if v_qty is null or v_qty <= 0
       or v_rate is null or v_rate < 0
       or v_gst < 0 or v_gst > 100 then
      raise exception 'invalid_purchase_item';
    end if;

    select m.name, coalesce(u.name, u.short_code)
      into v_name, v_unit
    from public.materials m
    left join public.units u on u.id = m.unit_id
    where m.id = v_material
      and m.organization_id = p_organization_id
      and m.is_active = true
    for update of m;

    if not found then
      raise exception 'active_material_not_found';
    end if;

    v_line := round(v_qty * v_rate)::bigint;
    v_line_gst := round(v_line * v_gst / 100.0)::bigint;
    v_subtotal := v_subtotal + v_line;
    v_gst_total := v_gst_total + v_line_gst;

    insert into public.material_purchase_items (
      organization_id, purchase_id, material_id,
      description_snapshot, unit_name_snapshot,
      quantity, unit_cost_paise, gst_rate,
      line_subtotal_paise, line_gst_paise
    ) values (
      p_organization_id, v_purchase, v_material,
      v_name, v_unit, v_qty, v_rate, v_gst, v_line, v_line_gst
    );

    update public.materials
    set current_quantity = current_quantity + v_qty,
        updated_at = now()
    where id = v_material
      and organization_id = p_organization_id;

    insert into public.stock_movements (
      organization_id, material_id, movement_type, quantity,
      reference_type, reference_id, notes, created_by
    ) values (
      p_organization_id, v_material, 'purchase', v_qty,
      'material_purchase', v_purchase,
      'Vendor purchase ' || coalesce(nullif(trim(p_purchase_number), ''), v_purchase::text),
      auth.uid()
    );
  end loop;

  update public.material_purchases
  set subtotal_paise = v_subtotal,
      gst_amount_paise = v_gst_total,
      total_amount_paise = v_subtotal + v_gst_total + coalesce(p_other_charges_paise, 0)
  where id = v_purchase
    and organization_id = p_organization_id;

  insert into public.audit_log (
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'material_purchase_received',
    'material_purchase', v_purchase,
    jsonb_build_object(
      'subtotal_paise', v_subtotal,
      'gst_amount_paise', v_gst_total,
      'item_count', jsonb_array_length(p_items)
    )
  );

  return v_purchase;
end;
$function$;

commit;

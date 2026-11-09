-- Add per-unit acquisition cost and contractor issue rate to the stock ledger.
-- Keep the catalogue selling price as a separate reference value.

begin;

create or replace view public.construction_stock_ledger
with (security_invoker = true) as
select
  sm.id,
  sm.organization_id,
  sm.material_id,
  sm.movement_type,
  sm.quantity,
  sm.reference_type,
  sm.reference_id,
  sm.notes,
  sm.created_by,
  sm.created_at,
  m.name as material_name,
  m.selling_price_paise,
  u.short_code as unit_short_code,
  coalesce(ct.name,v.name) as counterparty_name,
  p.name as project_name,
  c.contract_number,
  wo.po_number,
  mp.vendor_invoice_number,
  case
    when sm.reference_type = 'material_purchase' then (
      select mpi.unit_purchase_price_paise
      from public.material_purchase_items mpi
      where mpi.organization_id = sm.organization_id
        and mpi.purchase_id = sm.reference_id
        and mpi.material_id = sm.material_id
      order by mpi.created_at desc
      limit 1
    )
    when sm.reference_type = 'material_issue' then (
      select mii.purchase_unit_cost_paise
      from public.material_issue_items mii
      where mii.organization_id = sm.organization_id
        and mii.issue_id = mi.id
        and mii.material_id = sm.material_id
      order by mii.created_at desc
      limit 1
    )
    when sm.reference_type = 'material_return' then (
      select mii.purchase_unit_cost_paise
      from public.material_return_items mri
      join public.material_issue_items mii
        on mii.id = mri.issue_item_id
       and mii.organization_id = mri.organization_id
      where mri.organization_id = sm.organization_id
        and mri.return_id = sm.reference_id
        and mri.material_id = sm.material_id
      order by mri.created_at desc
      limit 1
    )
    else null
  end as actual_unit_cost_paise,
  case
    when sm.reference_type = 'material_issue' then (
      select mii.contractor_unit_rate_paise
      from public.material_issue_items mii
      where mii.organization_id = sm.organization_id
        and mii.issue_id = mi.id
        and mii.material_id = sm.material_id
      order by mii.created_at desc
      limit 1
    )
    when sm.reference_type = 'material_return' then (
      select mii.contractor_unit_rate_paise
      from public.material_return_items mri
      join public.material_issue_items mii
        on mii.id = mri.issue_item_id
       and mii.organization_id = mri.organization_id
      where mri.organization_id = sm.organization_id
        and mri.return_id = sm.reference_id
        and mri.material_id = sm.material_id
      order by mri.created_at desc
      limit 1
    )
    else null
  end as contractor_unit_rate_paise
from public.stock_movements sm
join public.materials m
  on m.id = sm.material_id
 and m.organization_id = sm.organization_id
left join public.units u
  on u.id = m.unit_id
 and u.organization_id = m.organization_id
left join public.material_issues mi
  on sm.reference_type = 'material_issue'
 and mi.id = sm.reference_id
 and mi.organization_id = sm.organization_id
left join public.material_returns mr
  on sm.reference_type = 'material_return'
 and mr.id = sm.reference_id
 and mr.organization_id = sm.organization_id
left join public.contractor_work_orders wo
  on wo.id = coalesce(mi.work_order_id, mr.work_order_id)
 and wo.organization_id = sm.organization_id
left join public.contractors ct
  on ct.id = wo.contractor_id
 and ct.organization_id = sm.organization_id
left join public.contracts c
  on c.id = wo.contract_id
 and c.organization_id = sm.organization_id
left join public.projects p
  on p.id = wo.project_id
 and p.organization_id = sm.organization_id
left join public.material_purchases mp
  on sm.reference_type = 'material_purchase'
 and mp.id = sm.reference_id
 and mp.organization_id = sm.organization_id
left join public.vendors v
  on v.id = mp.vendor_id
 and v.organization_id = sm.organization_id;

commit;

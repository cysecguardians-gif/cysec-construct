-- Construction-aware historical import operations.
-- Apply after 0016_allow_replacement_cancelled_settlements.sql.
-- Imports are transactional, organization-scoped and Admin-only. Financial events
-- are created through the same validated RPCs used by the application.

begin;

create or replace function public.import_construction_records(
  p_organization_id uuid,
  p_import_type text,
  p_rows jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_id uuid;
  v_parent_id uuid;
  v_count integer := 0;
  v_name text;
  v_key text;
  v_user uuid := auth.uid();
  v_amount bigint;
  v_status text;
  v_group record;
  v_items jsonb;
  v_vendor_id uuid;
  v_work_order_id uuid;
  v_issue_id uuid;
  v_line_count integer;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'non_empty_rows_array_required';
  end if;
  if p_import_type not in (
    'client_companies','contracts','projects','vendors','contractors',
    'work_orders','advances','client_bills','client_receipts','client_deductions',
    'material_purchases','material_issues','material_returns'
  ) then
    raise exception 'unsupported_construction_import_type';
  end if;

  -- Multi-line material transactions are supplied as one spreadsheet row per item.
  -- Rows sharing the transaction number are grouped and passed to the normal stock RPCs.
  if p_import_type = 'material_purchases' then
    for v_group in
      select value->>'purchase_number' as purchase_number,
        min(value->>'vendor_name') as vendor_name,
        min(value->>'purchase_date') as purchase_date,
        min(value->>'vendor_invoice_number') as vendor_invoice_number,
        min(value->>'other_charges') as other_charges,
        min(value->>'notes') as notes,
        count(distinct value->>'vendor_name') as vendor_count,
        count(distinct coalesce(value->>'purchase_date','')) as date_count,
        count(distinct coalesce(value->>'vendor_invoice_number','')) as invoice_count,
        count(distinct coalesce(value->>'other_charges','')) as charges_count
      from jsonb_array_elements(p_rows) group by value->>'purchase_number'
    loop
      if nullif(trim(v_group.purchase_number),'') is null or v_group.vendor_count<>1 or v_group.date_count<>1 or v_group.invoice_count<>1 or v_group.charges_count<>1 then
        raise exception 'purchase_number_required_and_vendor_must_match_for_all_lines';
      end if;
      if exists(select 1 from public.material_purchases where organization_id=p_organization_id and purchase_number=v_group.purchase_number) then
        raise exception 'purchase_number_already_exists: %',v_group.purchase_number;
      end if;
      select id into v_vendor_id from public.vendors
        where organization_id=p_organization_id and lower(name)=lower(trim(v_group.vendor_name)) and is_active;
      if v_vendor_id is null then raise exception 'vendor_not_found_for_purchase: %',v_group.vendor_name; end if;
      select count(*) into v_line_count from jsonb_array_elements(p_rows) x
        where x->>'purchase_number'=v_group.purchase_number;
      select jsonb_agg(jsonb_build_object(
        'material_id',m.id,'quantity',(x->>'quantity')::numeric,
        'unit_cost_paise',round((x->>'unit_cost')::numeric*100),
        'gst_rate',nullif(x->>'gst_rate','')::numeric
      )) into v_items
      from jsonb_array_elements(p_rows) x
      join public.materials m on m.organization_id=p_organization_id and lower(m.name)=lower(trim(x->>'material'))
      where x->>'purchase_number'=v_group.purchase_number;
      if coalesce(jsonb_array_length(v_items),0)<>v_line_count then raise exception 'purchase_material_not_found_or_missing: %',v_group.purchase_number; end if;
      perform public.record_material_purchase(
        p_organization_id,v_vendor_id,v_items,
        coalesce(nullif(v_group.purchase_date,'')::date,current_date),v_group.purchase_number,
        nullif(trim(v_group.vendor_invoice_number),''),round(coalesce(nullif(v_group.other_charges,'')::numeric,0)*100),
        nullif(trim(v_group.notes),'')
      );
      v_count:=v_count+1;
    end loop;

  elsif p_import_type = 'material_issues' then
    for v_group in
      select value->>'issue_number' as issue_number,
        min(value->>'po_number') as po_number,
        min(value->>'issue_date') as issue_date,
        min(value->>'notes') as notes,
        count(distinct value->>'po_number') as po_count,
        count(distinct coalesce(value->>'issue_date','')) as date_count
      from jsonb_array_elements(p_rows) group by value->>'issue_number'
    loop
      if nullif(trim(v_group.issue_number),'') is null or v_group.po_count<>1 or v_group.date_count<>1 then
        raise exception 'issue_number_required_and_work_order_must_match_for_all_lines';
      end if;
      if exists(select 1 from public.material_issues where organization_id=p_organization_id and issue_number=v_group.issue_number) then
        raise exception 'issue_number_already_exists: %',v_group.issue_number;
      end if;
      select id into v_work_order_id from public.contractor_work_orders
        where organization_id=p_organization_id and po_number=trim(v_group.po_number) and status in ('active','on_hold');
      if v_work_order_id is null then raise exception 'active_work_order_not_found_for_issue: %',v_group.po_number; end if;
      select count(*) into v_line_count from jsonb_array_elements(p_rows) x
        where x->>'issue_number'=v_group.issue_number;
      select jsonb_agg(jsonb_build_object(
        'material_id',m.id,'quantity',(x->>'quantity')::numeric,
        'contractor_unit_rate_paise',case when nullif(x->>'contractor_unit_rate','') is null then null else round((x->>'contractor_unit_rate')::numeric*100) end
      )) into v_items
      from jsonb_array_elements(p_rows) x
      join public.materials m on m.organization_id=p_organization_id and lower(m.name)=lower(trim(x->>'material')) and m.is_active
      where x->>'issue_number'=v_group.issue_number;
      if coalesce(jsonb_array_length(v_items),0)<>v_line_count then raise exception 'issue_material_not_found_or_inactive: %',v_group.issue_number; end if;
      perform public.issue_materials_to_contractor(
        p_organization_id,v_work_order_id,v_items,
        coalesce(nullif(v_group.issue_date,'')::date,current_date),v_group.issue_number,
        nullif(trim(v_group.notes),'')
      );
      v_count:=v_count+1;
    end loop;

  elsif p_import_type = 'material_returns' then
    for v_group in
      select value->>'return_number' as return_number,
        min(value->>'issue_number') as issue_number,
        min(value->>'return_date') as return_date,
        min(value->>'notes') as notes,
        count(distinct value->>'issue_number') as issue_count,
        count(distinct coalesce(value->>'return_date','')) as date_count
      from jsonb_array_elements(p_rows) group by value->>'return_number'
    loop
      if nullif(trim(v_group.return_number),'') is null or v_group.issue_count<>1 or v_group.date_count<>1 then
        raise exception 'return_number_required_and_issue_must_match_for_all_lines';
      end if;
      if exists(select 1 from public.material_returns where organization_id=p_organization_id and return_number=v_group.return_number) then
        raise exception 'return_number_already_exists: %',v_group.return_number;
      end if;
      select count(*) into v_line_count from public.material_issues
        where organization_id=p_organization_id and issue_number=trim(v_group.issue_number) and status<>'cancelled';
      if v_line_count<>1 then raise exception 'material_issue_not_found_or_ambiguous_for_return: %',v_group.issue_number; end if;
      select id into v_issue_id from public.material_issues
        where organization_id=p_organization_id and issue_number=trim(v_group.issue_number) and status<>'cancelled';
      select count(*) into v_line_count from jsonb_array_elements(p_rows) x
        where x->>'return_number'=v_group.return_number;
      if exists (
        select 1 from jsonb_array_elements(p_rows) x
        where x->>'return_number'=v_group.return_number
          and (select count(*) from public.material_issue_items ii where ii.issue_id=v_issue_id and lower(ii.description_snapshot)=lower(trim(x->>'material')))<>1
      ) then raise exception 'return_material_not_found_or_ambiguous: %',v_group.return_number; end if;
      select jsonb_agg(jsonb_build_object(
        'issue_item_id',ii.id,'quantity_returned',(x->>'quantity_returned')::numeric,
        'condition',coalesce(nullif(x->>'condition',''),'usable'),'notes',nullif(trim(x->>'line_notes'),'')
      )) into v_items
      from jsonb_array_elements(p_rows) x
      join public.material_issue_items ii on ii.issue_id=v_issue_id
        and lower(ii.description_snapshot)=lower(trim(x->>'material'))
      where x->>'return_number'=v_group.return_number;
      if coalesce(jsonb_array_length(v_items),0)<>v_line_count then raise exception 'return_material_not_found_or_ambiguous: %',v_group.return_number; end if;
      perform public.return_contractor_materials(
        p_organization_id,v_issue_id,v_items,
        coalesce(nullif(v_group.return_date,'')::date,current_date),v_group.return_number,
        nullif(trim(v_group.notes),'')
      );
      v_count:=v_count+1;
    end loop;
  end if;

  if p_import_type in ('material_purchases','material_issues','material_returns') then
    insert into public.audit_log(organization_id,user_id,action,entity_type,details)
    values(p_organization_id,v_user,'historical_import','construction_'||p_import_type,jsonb_build_object('transactions',v_count));
    return jsonb_build_object('imported_transactions',v_count,'import_type',p_import_type);
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    if p_import_type = 'client_companies' then
      v_name := nullif(trim(v_row->>'name'),'');
      if v_name is null then raise exception 'client_company_name_required'; end if;
      if exists(select 1 from public.client_companies where organization_id=p_organization_id and lower(name)=lower(v_name)) then
        raise exception 'client_company_already_exists: %', v_name;
      end if;
      v_id := public.create_client_company(
        p_organization_id,v_name,nullif(trim(v_row->>'gstin'),''),nullif(trim(v_row->>'pan'),''),
        nullif(trim(v_row->>'contact_person'),''),nullif(trim(v_row->>'phone'),''),
        nullif(trim(v_row->>'email'),''),nullif(trim(v_row->>'billing_address'),''),
        nullif(trim(v_row->>'city'),''),nullif(trim(v_row->>'state'),''),
        nullif(trim(v_row->>'state_code'),''),nullif(trim(v_row->>'postal_code'),'')
      );

    elsif p_import_type = 'contracts' then
      v_key := nullif(trim(v_row->>'contract_number'),'');
      v_name := nullif(trim(v_row->>'client_company'),'');
      if v_key is null or v_name is null or nullif(trim(v_row->>'title'),'') is null then
        raise exception 'contract_number_client_company_and_title_required';
      end if;
      if exists(select 1 from public.contracts where organization_id=p_organization_id and contract_number=v_key) then
        raise exception 'contract_number_already_exists: %', v_key;
      end if;
      select id into v_parent_id from public.client_companies
        where organization_id=p_organization_id and lower(name)=lower(v_name) and is_active limit 1;
      if v_parent_id is null then raise exception 'client_company_not_found: %', v_name; end if;
      v_amount := round(coalesce(nullif(v_row->>'original_value','')::numeric,0)*100);
      if v_amount < 0 then raise exception 'contract_value_cannot_be_negative'; end if;
      v_id := public.create_contract(
        p_organization_id,v_parent_id,v_key,trim(v_row->>'title'),v_amount,
        coalesce(round(nullif(v_row->>'revised_value','')::numeric*100),v_amount),
        coalesce(nullif(trim(v_row->>'contract_type'),''),'tender'),
        coalesce(nullif(v_row->>'contract_date','')::date,current_date),
        nullif(v_row->>'start_date','')::date,nullif(v_row->>'expected_end_date','')::date,
        nullif(trim(v_row->>'scope_of_work'),''),nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'projects' then
      v_key := nullif(trim(v_row->>'contract_number'),'');
      v_name := nullif(trim(v_row->>'name'),'');
      if v_key is null or v_name is null then raise exception 'project_contract_number_and_name_required'; end if;
      select id into v_parent_id from public.contracts
        where organization_id=p_organization_id and contract_number=v_key and status<>'cancelled';
      if v_parent_id is null then raise exception 'contract_not_found: %', v_key; end if;
      if exists(select 1 from public.projects where organization_id=p_organization_id and contract_id=v_parent_id and lower(name)=lower(v_name)) then
        raise exception 'project_already_exists: %', v_name;
      end if;
      v_id := public.create_project(
        p_organization_id,v_parent_id,v_name,nullif(trim(v_row->>'project_code'),''),
        nullif(trim(v_row->>'site_address'),''),nullif(trim(v_row->>'site_contact'),''),
        nullif(trim(v_row->>'site_phone'),''),nullif(v_row->>'start_date','')::date,
        nullif(v_row->>'expected_end_date','')::date,nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'vendors' then
      v_name := nullif(trim(v_row->>'name'),'');
      if v_name is null then raise exception 'vendor_name_required'; end if;
      if exists(select 1 from public.vendors where organization_id=p_organization_id and lower(name)=lower(v_name)) then
        raise exception 'vendor_already_exists: %', v_name;
      end if;
      v_id := public.create_vendor(
        p_organization_id,v_name,nullif(trim(v_row->>'gstin'),''),nullif(trim(v_row->>'pan'),''),
        nullif(trim(v_row->>'contact_person'),''),nullif(trim(v_row->>'phone'),''),
        nullif(trim(v_row->>'email'),''),nullif(trim(v_row->>'address'),''),
        nullif(trim(v_row->>'city'),''),nullif(trim(v_row->>'state'),''),
        nullif(trim(v_row->>'state_code'),''),nullif(trim(v_row->>'postal_code'),'')
      );

    elsif p_import_type = 'contractors' then
      v_name := nullif(trim(v_row->>'name'),'');
      if v_name is null then raise exception 'contractor_name_required'; end if;
      if exists(select 1 from public.contractors where organization_id=p_organization_id and lower(name)=lower(v_name)) then
        raise exception 'contractor_already_exists: %', v_name;
      end if;
      v_id := public.create_contractor(
        p_organization_id,v_name,coalesce(nullif(trim(v_row->>'contractor_type'),''),'subcontractor'),
        nullif(trim(v_row->>'gstin'),''),nullif(trim(v_row->>'pan'),''),
        nullif(trim(v_row->>'contact_person'),''),nullif(trim(v_row->>'phone'),''),
        nullif(trim(v_row->>'email'),''),nullif(trim(v_row->>'address'),''),
        nullif(trim(v_row->>'city'),''),nullif(trim(v_row->>'state'),''),
        nullif(trim(v_row->>'state_code'),''),nullif(trim(v_row->>'postal_code'),''),
        nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'work_orders' then
      v_key := nullif(trim(v_row->>'po_number'),'');
      if v_key is null then raise exception 'po_number_required'; end if;
      if exists(select 1 from public.contractor_work_orders where organization_id=p_organization_id and po_number=v_key) then
        raise exception 'po_number_already_exists: %', v_key;
      end if;
      select id into v_parent_id from public.projects
        where organization_id=p_organization_id and project_code=nullif(trim(v_row->>'project_code'),'') limit 1;
      if v_parent_id is null then
        select id into v_parent_id from public.projects
          where organization_id=p_organization_id and lower(name)=lower(nullif(trim(v_row->>'project_name'),'')) limit 1;
      end if;
      if v_parent_id is null then raise exception 'project_not_found_for_work_order'; end if;
      select id into v_id from public.contractors
        where organization_id=p_organization_id and lower(name)=lower(nullif(trim(v_row->>'contractor'),'')) and is_active limit 1;
      if v_id is null then raise exception 'contractor_not_found_for_work_order'; end if;
      v_name := lower(coalesce(nullif(trim(v_row->>'payment_basis'),''),'fixed'));
      if v_name not in ('fixed','percentage') then raise exception 'invalid_work_order_payment_basis'; end if;
      v_id := public.create_contractor_work_order(
        p_organization_id,v_parent_id,v_id,v_key,v_name,
        case when v_name='fixed' then round(nullif(v_row->>'fixed_amount','')::numeric*100) else null end,
        case when v_name='percentage' then nullif(v_row->>'agreed_percentage','')::numeric else null end,
        coalesce(nullif(v_row->>'po_date','')::date,current_date),
        coalesce(nullif(v_row->>'materials_chargeable','')::boolean,true),
        nullif(v_row->>'start_date','')::date,nullif(v_row->>'expected_end_date','')::date,
        nullif(trim(v_row->>'scope_of_work'),''),nullif(trim(v_row->>'terms_and_conditions'),''),
        nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'advances' then
      v_key := nullif(trim(v_row->>'po_number'),'');
      select id into v_parent_id from public.contractor_work_orders
        where organization_id=p_organization_id and po_number=v_key;
      if v_parent_id is null then raise exception 'work_order_not_found_for_advance: %', v_key; end if;
      v_amount := round(nullif(v_row->>'amount','')::numeric*100);
      if v_amount is null or v_amount<=0 then raise exception 'advance_amount_must_be_positive'; end if;
      v_id := public.record_contractor_advance(
        p_organization_id,v_parent_id,v_amount,coalesce(nullif(v_row->>'advance_date','')::date,current_date),
        coalesce(nullif(trim(v_row->>'payment_method'),''),'cash'),
        nullif(trim(v_row->>'reference_number'),''),nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'client_bills' then
      v_key := nullif(trim(v_row->>'bill_number'),'');
      select id into v_parent_id from public.contracts
        where organization_id=p_organization_id and contract_number=nullif(trim(v_row->>'contract_number'),'');
      if v_parent_id is null then raise exception 'contract_not_found_for_bill'; end if;
      if exists(select 1 from public.client_bills where organization_id=p_organization_id and bill_number=v_key) then
        raise exception 'bill_number_already_exists: %', v_key;
      end if;
      v_amount := round(nullif(v_row->>'amount_claimed','')::numeric*100);
      if v_amount is null or v_amount<=0 then raise exception 'bill_amount_must_be_positive'; end if;
      v_id := public.create_client_bill(
        p_organization_id,v_parent_id,v_key,v_amount,coalesce(nullif(v_row->>'bill_date','')::date,current_date),
        nullif(v_row->>'period_from','')::date,nullif(v_row->>'period_to','')::date,
        coalesce(nullif(trim(v_row->>'status'),''),'submitted'),nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'client_receipts' then
      v_key := nullif(trim(v_row->>'contract_number'),'');
      select id into v_parent_id from public.contracts where organization_id=p_organization_id and contract_number=v_key;
      if v_parent_id is null then raise exception 'contract_not_found_for_receipt: %', v_key; end if;
      select id into v_id from public.client_bills
        where organization_id=p_organization_id and contract_id=v_parent_id and bill_number=nullif(trim(v_row->>'bill_number'),'');
      v_amount := round(nullif(v_row->>'amount','')::numeric*100);
      if v_amount is null or v_amount<=0 then raise exception 'receipt_amount_must_be_positive'; end if;
      if nullif(trim(v_row->>'bill_number'),'') is not null and v_id is null then raise exception 'bill_not_found_for_receipt'; end if;
      if nullif(trim(v_row->>'reference_number'),'') is not null and exists(
        select 1 from public.client_receipts where organization_id=p_organization_id and reference_number=trim(v_row->>'reference_number')
      ) then raise exception 'receipt_reference_already_exists'; end if;
      v_id := public.record_client_receipt(
        p_organization_id,v_parent_id,v_amount,v_id,
        coalesce(nullif(v_row->>'receipt_date','')::date,current_date),
        coalesce(nullif(trim(v_row->>'payment_method'),''),'other'),
        nullif(trim(v_row->>'reference_number'),''),nullif(trim(v_row->>'notes'),'')
      );

    elsif p_import_type = 'client_deductions' then
      v_key := nullif(trim(v_row->>'contract_number'),'');
      select id into v_parent_id from public.contracts where organization_id=p_organization_id and contract_number=v_key;
      if v_parent_id is null then raise exception 'contract_not_found_for_deduction: %', v_key; end if;
      select id into v_id from public.client_bills
        where organization_id=p_organization_id and contract_id=v_parent_id and bill_number=nullif(trim(v_row->>'bill_number'),'');
      if nullif(trim(v_row->>'bill_number'),'') is not null and v_id is null then raise exception 'bill_not_found_for_deduction'; end if;
      v_amount := round(nullif(v_row->>'amount','')::numeric*100);
      if v_amount is null or v_amount<=0 then raise exception 'deduction_amount_must_be_positive'; end if;
      if nullif(trim(v_row->>'reference_number'),'') is not null and exists(
        select 1 from public.client_deductions where organization_id=p_organization_id and reference_number=trim(v_row->>'reference_number')
      ) then raise exception 'deduction_reference_already_exists'; end if;
      v_id := public.record_client_deduction(
        p_organization_id,v_parent_id,coalesce(nullif(trim(v_row->>'deduction_type'),''),'other'),v_amount,v_id,
        coalesce(nullif(v_row->>'deduction_date','')::date,current_date),
        coalesce(nullif(v_row->>'is_recoverable','')::boolean,false),
        nullif(trim(v_row->>'reference_number'),''),nullif(trim(v_row->>'notes'),'')
      );
    end if;
    v_count := v_count + 1;
  end loop;

  insert into public.audit_log(organization_id,user_id,action,entity_type,details)
  values(p_organization_id,v_user,'historical_import','construction_'||p_import_type,jsonb_build_object('count',v_count));
  return jsonb_build_object('imported',v_count,'import_type',p_import_type);
end;
$$;

revoke all on function public.import_construction_records(uuid,text,jsonb) from public, anon;
grant execute on function public.import_construction_records(uuid,text,jsonb) to authenticated;

insert into public.app_schema_version(version) values (17) on conflict (version) do nothing;

commit;

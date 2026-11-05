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
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'non_empty_rows_array_required';
  end if;
  if p_import_type not in (
    'client_companies','contracts','projects','vendors','contractors',
    'work_orders','advances','client_bills','client_receipts','client_deductions'
  ) then
    raise exception 'unsupported_construction_import_type';
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
        where organization_id=p_organization_id and (project_code=nullif(trim(v_row->>'project_code'),'') or lower(name)=lower(nullif(trim(v_row->>'project_name'),''))) limit 1;
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

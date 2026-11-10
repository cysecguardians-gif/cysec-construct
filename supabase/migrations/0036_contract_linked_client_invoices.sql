-- CySec Construct: contract-linked client invoices
-- Apply manually in Supabase SQL Editor after the existing migrations.
-- Contract invoices are tax invoices and client_bills are their finance-ledger records.

begin;

alter table public.client_companies
  add column if not exists customer_id uuid;

alter table public.client_companies
  add constraint client_companies_customer_fk
  foreign key (customer_id) references public.customers(id) on delete restrict;

-- Link existing client companies to their invoice customer by the legacy
-- normalized-name match. Create a customer only where no match exists.
do $$
declare r record; v_customer uuid;
begin
  for r in
    select * from public.client_companies
    where customer_id is null
    order by created_at, id
  loop
    select id into v_customer
    from public.customers
    where organization_id=r.organization_id
      and lower(trim(name))=lower(trim(r.name))
    order by created_at
    limit 1;

    if v_customer is null then
      insert into public.customers(
        organization_id,name,gstin,pan,phone,email,
        billing_address_line1,billing_address_line2,billing_city,
        billing_state,billing_state_code,billing_postal_code,is_active
      ) values (
        r.organization_id,r.name,r.gstin,r.pan,r.phone,r.email,
        r.address_line1,r.address_line2,r.city,r.state,r.state_code,r.postal_code,r.is_active
      ) returning id into v_customer;
    end if;

    update public.client_companies set customer_id=v_customer where id=r.id;
  end loop;
end $$;

create or replace function public.sync_client_company_customer()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.customer_id is null then
    select id into new.customer_id
    from public.customers
    where organization_id=new.organization_id
      and lower(trim(name))=lower(trim(new.name))
    order by created_at
    limit 1;
  end if;

  if new.customer_id is null then
    insert into public.customers(
      organization_id,name,gstin,pan,phone,email,
      billing_address_line1,billing_address_line2,billing_city,
      billing_state,billing_state_code,billing_postal_code,is_active
    ) values (
      new.organization_id,new.name,new.gstin,new.pan,new.phone,new.email,
      new.address_line1,new.address_line2,new.city,new.state,new.state_code,new.postal_code,new.is_active
    ) returning id into new.customer_id;
  else
    update public.customers
    set name=new.name,gstin=new.gstin,pan=new.pan,phone=new.phone,email=new.email,
        billing_address_line1=new.address_line1,billing_address_line2=new.address_line2,
        billing_city=new.city,billing_state=new.state,billing_state_code=new.state_code,
        billing_postal_code=new.postal_code,is_active=new.is_active,updated_at=now()
    where id=new.customer_id and organization_id=new.organization_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_client_company_to_customer on public.client_companies;
drop trigger if exists trg_sync_client_company_customer on public.client_companies;
create trigger trg_sync_client_company_customer
before insert or update of name,gstin,pan,phone,email,address_line1,address_line2,
  city,state,state_code,postal_code,is_active
on public.client_companies
for each row execute function public.sync_client_company_customer();

alter table public.invoices
  add column if not exists contract_id uuid,
  add column if not exists client_bill_id uuid;

alter table public.invoices
  add constraint invoices_contract_fk
  foreign key (organization_id,contract_id)
  references public.contracts(organization_id,id) on delete restrict;

alter table public.client_bills
  add column if not exists invoice_id uuid;

alter table public.client_bills
  add constraint client_bills_invoice_fk
  foreign key (invoice_id) references public.invoices(id) on delete restrict;

create unique index if not exists uq_client_bills_invoice
  on public.client_bills(invoice_id) where invoice_id is not null;

alter table public.invoices
  add constraint invoices_client_bill_fk
  foreign key (organization_id,client_bill_id)
  references public.client_bills(organization_id,id) on delete restrict;

create index if not exists idx_invoices_contract
  on public.invoices(organization_id,contract_id,invoice_date desc);

-- One atomic operation creates both the statutory invoice and its contract
-- bill ledger entry. The contract row lock prevents concurrent overbilling.
create or replace function public.issue_contract_invoice(
  p_organization_id uuid,
  p_contract_id uuid,
  p_invoice_date date,
  p_items jsonb,
  p_gst_enabled boolean default true,
  p_place_of_supply_state text default null,
  p_place_of_supply_state_code text default null,
  p_notes text default null,
  p_period_from date default null,
  p_period_to date default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_contract public.contracts%rowtype;
  v_company public.client_companies%rowtype;
  v_customer public.customers%rowtype;
  v_invoice_id uuid;
  v_bill_id uuid;
  v_invoice_number text;
  v_org_state_code text;
  v_same_state boolean;
  v_item jsonb;
  v_description text;
  v_hsn text;
  v_unit text;
  v_qty numeric(14,3);
  v_price bigint;
  v_rate numeric(5,2);
  v_base bigint;
  v_line_cgst bigint;
  v_line_sgst bigint;
  v_line_igst bigint;
  v_line_total bigint;
  v_subtotal bigint:=0;
  v_cgst bigint:=0;
  v_sgst bigint:=0;
  v_igst bigint:=0;
  v_grand bigint:=0;
  v_already_billed bigint:=0;
begin
  perform public.require_org_member(p_organization_id);

  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'At least one work description is required';
  end if;

  select * into v_contract
  from public.contracts
  where id=p_contract_id and organization_id=p_organization_id
    and status not in ('draft','cancelled','closed')
  for update;
  if not found then raise exception 'Active contract not found'; end if;

  select * into v_company
  from public.client_companies
  where id=v_contract.client_company_id and organization_id=p_organization_id
    and is_active=true;
  if not found or v_company.customer_id is null then
    raise exception 'Client company is not linked to an active invoice customer';
  end if;

  select * into v_customer
  from public.customers
  where id=v_company.customer_id and organization_id=p_organization_id
    and is_active=true;
  if not found then raise exception 'Invoice customer is inactive or missing'; end if;

  select coalesce(sum(amount_paise),0)::bigint into v_already_billed
  from public.client_bills
  where organization_id=p_organization_id and contract_id=p_contract_id
    and status not in ('draft','rejected','cancelled');

  v_org_state_code:=(
    select state_code from public.organizations where id=p_organization_id
  );
  v_same_state:=coalesce(nullif(trim(p_place_of_supply_state_code),''),v_customer.billing_state_code)=v_org_state_code;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_description:=nullif(trim(v_item->>'description'),'');
    v_hsn:=nullif(trim(v_item->>'hsn_sac_code'),'');
    v_unit:=nullif(trim(v_item->>'unit_name'),'');
    v_qty:=coalesce(nullif(v_item->>'quantity','')::numeric,1);
    v_price:=coalesce(nullif(v_item->>'unit_price_paise','')::bigint,0);
    v_rate:=case when p_gst_enabled then coalesce(nullif(v_item->>'gst_rate','')::numeric,0) else 0 end;
    if v_description is null or v_qty<=0 or v_price<0 or v_rate<0 or v_rate>100 then
      raise exception 'Each work line needs a description, positive quantity and valid rate';
    end if;
    v_base:=round(v_qty*v_price);
    if p_gst_enabled and v_same_state then
      v_line_cgst:=round(v_base*v_rate/200);
      v_line_sgst:=round(v_base*v_rate/200);
      v_line_igst:=0;
    elsif p_gst_enabled then
      v_line_cgst:=0;v_line_sgst:=0;
      v_line_igst:=round(v_base*v_rate/100);
    else
      v_line_cgst:=0;v_line_sgst:=0;v_line_igst:=0;
    end if;
    v_line_total:=v_base+v_line_cgst+v_line_sgst+v_line_igst;
    v_subtotal:=v_subtotal+v_base;
    v_cgst:=v_cgst+v_line_cgst;v_sgst:=v_sgst+v_line_sgst;v_igst:=v_igst+v_line_igst;
    v_grand:=v_grand+v_line_total;
  end loop;

  if v_grand<=0 then raise exception 'Invoice total must be greater than zero'; end if;
  if v_already_billed+v_grand>v_contract.revised_value_paise then
    raise exception 'Invoice exceeds remaining contract value. Remaining amount: % paise',
      greatest(v_contract.revised_value_paise-v_already_billed,0);
  end if;

  v_invoice_number:=public.next_invoice_number(p_organization_id,coalesce(p_invoice_date,current_date));
  insert into public.invoices(
    organization_id,customer_id,invoice_number,invoice_date,
    place_of_supply_state,place_of_supply_state_code,status,
    gst_enabled,cgst_amount_paise,sgst_amount_paise,igst_amount_paise,
    subtotal_paise,taxable_value_paise,total_gst_paise,grand_total_paise,
    notes,created_by,contract_id
  ) values (
    p_organization_id,v_customer.id,v_invoice_number,coalesce(p_invoice_date,current_date),
    coalesce(nullif(trim(p_place_of_supply_state),''),v_customer.billing_state),
    coalesce(nullif(trim(p_place_of_supply_state_code),''),v_customer.billing_state_code),
    'issued',coalesce(p_gst_enabled,false),v_cgst,v_sgst,v_igst,
    v_subtotal,v_subtotal,v_cgst+v_sgst+v_igst,v_grand,
    p_notes,auth.uid(),p_contract_id
  ) returning id into v_invoice_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_description:=trim(v_item->>'description');
    v_hsn:=nullif(trim(v_item->>'hsn_sac_code'),'');
    v_unit:=nullif(trim(v_item->>'unit_name'),'');
    v_qty:=coalesce(nullif(v_item->>'quantity','')::numeric,1);
    v_price:=coalesce(nullif(v_item->>'unit_price_paise','')::bigint,0);
    v_rate:=case when p_gst_enabled then coalesce(nullif(v_item->>'gst_rate','')::numeric,0) else 0 end;
    v_base:=round(v_qty*v_price);
    if p_gst_enabled and v_same_state then
      v_line_cgst:=round(v_base*v_rate/200);v_line_sgst:=round(v_base*v_rate/200);v_line_igst:=0;
    elsif p_gst_enabled then
      v_line_cgst:=0;v_line_sgst:=0;v_line_igst:=round(v_base*v_rate/100);
    else
      v_line_cgst:=0;v_line_sgst:=0;v_line_igst:=0;
    end if;
    insert into public.invoice_items(
      invoice_id,material_id,description,hsn_sac_code,unit_name,quantity,
      unit_price_paise,discount_amount_paise,taxable_value_paise,gst_rate,
      cgst_amount_paise,sgst_amount_paise,igst_amount_paise,line_total_paise
    ) values (
      v_invoice_id,null,v_description,v_hsn,v_unit,v_qty,v_price,0,v_base,v_rate,
      v_line_cgst,v_line_sgst,v_line_igst,v_base+v_line_cgst+v_line_sgst+v_line_igst
    );
  end loop;

  insert into public.client_bills(
    organization_id,contract_id,bill_number,bill_date,description,
    period_from,period_to,amount_paise,status,created_by,invoice_id
  ) values (
    p_organization_id,p_contract_id,v_invoice_number,coalesce(p_invoice_date,current_date),
    'Invoice '||v_invoice_number,p_period_from,p_period_to,v_grand,'submitted',auth.uid(),v_invoice_id
  ) returning id into v_bill_id;

  update public.invoices set client_bill_id=v_bill_id where id=v_invoice_id;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contract_invoice_issued','invoice',v_invoice_id,
    jsonb_build_object('contract_id',p_contract_id,'client_bill_id',v_bill_id,
      'invoice_number',v_invoice_number,'grand_total_paise',v_grand));

  return v_invoice_id;
end;
$$;

-- Mirror payments made through the existing invoice payment screen into the
-- contract receipt/allocation ledger. This keeps both reporting surfaces aligned.
create or replace function public.sync_contract_invoice_payment()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_contract_id uuid; v_bill_id uuid; v_receipt_id uuid;
begin
  select contract_id,client_bill_id into v_contract_id,v_bill_id
  from public.invoices where id=new.invoice_id and organization_id=new.organization_id;
  if v_contract_id is null or v_bill_id is null then return new; end if;

  insert into public.client_receipts(
    organization_id,contract_id,receipt_number,receipt_date,amount_paise,
    payment_method,reference_number,notes,created_by
  ) values (
    new.organization_id,v_contract_id,'PAY-'||new.id::text,new.payment_date,
    new.amount_paise,new.payment_method,new.reference_number,new.notes,new.created_by
  ) returning id into v_receipt_id;

  insert into public.client_receipt_allocations(
    organization_id,receipt_id,bill_id,amount_paise
  ) values (new.organization_id,v_receipt_id,v_bill_id,new.amount_paise);

  update public.client_bills
  set status=case
    when (select coalesce(sum(amount_paise),0) from public.client_receipt_allocations
          where organization_id=new.organization_id and bill_id=v_bill_id)>=amount_paise
      then 'paid' else 'partially_paid' end,
      updated_at=now()
  where id=v_bill_id and organization_id=new.organization_id;
  return new;
end;
$$;

drop trigger if exists trg_sync_contract_invoice_payment on public.payments;
create trigger trg_sync_contract_invoice_payment
after insert on public.payments
for each row execute function public.sync_contract_invoice_payment();

create or replace function public.sync_contract_invoice_cancellation()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.status='cancelled' and old.status is distinct from new.status then
    update public.client_bills
    set status='cancelled',updated_at=now()
    where invoice_id=new.id and organization_id=new.organization_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_contract_invoice_cancellation on public.invoices;
create trigger trg_sync_contract_invoice_cancellation
after update of status on public.invoices
for each row execute function public.sync_contract_invoice_cancellation();

grant execute on function public.issue_contract_invoice(uuid,uuid,date,jsonb,boolean,text,text,text,date,date) to authenticated;
revoke execute on function public.issue_contract_invoice(uuid,uuid,date,jsonb,boolean,text,text,text,date,date) from anon;

insert into public.app_schema_version(version) values (36) on conflict (version) do nothing;

commit;

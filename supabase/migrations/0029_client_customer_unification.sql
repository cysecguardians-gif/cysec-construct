-- CySec Construct schema v29
-- Synchronize tender/client companies with invoice customers.

begin;

insert into public.customers (
  organization_id, name, gstin, pan, phone, email,
  billing_address_line1, billing_address_line2, billing_city,
  billing_state, billing_state_code, billing_postal_code, is_active
)
select
  cc.organization_id, cc.name, cc.gstin, cc.pan, cc.phone, cc.email,
  cc.address_line1, cc.address_line2, cc.city,
  cc.state, cc.state_code, cc.postal_code, cc.is_active
from public.client_companies cc
where not exists (
  select 1 from public.customers c
  where c.organization_id = cc.organization_id
    and lower(trim(c.name)) = lower(trim(cc.name))
);

create or replace function public.sync_client_company_to_customer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare matched_customer_id uuid;
begin
  select c.id into matched_customer_id
  from public.customers c
  where c.organization_id = new.organization_id
    and lower(trim(c.name)) = lower(trim(new.name))
  order by c.created_at
  limit 1;

  if matched_customer_id is null then
    insert into public.customers (
      organization_id, name, gstin, pan, phone, email,
      billing_address_line1, billing_address_line2, billing_city,
      billing_state, billing_state_code, billing_postal_code, is_active
    ) values (
      new.organization_id, new.name, new.gstin, new.pan, new.phone, new.email,
      new.address_line1, new.address_line2, new.city,
      new.state, new.state_code, new.postal_code, new.is_active
    );
  else
    update public.customers
    set name = new.name,
        gstin = coalesce(new.gstin, gstin),
        pan = coalesce(new.pan, pan),
        phone = coalesce(new.phone, phone),
        email = coalesce(new.email, email),
        billing_address_line1 = coalesce(new.address_line1, billing_address_line1),
        billing_address_line2 = coalesce(new.address_line2, billing_address_line2),
        billing_city = coalesce(new.city, billing_city),
        billing_state = coalesce(new.state, billing_state),
        billing_state_code = coalesce(new.state_code, billing_state_code),
        billing_postal_code = coalesce(new.postal_code, billing_postal_code),
        is_active = new.is_active,
        updated_at = now()
    where id = matched_customer_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_client_company_to_customer on public.client_companies;
create trigger trg_sync_client_company_to_customer
after insert or update of name, gstin, pan, phone, email, address_line1,
  address_line2, city, state, state_code, postal_code, is_active
on public.client_companies
for each row execute function public.sync_client_company_to_customer();

insert into public.app_schema_version(version)
values (29)
on conflict (version) do nothing;

commit;

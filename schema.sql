-- Ghar Kharcha Online v2 — Supabase database
create extension if not exists pgcrypto;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  join_code text not null unique,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check(role in ('owner','admin','member')),
  display_name text not null default '',
  created_at timestamptz not null default now(),
  primary key (household_id,user_id)
);

create table if not exists public.wallets (
  household_id uuid primary key references public.households(id) on delete cascade,
  fund numeric(14,2) not null default 0,
  reserve numeric(14,2) not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  category text not null,
  amount numeric(14,2) not null check(amount > 0),
  note text not null default '',
  expense_date date not null default current_date,
  has_bill boolean not null default false,
  photo_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  type text not null,
  amount numeric(14,2) not null check(amount >= 0),
  balance_before numeric(14,2) not null,
  balance_after numeric(14,2) not null,
  transaction_date date not null default current_date,
  note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists expenses_household_date_idx on public.expenses(household_id, expense_date desc, created_at desc);
create index if not exists expenses_household_category_idx on public.expenses(household_id, category);
create index if not exists transactions_household_date_idx on public.transactions(household_id, transaction_date desc, created_at desc);

create or replace function public.is_member(p_household uuid)
returns boolean language sql security definer set search_path=public stable as $$
  select exists(select 1 from public.household_members m where m.household_id=p_household and m.user_id=auth.uid());
$$;

create or replace function public.my_role(p_household uuid)
returns text language sql security definer set search_path=public stable as $$
  select role from public.household_members where household_id=p_household and user_id=auth.uid();
$$;

create or replace function public.create_household(p_name text)
returns public.households language plpgsql security definer set search_path=public as $$
declare h public.households; code text;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  if exists(select 1 from public.household_members where user_id=auth.uid()) then raise exception 'You already belong to a household'; end if;
  loop
    code := upper(substr(encode(gen_random_bytes(8),'hex'),1,6));
    exit when not exists(select 1 from public.households where join_code=code);
  end loop;
  insert into public.households(name,join_code,created_by)
  values(coalesce(nullif(trim(p_name),''),'My Family'),code,auth.uid()) returning * into h;
  insert into public.household_members(household_id,user_id,role,display_name)
  values(h.id,auth.uid(),'owner',coalesce((select raw_user_meta_data->>'name' from auth.users where id=auth.uid()),''));
  insert into public.wallets(household_id) values(h.id);
  return h;
end;$$;

create or replace function public.join_household(p_code text)
returns public.households language plpgsql security definer set search_path=public as $$
declare h public.households;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  select * into h from public.households where join_code=upper(trim(p_code));
  if h.id is null then raise exception 'Invalid join code'; end if;
  insert into public.household_members(household_id,user_id,role,display_name)
  values(h.id,auth.uid(),'member',coalesce((select raw_user_meta_data->>'name' from auth.users where id=auth.uid()),''))
  on conflict do nothing;
  return h;
end;$$;

create or replace function public.change_wallet(p_household uuid, p_bucket text, p_delta numeric, p_date date, p_note text default '')
returns numeric language plpgsql security definer set search_path=public as $$
declare before_amt numeric; after_amt numeric; typ text;
begin
  if not public.is_member(p_household) then raise exception 'Not a household member'; end if;
  if p_delta = 0 then raise exception 'Amount cannot be zero'; end if;
  if p_bucket not in ('fund','reserve') then raise exception 'Invalid wallet bucket'; end if;
  perform 1 from public.wallets where household_id=p_household for update;
  if p_bucket='fund' then
    select fund into before_amt from public.wallets where household_id=p_household;
    after_amt := before_amt + p_delta;
    if after_amt < 0 then raise exception 'Balance cannot go below zero'; end if;
    update public.wallets set fund=after_amt, updated_at=now() where household_id=p_household;
    typ := case when p_delta>0 then 'fund_add' else 'fund_remove' end;
  else
    select reserve into before_amt from public.wallets where household_id=p_household;
    after_amt := before_amt + p_delta;
    if after_amt < 0 then raise exception 'Balance cannot go below zero'; end if;
    update public.wallets set reserve=after_amt, updated_at=now() where household_id=p_household;
    typ := case when p_delta>0 then 'reserve_add' else 'reserve_remove' end;
  end if;
  insert into public.transactions(household_id,user_id,type,amount,balance_before,balance_after,transaction_date,note)
  values(p_household,auth.uid(),typ,abs(p_delta),before_amt,after_amt,coalesce(p_date,current_date),coalesce(p_note,''));
  return after_amt;
end;$$;

create or replace function public.add_expense(p_household uuid, p_category text, p_amount numeric, p_note text, p_date date, p_has_bill boolean, p_photo_url text default null)
returns public.expenses language plpgsql security definer set search_path=public as $$
declare w numeric; e public.expenses;
begin
  if not public.is_member(p_household) then raise exception 'Not a household member'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be greater than zero'; end if;
  perform 1 from public.wallets where household_id=p_household for update;
  select fund into w from public.wallets where household_id=p_household;
  if w < p_amount then raise exception 'Fund mein paisa kam hai'; end if;
  update public.wallets set fund=w-p_amount, updated_at=now() where household_id=p_household;
  insert into public.expenses(household_id,user_id,category,amount,note,expense_date,has_bill,photo_url)
  values(p_household,auth.uid(),p_category,p_amount,coalesce(p_note,''),coalesce(p_date,current_date),coalesce(p_has_bill,false),p_photo_url) returning * into e;
  insert into public.transactions(household_id,user_id,type,amount,balance_before,balance_after,transaction_date,note)
  values(p_household,auth.uid(),'expense',p_amount,w,w-p_amount,coalesce(p_date,current_date),coalesce(p_note,''));
  return e;
end;$$;

create or replace function public.delete_expense(p_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare e public.expenses; w numeric; role_now text;
begin
  select * into e from public.expenses where id=p_id;
  if e.id is null then raise exception 'Expense not found'; end if;
  if not public.is_member(e.household_id) then raise exception 'Not a household member'; end if;
  role_now := public.my_role(e.household_id);
  if role_now not in ('owner','admin') and e.user_id <> auth.uid() then raise exception 'Only the entry owner or admin can delete this'; end if;
  perform 1 from public.wallets where household_id=e.household_id for update;
  select fund into w from public.wallets where household_id=e.household_id;
  update public.wallets set fund=w+e.amount, updated_at=now() where household_id=e.household_id;
  insert into public.transactions(household_id,user_id,type,amount,balance_before,balance_after,transaction_date,note)
  values(e.household_id,auth.uid(),'expense_deleted',e.amount,w,w+e.amount,current_date,'Expense deleted');
  delete from public.expenses where id=e.id;
  return true;
end;$$;

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.wallets enable row level security;
alter table public.expenses enable row level security;
alter table public.transactions enable row level security;

drop policy if exists household_select on public.households;
create policy household_select on public.households for select using (public.is_member(id));
drop policy if exists members_select on public.household_members;
create policy members_select on public.household_members for select using (public.is_member(household_id));
drop policy if exists wallets_select on public.wallets;
create policy wallets_select on public.wallets for select using (public.is_member(household_id));
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select using (public.is_member(household_id));
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select using (public.is_member(household_id));

-- Only RPCs mutate financial data. Do not grant direct insert/update/delete to anon/authenticated.
revoke insert, update, delete on public.wallets from anon, authenticated;
revoke insert, update, delete on public.expenses from anon, authenticated;
revoke insert, update, delete on public.transactions from anon, authenticated;
grant execute on function public.create_household(text) to authenticated;
grant execute on function public.join_household(text) to authenticated;
grant execute on function public.change_wallet(uuid,text,numeric,date,text) to authenticated;
grant execute on function public.add_expense(uuid,text,numeric,text,date,boolean,text) to authenticated;
grant execute on function public.delete_expense(uuid) to authenticated;

do $$ begin
  insert into storage.buckets(id,name,public) values('bill-photos','bill-photos',true) on conflict(id) do nothing;
exception when others then null; end $$;

drop policy if exists bill_photos_read on storage.objects;
create policy bill_photos_read on storage.objects for select using (bucket_id='bill-photos');
drop policy if exists bill_photos_insert on storage.objects;
create policy bill_photos_insert on storage.objects for insert to authenticated with check (bucket_id='bill-photos');

-- Ghar Kharcha v10.1: visible edits (Superuser any date, Co-admin 50 days, Entry/Mamta 40 days), Superuser-only delete. Run ONCE after roles-guest.sql.
alter table public.expenses add column if not exists edit_count int not null default 0;
alter table public.expenses add column if not exists edited_at timestamptz;
create table if not exists public.expense_edits(id uuid primary key default gen_random_uuid(), household_id uuid not null references public.households(id) on delete cascade, expense_id uuid not null, user_id uuid, author text, edited_at timestamptz default now(), old_data jsonb, new_data jsonb);
alter table public.expense_edits enable row level security;
drop policy if exists edits_select on public.expense_edits; create policy edits_select on public.expense_edits for select using (public.is_member(household_id));

create or replace function public.edit_expense(p_id uuid, p_category text, p_amount numeric, p_note text, p_date date, p_has_bill boolean, p_cost_centre text)
returns void language plpgsql security definer set search_path=public as $$
declare e public.expenses; r text; w numeric; d numeric; o jsonb; n jsonb; lim int;
begin
  select * into e from public.expenses where id=p_id;
  if e.id is null then raise exception 'Entry nahi mili'; end if;
  r:=public.my_role(e.household_id);
  if r is null or p_amount is null or p_amount<=0 then raise exception 'Galat data'; end if;
  if r='admin' then lim:=50; elsif r='member' then lim:=40; elsif r<>'owner' then raise exception 'Edit ki permission nahi hai'; end if;
  if lim is not null and (e.expense_date < current_date-lim or p_date < current_date-lim) then raise exception 'Aap sirf pichhle % din ki entry badal sakte ho', lim; end if;
  o:=jsonb_build_object('category',e.category,'amount',e.amount,'note',e.note,'date',e.expense_date,'bill',e.has_bill,'cost_centre',e.cost_centre);
  n:=jsonb_build_object('category',p_category,'amount',p_amount,'note',coalesce(p_note,''),'date',p_date,'bill',coalesce(p_has_bill,false),'cost_centre',coalesce(nullif(p_cost_centre,''),'Household'));
  if o=n then return; end if;
  d:=p_amount-e.amount;
  if d<>0 then
    perform 1 from public.wallets where household_id=e.household_id for update;
    select fund into w from public.wallets where household_id=e.household_id;
    if d>0 and w<d then raise exception 'Fund mein paisa kam hai'; end if;
    update public.wallets set fund=w-d, updated_at=now() where household_id=e.household_id;
    insert into public.transactions(household_id,user_id,type,amount,balance_before,balance_after,transaction_date,note)
    values(e.household_id,auth.uid(),'expense_edit',abs(d),w,w-d,current_date,'Entry edit: '||left(coalesce(e.note,''),40));
  end if;
  update public.expenses set category=p_category,amount=p_amount,note=coalesce(p_note,''),expense_date=p_date,has_bill=coalesce(p_has_bill,false),cost_centre=coalesce(nullif(p_cost_centre,''),'Household'),edit_count=edit_count+1,edited_at=now() where id=p_id;
  insert into public.expense_edits(household_id,expense_id,user_id,author,old_data,new_data)
  values(e.household_id,p_id,auth.uid(),(select display_name from public.household_members where household_id=e.household_id and user_id=auth.uid()),o,n);
end;$$;
grant execute on function public.edit_expense(uuid,text,numeric,text,date,boolean,text) to authenticated;

create or replace function public.delete_expense(p_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare e public.expenses; w numeric;
begin
  select * into e from public.expenses where id=p_id;
  if e.id is null then raise exception 'Expense not found'; end if;
  if public.my_role(e.household_id) is distinct from 'owner' then raise exception 'Sirf Superuser delete kar sakta hai'; end if;
  perform 1 from public.wallets where household_id=e.household_id for update;
  select fund into w from public.wallets where household_id=e.household_id;
  update public.wallets set fund=w+e.amount, updated_at=now() where household_id=e.household_id;
  insert into public.transactions(household_id,user_id,type,amount,balance_before,balance_after,transaction_date,note)
  values(e.household_id,auth.uid(),'expense_deleted',e.amount,w,w+e.amount,current_date,'Deleted: '||left(coalesce(e.note,''),40));
  delete from public.expenses where id=e.id;
  return true;
end;$$;
grant execute on function public.delete_expense(uuid) to authenticated;

create or replace function public.guard_roles() returns trigger language plpgsql security definer set search_path=public as $$
declare h uuid; r text;
begin
  h:=(case when tg_op='DELETE' then old.household_id else new.household_id end);
  r:=public.my_role(h);
  if r='guest' then raise exception 'Guest sirf dekh sakta hai'; end if;
  if tg_op='DELETE' and tg_table_name='expenses' and r<>'owner' then raise exception 'Sirf Superuser delete kar sakta hai'; end if;
  return coalesce(new,old);
end;$$;

-- Cost-centre changes now follow the same edit rules (made through edit_expense), so close the old shortcut:
drop function if exists public.set_expense_cost_centre(uuid,text);

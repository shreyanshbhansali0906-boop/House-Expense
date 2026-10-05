-- Ghar Kharcha v11: automatic backup on the 1st and 16th of every month (about every 15 days).
-- Run ONCE in Supabase > SQL Editor.
create table if not exists public.backups(id uuid primary key default gen_random_uuid(), household_id uuid not null references public.households(id) on delete cascade, created_at timestamptz not null default now(), kind text not null default 'auto', data jsonb not null);
alter table public.backups enable row level security;
drop policy if exists backups_select on public.backups;
create policy backups_select on public.backups for select using (coalesce(public.my_role(household_id),'') in ('owner','admin'));

create or replace function public.snapshot_household(p_household uuid, p_kind text)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.backups(household_id,kind,data) values(p_household,p_kind,jsonb_build_object(
    'app','ghar-kharcha-online','taken_at',now(),
    'household',(select to_jsonb(h) from public.households h where h.id=p_household),
    'wallet',(select to_jsonb(w) from public.wallets w where w.household_id=p_household),
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',m.role,'display_name',m.display_name)) from public.household_members m where m.household_id=p_household),'[]'::jsonb),
    'expenses',coalesce((select jsonb_agg(to_jsonb(e) order by e.expense_date) from public.expenses e where e.household_id=p_household),'[]'::jsonb),
    'transactions',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from public.transactions t where t.household_id=p_household),'[]'::jsonb),
    'expense_edits',coalesce((select jsonb_agg(to_jsonb(x)) from public.expense_edits x where x.household_id=p_household),'[]'::jsonb),
    'suggestions',coalesce((select jsonb_agg(to_jsonb(s)) from public.suggestions s where s.household_id=p_household),'[]'::jsonb)));
  delete from public.backups where household_id=p_household and id not in (select id from public.backups where household_id=p_household order by created_at desc limit 12);
end;$$;
revoke all on function public.snapshot_household(uuid,text) from public, anon, authenticated;

create or replace function public.run_all_backups() returns void language plpgsql security definer set search_path=public as $$
declare h record;
begin for h in select id from public.households loop perform public.snapshot_household(h.id,'auto'); end loop; end;$$;
revoke all on function public.run_all_backups() from public, anon, authenticated;

create or replace function public.backup_now(p_household uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if coalesce(public.my_role(p_household),'') not in ('owner','admin') then raise exception 'Sirf admin backup le sakta hai'; end if;
  perform public.snapshot_household(p_household,'manual');
end;$$;
grant execute on function public.backup_now(uuid) to authenticated;

-- Schedule: 2:00 AM UTC (7:30 AM India) on the 1st and 16th. If this block shows a NOTICE, enable the pg_cron extension
-- in Supabase > Database > Extensions, then run only this block again. Manual "Backup abhi" works either way.
do $$ begin
  create extension if not exists pg_cron;
  begin perform cron.unschedule('ghar-backup'); exception when others then null; end;
  perform cron.schedule('ghar-backup','0 2 1,16 * *','select public.run_all_backups()');
exception when others then raise notice 'pg_cron not enabled yet: %', sqlerrm;
end $$;

select public.run_all_backups();  -- take the first backup right now

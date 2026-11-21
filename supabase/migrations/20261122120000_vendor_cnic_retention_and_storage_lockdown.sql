-- Queue rejected vendor CNIC data for deletion after 90 days and closed accounts after 90 days.
create table if not exists private.vendor_cnic_retention_queue(
 id uuid primary key default gen_random_uuid(), seller_profile_id uuid, user_id uuid not null,
 cnic_front_path text, cnic_back_path text,
 reason text not null check(reason in('rejected_application','account_closed')),
 scheduled_for timestamptz not null, next_attempt_at timestamptz not null default now(),
 status text not null default 'pending' check(status in('pending','processing','completed','cancelled')),
 attempts int not null default 0 check(attempts>=0), last_error text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), completed_at timestamptz
);
create index if not exists vendor_cnic_retention_due_idx on private.vendor_cnic_retention_queue(scheduled_for,next_attempt_at) where status='pending';
create unique index if not exists vendor_cnic_retention_active_profile_idx on private.vendor_cnic_retention_queue(seller_profile_id) where seller_profile_id is not null and status in('pending','processing');
alter table private.vendor_cnic_retention_queue enable row level security;
revoke all on private.vendor_cnic_retention_queue from public,anon,authenticated;
grant all on private.vendor_cnic_retention_queue to service_role;

create or replace function private.queue_vendor_cnic_retention()
returns trigger language plpgsql security definer set search_path=''
as $$
declare p public.seller_profiles%rowtype; due timestamptz; why text;
begin
 if tg_op='DELETE' then p:=old;due:=now()+interval '90 days';why:='account_closed';
 else
  p:=new;
  if new.status='rejected' then due:=coalesce(new.reviewed_at,now())+interval '90 days';why:='rejected_application';
  else
   update private.vendor_cnic_retention_queue set status='cancelled',updated_at=now() where seller_profile_id=new.id and status in('pending','processing');
   return new;
  end if;
 end if;
 insert into private.vendor_cnic_retention_queue(seller_profile_id,user_id,cnic_front_path,cnic_back_path,reason,scheduled_for,next_attempt_at,status,updated_at)
 values(p.id,p.user_id,p.cnic_front_path,p.cnic_back_path,why,due,now(),'pending',now())
 on conflict(seller_profile_id) where seller_profile_id is not null and status in('pending','processing')
 do update set user_id=excluded.user_id,cnic_front_path=excluded.cnic_front_path,cnic_back_path=excluded.cnic_back_path,
 reason=excluded.reason,scheduled_for=excluded.scheduled_for,next_attempt_at=now(),status='pending',attempts=0,last_error=null,updated_at=now();
 if tg_op='DELETE' then return old;end if;return new;
end $$;
drop trigger if exists seller_profiles_cnic_retention_update on public.seller_profiles;
create trigger seller_profiles_cnic_retention_update after update of status,reviewed_at,cnic_front_path,cnic_back_path on public.seller_profiles for each row execute function private.queue_vendor_cnic_retention();
drop trigger if exists seller_profiles_cnic_retention_delete on public.seller_profiles;
create trigger seller_profiles_cnic_retention_delete before delete on public.seller_profiles for each row execute function private.queue_vendor_cnic_retention();

insert into private.vendor_cnic_retention_queue(seller_profile_id,user_id,cnic_front_path,cnic_back_path,reason,scheduled_for,next_attempt_at)
select id,user_id,cnic_front_path,cnic_back_path,'rejected_application',coalesce(reviewed_at,updated_at,created_at)+interval '90 days',now()
from public.seller_profiles where status='rejected'
on conflict(seller_profile_id) where seller_profile_id is not null and status in('pending','processing')
do update set cnic_front_path=excluded.cnic_front_path,cnic_back_path=excluded.cnic_back_path,scheduled_for=excluded.scheduled_for,updated_at=now();

create or replace function public.validate_vendor_cnic_retention_cron_token(p_token text)
returns boolean language sql stable security definer set search_path=''
as $$ select coalesce(p_token,'')<>'' and exists(select 1 from vault.decrypted_secrets where name='vendor_cnic_retention_cron_token' and decrypted_secret=p_token) $$;
revoke all on function public.validate_vendor_cnic_retention_cron_token(text) from public,authenticated;
grant execute on function public.validate_vendor_cnic_retention_cron_token(text) to anon;

create or replace function public.claim_vendor_cnic_retention_batch(p_limit integer default 100)
returns table(queue_id uuid,seller_profile_id uuid,cnic_front_path text,cnic_back_path text)
language plpgsql security definer set search_path=''
as $$
begin
 return query with due as(
  select q.id from private.vendor_cnic_retention_queue q where q.status='pending' and q.scheduled_for<=now() and q.next_attempt_at<=now()
  order by q.scheduled_for,q.created_at for update skip locked limit greatest(1,least(coalesce(p_limit,100),500))
 ), claimed as(
  update private.vendor_cnic_retention_queue q set status='processing',attempts=q.attempts+1,updated_at=now()
  from due where q.id=due.id returning q.id,q.seller_profile_id,q.cnic_front_path,q.cnic_back_path
 ) select c.id,c.seller_profile_id,c.cnic_front_path,c.cnic_back_path from claimed c;
end $$;
create or replace function public.complete_vendor_cnic_retention_item(p_queue_id uuid,p_success boolean,p_error text default null)
returns boolean language plpgsql security definer set search_path=''
as $$
declare q private.vendor_cnic_retention_queue%rowtype;
begin
 select * into q from private.vendor_cnic_retention_queue where id=p_queue_id and status='processing' for update;
 if not found then return false;end if;
 if p_success then
  if q.seller_profile_id is not null then
   update public.seller_profiles set cnic_number=null,cnic_front_path=null,cnic_back_path=null,updated_at=now()
   where id=q.seller_profile_id and cnic_front_path is not distinct from q.cnic_front_path and cnic_back_path is not distinct from q.cnic_back_path;
  end if;
  update private.vendor_cnic_retention_queue set status='completed',cnic_front_path=null,cnic_back_path=null,last_error=null,completed_at=now(),updated_at=now() where id=p_queue_id;
 else
  update private.vendor_cnic_retention_queue set status='pending',next_attempt_at=now()+interval '1 day',last_error=left(coalesce(p_error,'Storage deletion failed'),500),updated_at=now() where id=p_queue_id;
 end if;return true;
end $$;
revoke all on function public.claim_vendor_cnic_retention_batch(integer) from public,anon,authenticated;
revoke all on function public.complete_vendor_cnic_retention_item(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.claim_vendor_cnic_retention_batch(integer) to service_role;
grant execute on function public.complete_vendor_cnic_retention_item(uuid,boolean,text) to service_role;

do $$ begin
 if not exists(select 1 from vault.secrets where name='vendor_cnic_retention_cron_token') then
  perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'vendor_cnic_retention_cron_token','Private token for scheduled vendor CNIC cleanup',null);
 end if;
 if not exists(select 1 from vault.secrets where name='jtbazar_project_url') then
  perform vault.create_secret('https://xrrhbnnzjqkqnqdvayjw.supabase.co','jtbazar_project_url','JTBazar Supabase URL for scheduled maintenance',null);
 end if;
 if not exists(select 1 from vault.secrets where name='jtbazar_publishable_key') then
  perform vault.create_secret('sb_publishable_fBu4PTDFMxgcNZ8luVkpOQ_lIIbZUHI','jtbazar_publishable_key','Public API key for scheduled function gateway',null);
 end if;
end $$;
select cron.schedule('jtbazar-vendor-cnic-retention-daily','0 2 * * *',$job$
 select net.http_post(
  url:=(select decrypted_secret from vault.decrypted_secrets where name='jtbazar_project_url')||'/functions/v1/vendor-cnic-retention-cleanup',
  headers:=jsonb_build_object('Content-Type','application/json','apikey',(select decrypted_secret from vault.decrypted_secrets where name='jtbazar_publishable_key'),'x-cron-token',(select decrypted_secret from vault.decrypted_secrets where name='vendor_cnic_retention_cron_token')),
  body:=jsonb_build_object('source','pg_cron')
 );
$job$);

-- Vendors may read their own documents; administrators use the audited Edge Function.
drop policy if exists vendor_documents_admin_read on storage.objects;
drop policy if exists vendor_documents_owner_or_admin_read on storage.objects;
drop policy if exists vendor_documents_admin_delete on storage.objects;

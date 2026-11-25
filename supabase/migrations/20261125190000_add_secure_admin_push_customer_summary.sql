create or replace function public.admin_push_customer_summary()
returns table(
  id uuid,
  full_name text,
  phone text,
  avatar_url text,
  email text,
  order_count bigint,
  lifetime_value numeric,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null and (auth.jwt() ->> 'role') is distinct from 'service_role' then
    raise exception using errcode = '42501', message = 'Authentication is required.';
  end if;

  if (auth.jwt() ->> 'role') is distinct from 'service_role'
     and (auth.jwt() ->> 'aal') is distinct from 'aal2'
     and (private.has_role('admin'::public.app_role) or private.has_verified_totp_factor()) then
    raise exception using errcode = '42501', message = 'JTBazar authenticator verification is required.';
  end if;

  if (auth.jwt() ->> 'role') is distinct from 'service_role'
     and not private.has_role('admin'::public.app_role) then
    raise exception using errcode = '42501', message = 'Administrator access is required.';
  end if;

  return query
  select p.id,
         p.full_name,
         p.phone,
         p.avatar_url,
         u.email::text,
         coalesce((select count(*) from public.orders o where o.customer_id = p.id), 0)::bigint,
         coalesce((select sum(o.total) from public.orders o
                   where o.customer_id = p.id
                     and o.order_status = 'delivered'::public.order_status
                     and o.payment_status = 'paid'::public.payment_status), 0)::numeric,
         p.created_at,
         p.updated_at
  from public.profiles p
  join auth.users u on u.id = p.id
  join public.user_roles ur on ur.user_id = p.id
  where ur.role = 'customer'::public.app_role
  order by p.created_at desc
  limit 5000;
end;
$function$;

revoke all on function public.admin_push_customer_summary() from public, anon;
grant execute on function public.admin_push_customer_summary() to authenticated, service_role;

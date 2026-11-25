create or replace function private.assign_notification_audience()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.audience := case
    when new.title in (
      'New seller application',
      'Product listing needs review',
      'Marketplace case opened',
      'New seller support ticket',
      'New customer support ticket'
    )
      or (new.title like 'New order %' and new.title not like 'New order for %') then 'admin'
    when new.title in (
      'New delivery assigned',
      'Driver application approved',
      'Driver application rejected',
      'Driver access suspended',
      'Driver access enabled',
      'Driver access disabled'
    ) then 'driver'
    when new.title like 'New order for %' or new.title like 'Order % cancelled' then 'vendor'
    else 'customer'
  end;
  return new;
end;
$$;

create or replace function private.notify_customer_driver_access_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text;
  v_body text;
begin
  if tg_op = 'INSERT' then
    if not new.enabled then
      return new;
    end if;
  elsif old.enabled is not distinct from new.enabled then
    return new;
  end if;

  if new.enabled then
    v_title := 'Driver access enabled';
    v_body := 'Your JTBazar Driver access has been enabled. You can now open Driver Center and submit your driver application.';
  else
    v_title := 'Driver access disabled';
    v_body := 'Your JTBazar Driver access has been disabled by the JTBazar team. If you believe this is a mistake, please contact support.';
  end if;

  insert into public.notifications(user_id, kind, title, body)
  values (new.user_id, 'account'::public.notification_kind, v_title, v_body);

  return new;
end;
$$;

drop trigger if exists customer_driver_access_push_status on public.customer_driver_access;
create trigger customer_driver_access_push_status
after insert or update of enabled
on public.customer_driver_access
for each row
execute function private.notify_customer_driver_access_status();

revoke all on function private.notify_customer_driver_access_status() from public, anon, authenticated;

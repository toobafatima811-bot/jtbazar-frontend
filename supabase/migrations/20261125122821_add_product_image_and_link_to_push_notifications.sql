-- Support image-rich product broadcasts through the existing notification inbox and FCM pipeline.
alter table public.notifications
  add column if not exists image_url text,
  add column if not exists link_url text;

create or replace function private.dispatch_notification_push()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_payload jsonb; v_secret text; v_signature text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='jtbazar_push_webhook_secret' limit 1;
  if v_secret is null then
    raise warning 'JTBazar push webhook secret is missing; notification % remains in-app only',new.id;
    return new;
  end if;
  v_payload:=jsonb_build_object(
    'action','webhook',
    'user_id',new.user_id,
    'title',new.title,
    'body',new.body,
    'image_url',new.image_url,
    'link',coalesce(new.link_url,case when new.related_order_id is not null then 'https://www.jt-bazar.com/account' else 'https://www.jt-bazar.com/' end),
    'data',jsonb_build_object(
      'notification_id',new.id,
      'kind',new.kind,
      'audience',new.audience,
      'related_order_id',new.related_order_id
    )
  );
  v_signature:=encode(extensions.hmac(v_payload::text,v_secret,'sha256'),'hex');
  perform net.http_post(
    url:='https://xrrhbnnzjqkqnqdvayjw.supabase.co/functions/v1/firebase-push-notifications',
    headers:=jsonb_build_object(
      'Content-Type','application/json',
      'apikey','sb_publishable_fBu4PTDFMxgcNZ8luVkpOQ_lIIbZUHI',
      'x-jtbazar-signature',v_signature
    ),
    body:=v_payload
  );
  return new;
end;
$$;

revoke all on function private.dispatch_notification_push() from public,anon,authenticated;

-- Keep campaign form selections consistent at the database boundary.
-- Launch popups are only popups when show_on_launch is enabled.
-- All other promotions are homepage banners with a valid placement.
create or replace function public.normalize_launch_promotion()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(new.show_on_launch, false) then
    new.campaign_type := 'popup';
    new.display_position := null;
  else
    new.campaign_type := 'banner';
    if new.display_position is null then
      new.display_position := 'hero_banner';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists promotions_normalize_launch_promotion on public.promotions;
create trigger promotions_normalize_launch_promotion
before insert or update of show_on_launch, campaign_type, display_position
on public.promotions
for each row
execute function public.normalize_launch_promotion();

-- Allow the dedicated mobile app promotion placement used by the homepage.
-- Keep all existing supported promotion positions unchanged.
alter table public.promotions
  drop constraint if exists promotions_display_position_check;

alter table public.promotions
  add constraint promotions_display_position_check
  check (
    display_position is null
    or display_position = any (array[
      'hero_banner',
      'top_promo',
      'category_feature',
      'product_strip',
      'offer_section',
      'seller_banner',
      'app_download_banner'
    ]::text[])
  );

-- ============================================================
-- إعداد قاعدة بيانات App Shop على Supabase
-- الخطوات: Supabase > SQL Editor > New query > الصق الملف كله > Run
-- آمن لإعادة التشغيل (شغّله تاني بعد أي تحديث). كود الإدارة اللي غيّرته لا يتأثر.
-- ============================================================

create table if not exists store (
  id int primary key default 1,
  data jsonb not null default '{}'::jsonb,
  check (id = 1)
);
create table if not exists store_secret (
  id int primary key default 1,
  admin_hash text not null,
  check (id = 1)
);
-- الطلبات: لا أحد يقرأها مباشرة، القراءة للأدمن فقط من خلال list_orders
create table if not exists orders (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  customer jsonb not null,
  items jsonb not null,
  delivery_name text,
  delivery_fee numeric not null default 0,
  total numeric not null,
  method text,
  kind text not null,
  note text default '',
  status text not null default 'new',
  token text not null,
  session_url text,
  restocked boolean not null default false
);

alter table store enable row level security;
alter table store_secret enable row level security;
alter table orders enable row level security;

drop policy if exists "public read store" on store;
create policy "public read store" on store for select using (true);

insert into store (id, data) values (1, '{}') on conflict (id) do nothing;
insert into store_secret (id, admin_hash) values (1, '674eeaa6e6454efc59ca2cd0692647315f6bd2398e73af5a6cd003dad0b912e9') on conflict (id) do nothing;

create or replace function check_admin(p_hash text) returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from store_secret where id = 1 and admin_hash = p_hash);
$$;

-- حفظ بيانات المتجر من لوحة الإدارة (المخزون الحالي يحتفظ به السيرفر إلا للمنتجات اللي الأدمن غيّر مخزونها)
drop function if exists save_store(text, jsonb);
drop function if exists save_store(text, jsonb, jsonb);
create function save_store(p_hash text, p_data jsonb, p_dirty jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cur jsonb; newp jsonb := '[]'::jsonb; item jsonb; np jsonb; oldp jsonb;
begin
  if not check_admin(p_hash) then raise exception 'unauthorized'; end if;
  select data into cur from store where id = 1 for update;
  for item in select * from jsonb_array_elements(coalesce(p_data->'products', '[]'::jsonb)) loop
    np := item;
    if not (p_dirty @> jsonb_build_array(item->'id')) then
      oldp := null;
      select e into oldp from jsonb_array_elements(coalesce(cur->'products', '[]'::jsonb)) e
        where e->'id' = item->'id' limit 1;
      if oldp is not null then
        np := jsonb_set(item, '{stock}', coalesce(oldp->'stock', '0'::jsonb));
      end if;
    end if;
    newp := newp || jsonb_build_array(np);
  end loop;
  p_data := jsonb_set(p_data, '{products}', newp);
  insert into store (id, data) values (1, p_data)
  on conflict (id) do update set data = excluded.data;
  return p_data;
end $$;

create or replace function change_admin(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not check_admin(p_old) then raise exception 'unauthorized'; end if;
  update store_secret set admin_hash = p_new where id = 1;
end $$;

-- ---------- المخزون والطلبات ----------

-- إرجاع كميات طلب للمخزون (داخلية فقط)
create or replace function restock_items(p_items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d jsonb; prods jsonb; item jsonb; i int;
begin
  select data into d from store where id = 1 for update;
  prods := coalesce(d->'products', '[]'::jsonb);
  for item in select * from jsonb_array_elements(p_items) loop
    for i in 0 .. jsonb_array_length(prods) - 1 loop
      if prods->i->'id' = item->'id' then
        prods := jsonb_set(prods, array[i::text, 'stock'],
          to_jsonb(coalesce((prods->i->>'stock')::int, 0) + (item->>'qty')::int));
        exit;
      end if;
    end loop;
  end loop;
  update store set data = jsonb_set(d, '{products}', prods) where id = 1;
end $$;

-- طلبات الدفع الإلكتروني اللي مدتها عدّت 90 دقيقة بدون دفع: تُلغى وترجع كمياتها
create or replace function sweep_awaiting() returns void
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  for o in select id, items from orders
           where status = 'awaiting_payment' and created_at < now() - interval '90 minutes' for update loop
    perform restock_items(o.items);
    update orders set status = 'cancelled', restocked = true where id = o.id;
  end loop;
end $$;

-- تسجيل طلب العميل: يحسب السعر والتوصيل من بيانات المتجر على السيرفر (مش من المتصفح)
-- ويخصم المخزون لكل طرق الدفع (يدوي / عند الاستلام / إلكتروني)
drop function if exists place_order(jsonb);
drop function if exists place_order(jsonb, jsonb, bigint, text, text, text);
create function place_order(p_items jsonb, p_customer jsonb, p_delivery bigint, p_method text, p_kind text, p_note text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d jsonb; prods jsonb; item jsonb; i int; hit boolean; pid text; q int; cur int;
  lines jsonb := '[]'::jsonb; sub numeric := 0; price numeric; pname text;
  dl jsonb; dsel jsonb; dfee numeric := 0; dname text; fo numeric; tok text; oid bigint; tot numeric;
  cust jsonb;
begin
  perform sweep_awaiting();
  if p_kind not in ('cod', 'manual', 'kashier') then raise exception 'bad_kind'; end if;
  if coalesce(trim(p_customer->>'name'), '') = '' or coalesce(trim(p_customer->>'phone'), '') = '' then
    raise exception 'bad_customer';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_cart';
  end if;

  select data into d from store where id = 1 for update;
  if d is null then raise exception 'store_empty'; end if;
  prods := coalesce(d->'products', '[]'::jsonb);
  if p_kind = 'kashier' and coalesce((d->'settings'->>'kashierOn')::boolean, false) = false then
    raise exception 'kashier_disabled';
  end if;

  for item in select * from jsonb_array_elements(p_items) loop
    pid := item->>'id';
    q := (item->>'qty')::int;
    if q is null or q < 1 or q > 1000 then raise exception 'bad_qty'; end if;
    hit := false;
    for i in 0 .. jsonb_array_length(prods) - 1 loop
      if prods->i->>'id' = pid then
        cur := coalesce((prods->i->>'stock')::int, 0);
        pname := coalesce(prods->i->>'name', pid);
        if cur < q then raise exception 'out_of_stock:%', pname; end if;
        price := coalesce((prods->i->>'price')::numeric, 0);
        prods := jsonb_set(prods, array[i::text, 'stock'], to_jsonb(cur - q));
        sub := sub + price * q;
        lines := lines || jsonb_build_array(jsonb_build_object('id', prods->i->'id', 'name', pname, 'price', price, 'qty', q));
        hit := true;
        exit;
      end if;
    end loop;
    if not hit then raise exception 'not_found:%', pid; end if;
  end loop;

  -- التوصيل (لو الأدمن لم يحفظ إعداداته بعد: القيم الافتراضية نفسها اللي في الواجهة)
  dl := d->'delivery';
  if dl is null or jsonb_typeof(dl) <> 'array' then
    dl := jsonb_build_array(
      jsonb_build_object('id', 1, 'name', 'توصيل للمنزل', 'fee', coalesce(nullif((d->'settings'->>'shipping')::numeric, 0), 50), 'needAddr', true, 'on', true),
      jsonb_build_object('id', 2, 'name', 'استلام من المتجر', 'fee', 0, 'needAddr', false, 'on', true));
  end if;
  select x into dsel from jsonb_array_elements(dl) x
    where (x->>'id')::bigint = p_delivery and coalesce((x->>'on')::boolean, false) limit 1;
  if dsel is null then raise exception 'bad_delivery'; end if;
  dname := dsel->>'name';
  dfee := coalesce((dsel->>'fee')::numeric, 0);
  fo := coalesce((d->'settings'->>'freeOver')::numeric, 0);
  if fo > 0 and sub >= fo then dfee := 0; end if;
  if coalesce((dsel->>'needAddr')::boolean, false) and coalesce(trim(p_customer->>'addr'), '') = '' then
    raise exception 'bad_address';
  end if;

  tot := sub + dfee;
  tok := gen_random_uuid()::text;
  cust := jsonb_build_object('name', left(trim(p_customer->>'name'), 100),
                             'phone', left(trim(p_customer->>'phone'), 20),
                             'addr', left(coalesce(trim(p_customer->>'addr'), ''), 300));
  insert into orders (customer, items, delivery_name, delivery_fee, total, method, kind, note, status, token)
  values (cust, lines, dname, dfee, tot, left(coalesce(p_method, ''), 100), p_kind, left(coalesce(p_note, ''), 200),
          case when p_kind = 'kashier' then 'awaiting_payment' else 'new' end, tok)
  returning id into oid;

  d := jsonb_set(d, '{products}', prods);
  update store set data = d where id = 1;
  return jsonb_build_object('order_id', oid, 'token', tok, 'order_no', 'AS-' || oid, 'fee', dfee, 'total', tot,
                            'data', jsonb_build_object('products', prods));
end $$;

-- العميل يلغي طلبه (لو تعذر فتح صفحة الدفع الإلكتروني) وترجع الكميات
create or replace function cancel_my_order(p_id bigint, p_token text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype;
begin
  select * into o from orders where id = p_id and token = p_token for update;
  if found and o.status = 'awaiting_payment' then
    perform restock_items(o.items);
    update orders set status = 'cancelled', restocked = true where id = p_id;
  end if;
end $$;

-- تُستدعى من دالة kashier (service role فقط): فشل الدفع
create or replace function internal_cancel_order(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype;
begin
  select * into o from orders where id = p_id for update;
  if found and o.status = 'awaiting_payment' then
    perform restock_items(o.items);
    update orders set status = 'cancelled', restocked = true where id = p_id;
  end if;
end $$;

-- قائمة الطلبات للأدمن (بدون التوكن)
create or replace function list_orders(p_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not check_admin(p_hash) then raise exception 'unauthorized'; end if;
  perform sweep_awaiting();
  return coalesce((select jsonb_agg(to_jsonb(o) - 'token' - 'session_url' order by o.id desc)
                   from (select * from orders order by id desc limit 200) o), '[]'::jsonb);
end $$;

-- تغيير حالة طلب (الإلغاء يرجّع الكميات للمخزون)
create or replace function admin_set_order(p_hash text, p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders%rowtype;
begin
  if not check_admin(p_hash) then raise exception 'unauthorized'; end if;
  if p_status not in ('new', 'paid', 'delivered', 'cancelled') then raise exception 'bad_status'; end if;
  select * into o from orders where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if o.status = 'cancelled' then raise exception 'already_cancelled'; end if;
  if p_status = 'cancelled' and not o.restocked then perform restock_items(o.items); end if;
  update orders set status = p_status, restocked = (restocked or p_status = 'cancelled') where id = p_id;
end $$;

-- الصلاحيات: الدوال الداخلية مقفولة، والباقي متاح للمتصفح (والأدمن محمي بالكود)
revoke all on function restock_items(jsonb) from public, anon, authenticated;
revoke all on function sweep_awaiting() from public, anon, authenticated;
revoke all on function internal_cancel_order(bigint) from public, anon, authenticated;
grant execute on function internal_cancel_order(bigint) to service_role;
grant execute on function check_admin(text) to anon;
grant execute on function save_store(text, jsonb, jsonb) to anon;
grant execute on function change_admin(text, text) to anon;
grant execute on function place_order(jsonb, jsonb, bigint, text, text, text) to anon;
grant execute on function cancel_my_order(bigint, text) to anon;
grant execute on function list_orders(text) to anon;
grant execute on function admin_set_order(text, bigint, text) to anon;

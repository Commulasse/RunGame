-- =====================================================================
-- RunGame – databáze pro Supabase
-- Vlož celé do Supabase → SQL Editor → New query → Run.
-- Skript jde spustit znovu (nic nesmaže, jen doplní / přepíše funkce).
-- =====================================================================

-- ---------- profily běžců (1:1 k auth.users) ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  name        text not null default '',
  nick        text not null default '',
  year        int,
  team        text,
  street      text,
  city        text,
  zip         text,
  news        boolean not null default false,
  role        text not null default 'runner' check (role in ('runner','admin')),
  created_at  timestamptz not null default now()
);

-- ---------- závody ----------
-- Celý objekt závodu (vzhled karty, popis, tratě…) je v "data".
-- Sloupce kind/f/e/up jsou kopie kvůli kontrolám a dotazům.
create table if not exists public.events (
  id          text primary key,
  kind        text not null check (kind in ('run','challenge')),
  f           date not null,
  e           date not null,
  up          date not null,
  data        jsonb not null,
  updated_at  timestamptz not null default now()
);

-- ---------- registrace ----------
create sequence if not exists public.bib_seq start 1001;

create table if not exists public.regs (
  id          text primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  race        text not null references public.events(id) on delete restrict,
  dist        numeric(7,2) not null check (dist > 0),
  nick        text not null default '',
  pack        text not null default 'start',
  extra       text,
  pay         text not null default 'bank',
  price       int  not null default 0,
  paid        boolean not null default false,
  paid_at     timestamptz,
  bib         int  not null,
  vs          text,
  at          date not null default current_date,
  act_id      text,
  otime       text,
  created_at  timestamptz not null default now(),
  unique (user_id, race, dist)
);
create unique index if not exists regs_bib_uq on public.regs(bib);

-- ---------- běhy (deník) ----------
create table if not exists public.acts (
  id          text primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  date        date not null,
  km          numeric(8,2) not null check (km > 0 and km < 400),
  time        text not null check (time ~ '^\d{1,3}:[0-5]\d:[0-5]\d$'),
  img         text,          -- cesta ve Storage (bucket proofs) nebo null
  file        text,
  link        text,
  source      text not null default 'screen',
  trk         jsonb,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  note        text,
  reg_id      text references public.regs(id) on delete set null,
  excl        text[] not null default '{}',
  created_at  timestamptz not null default now()
);
create index if not exists acts_user_idx on public.acts(user_id, date);

-- reg.act_id → acts (přidáno až teď, kvůli pořadí tabulek)
do $$ begin
  alter table public.regs add constraint regs_act_fk foreign key (act_id) references public.acts(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ---------- pomocné funkce ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

-- Startovné podle druhu závodu (jednorázový 249 Kč, dlouhý 349 Kč).
-- Ceny měň jen tady (a v config.js na webu).
create or replace function public.fee_for(p_race text) returns int
language sql stable security definer set search_path = public as $$
  select case when kind = 'challenge' then 349 else 249 end from public.events where id = p_race
$$;

-- ---------- nový uživatel → profil ----------
create or replace function public.on_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, email, name, nick, year, team, news)
  values (new.id, lower(new.email),
          coalesce(new.raw_user_meta_data->>'name',''),
          coalesce(new.raw_user_meta_data->>'nick',''),
          nullif(new.raw_user_meta_data->>'year','')::int,
          nullif(new.raw_user_meta_data->>'team',''),
          coalesce((new.raw_user_meta_data->>'news')::boolean,false))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.on_auth_user();

-- ---------- ochrana: co nesmí měnit běžec ----------
create or replace function public.guard_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := coalesce(old.role, 'runner');
    new.email := coalesce(old.email, new.email);
    new.id := coalesce(old.id, new.id);
  end if;
  return new;
end $$;
drop trigger if exists guard_profiles on public.profiles;
create trigger guard_profiles before insert or update on public.profiles
  for each row execute function public.guard_profiles();

create or replace function public.guard_regs() returns trigger
language plpgsql security definer set search_path = public as $$
declare ev public.events; a public.acts;
begin
  select * into ev from public.events where id = new.race;
  if tg_op = 'INSERT' then
    if auth.uid() is not null and not public.is_admin() then
      new.user_id := auth.uid();
      new.paid := false; new.paid_at := null;
      new.act_id := null; new.otime := null;
      new.at := current_date;
      if current_date > ev.e then raise exception 'Registrace do tohoto závodu už skončila'; end if;
      if ev.kind = 'challenge' then new.dist := (ev.data->'km'->>0)::numeric; end if;
      if not (ev.data->'km') @> to_jsonb(new.dist) and not (ev.data->'km') @> to_jsonb(new.dist::int) then
        raise exception 'Neplatná trať';
      end if;
    end if;
    if new.bib is null or (auth.uid() is not null and not public.is_admin()) then new.bib := nextval('public.bib_seq'); end if;
    new.price := coalesce(public.fee_for(new.race), 0);
    new.pay := 'bank';
    new.vs := new.bib::text;
  else
    if auth.uid() is not null and not public.is_admin() then
      -- běžec smí měnit jen přezdívku a přiřazení běhu
      new.user_id := old.user_id; new.race := old.race; new.dist := old.dist;
      new.price := old.price; new.paid := old.paid; new.paid_at := old.paid_at;
      new.bib := old.bib; new.vs := old.vs; new.at := old.at; new.pay := old.pay; new.pack := old.pack;
      if new.act_id is not null then
        select * into a from public.acts where id = new.act_id;
        if a.user_id is distinct from old.user_id then raise exception 'Cizí běh'; end if;
      end if;
    end if;
    if new.paid and not old.paid then new.paid_at := now(); end if;
    if not new.paid then new.paid_at := null; end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_regs on public.regs;
create trigger guard_regs before insert or update on public.regs
  for each row execute function public.guard_regs();

create or replace function public.guard_acts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.status := 'pending'; new.note := null;
    if new.date > current_date then raise exception 'Běh nemůže být v budoucnu'; end if;
  else
    new.user_id := old.user_id;
    if old.status = 'approved' then
      -- schválený běh už běžec měnit nesmí (jen vyloučení z dlouhých závodů)
      new.date := old.date; new.km := old.km; new.time := old.time; new.img := old.img;
      new.status := old.status; new.note := old.note; new.reg_id := old.reg_id;
    else
      if new.status <> old.status then new.status := 'pending'; end if;
      if old.status = 'rejected' then new.status := 'pending'; end if;
      new.note := old.note;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_acts on public.acts;
create trigger guard_acts before insert or update on public.acts
  for each row execute function public.guard_acts();

create or replace function public.guard_acts_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() and old.status = 'approved' then
    raise exception 'Schválený běh nejde smazat';
  end if;
  return old;
end $$;
drop trigger if exists guard_acts_delete on public.acts;
create trigger guard_acts_delete before delete on public.acts
  for each row execute function public.guard_acts_delete();

create or replace function public.touch_events() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists touch_events on public.events;
create trigger touch_events before update on public.events
  for each row execute function public.touch_events();

-- ---------- pravidla přístupu (RLS) ----------
alter table public.profiles enable row level security;
alter table public.events   enable row level security;
alter table public.regs     enable row level security;
alter table public.acts     enable row level security;

drop policy if exists p_profiles_sel on public.profiles;
drop policy if exists p_profiles_upd on public.profiles;
drop policy if exists p_profiles_adm on public.profiles;
create policy p_profiles_sel on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy p_profiles_upd on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy p_profiles_adm on public.profiles for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_events_sel on public.events;
drop policy if exists p_events_adm on public.events;
create policy p_events_sel on public.events for select using (true);
create policy p_events_adm on public.events for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_regs_sel on public.regs;
drop policy if exists p_regs_ins on public.regs;
drop policy if exists p_regs_upd on public.regs;
drop policy if exists p_regs_adm on public.regs;
create policy p_regs_sel on public.regs for select using (user_id = auth.uid() or public.is_admin());
create policy p_regs_ins on public.regs for insert with check (auth.uid() is not null);
create policy p_regs_upd on public.regs for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy p_regs_adm on public.regs for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_acts_sel on public.acts;
drop policy if exists p_acts_ins on public.acts;
drop policy if exists p_acts_upd on public.acts;
drop policy if exists p_acts_del on public.acts;
drop policy if exists p_acts_adm on public.acts;
create policy p_acts_sel on public.acts for select using (user_id = auth.uid() or public.is_admin());
create policy p_acts_ins on public.acts for insert with check (auth.uid() is not null);
create policy p_acts_upd on public.acts for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy p_acts_del on public.acts for delete using (user_id = auth.uid());
create policy p_acts_adm on public.acts for all using (public.is_admin()) with check (public.is_admin());

-- ---------- veřejné výsledky (bez jmen, e-mailů a screenshotů) ----------
create or replace view public.pub_regs as
  select r.id, r.user_id, r.race, r.dist, coalesce(nullif(r.nick,''), nullif(p.nick,''), 'Běžec ' || r.bib) as nick,
         r.paid, r.bib, r.at, r.act_id, r.otime
  from public.regs r join public.profiles p on p.id = r.user_id
  where r.paid;
create or replace view public.pub_acts as
  select a.id, a.user_id, a.date, a.km, a.time, a.status, a.reg_id, a.excl
  from public.acts a
  where a.status in ('approved','pending')
    and exists (select 1 from public.regs r where r.user_id = a.user_id and r.paid);

revoke all on public.pub_regs, public.pub_acts from anon, authenticated;
grant select on public.pub_regs, public.pub_acts to anon, authenticated;
grant select on public.events to anon, authenticated;
grant select, insert, update, delete on public.profiles, public.events, public.regs, public.acts to authenticated;
grant usage on sequence public.bib_seq to authenticated;

-- ---------- úložiště souborů ----------
-- proofs = screenshoty běhů (soukromé), events = obrázky závodů (veřejné)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proofs','proofs', false, 3145728, array['image/jpeg','image/png','image/webp']),
       ('events','events', true,  3145728, array['image/jpeg','image/png','image/webp','image/svg+xml'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists rg_proofs_own on storage.objects;
drop policy if exists rg_proofs_adm on storage.objects;
drop policy if exists rg_events_adm on storage.objects;
create policy rg_proofs_own on storage.objects for all to authenticated
  using (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy rg_proofs_adm on storage.objects for all to authenticated
  using (bucket_id = 'proofs' and public.is_admin())
  with check (bucket_id = 'proofs' and public.is_admin());
create policy rg_events_adm on storage.objects for all to authenticated
  using (bucket_id = 'events' and public.is_admin())
  with check (bucket_id = 'events' and public.is_admin());

-- ---------- e-maily (nepovinné, přes Brevo) ----------
-- Funguje, až v Supabase zapneš rozšíření pg_net (Database → Extensions → pg_net)
-- a uložíš klíč: select vault.create_secret('xkeysib-…', 'brevo_key');
create or replace function public.rg_mail(p_to text, p_subject text, p_html text) returns void
language plpgsql security definer set search_path = public as $$
declare k text;
begin
  begin
    select decrypted_secret into k from vault.decrypted_secrets where name = 'brevo_key' limit 1;
  exception when others then return; end;
  if k is null or p_to is null then return; end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', k, 'content-type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name','RunGame','email','info@rungame.cz'),
      'to', jsonb_build_array(jsonb_build_object('email', p_to)),
      'subject', p_subject,
      'htmlContent', p_html));
exception when others then
  raise warning 'rg_mail: %', sqlerrm;
end $$;

create or replace function public.rg_mail_regs() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.profiles; ev public.events; n text; acc text;
begin
  select * into p from public.profiles where id = new.user_id;
  select * into ev from public.events where id = new.race;
  n := coalesce(ev.data->>'n', new.race);
  begin
    select decrypted_secret into acc from vault.decrypted_secrets where name = 'bank_account' limit 1;
  exception when others then acc := null; end;
  acc := coalesce(acc, '(číslo účtu najdeš ve svém účtu na rungame.cz)');
  if tg_op = 'INSERT' then
    perform public.rg_mail(p.email, 'RunGame: startovní číslo ' || new.bib || ' – ' || n,
      '<h2>Jsi na startu: ' || n || '</h2><p>Tvoje startovní číslo je <b>' || new.bib || '</b>, trať ' || new.dist || ' km.</p>'
      || '<p>Startovné <b>' || new.price || ' Kč</b> pošli do 5 dnů na účet <b>' || acc || '</b> s variabilním symbolem <b>' || new.vs || '</b>. QR platbu najdeš ve svém účtu na <a href="https://rungame.cz/#ucet">rungame.cz</a>.</p>'
      || '<p>Nahraná data ručně kontrolujeme. Když nesedí, běh ti vrátíme k doplnění.</p><p>Tým RunGame</p>');
  elsif new.paid and not old.paid then
    perform public.rg_mail(p.email, 'RunGame: platba přijata – ' || n,
      '<h2>Platba dorazila</h2><p>Registrace do závodu ' || n || ' platí. Startovní číslo <b>' || new.bib || '</b>.</p>'
      || '<p>Výsledek nahraj ve svém účtu na <a href="https://rungame.cz/#ucet">rungame.cz</a>.</p><p>Tým RunGame</p>');
  end if;
  return new;
end $$;
drop trigger if exists rg_mail_regs on public.regs;
create trigger rg_mail_regs after insert or update of paid on public.regs
  for each row execute function public.rg_mail_regs();

create or replace function public.rg_mail_acts() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  if new.status = old.status then return new; end if;
  select * into p from public.profiles where id = new.user_id;
  if new.status = 'approved' then
    perform public.rg_mail(p.email, 'RunGame: běh ' || to_char(new.date,'DD. MM. YYYY') || ' je schválený',
      '<p>Tvůj běh ' || new.km || ' km za ' || new.time || ' jsme zkontrolovali a schválili.</p><p>Diplom po splnění závodu najdeš ve svém účtu na <a href="https://rungame.cz/#ucet">rungame.cz</a>.</p><p>Tým RunGame</p>');
  elsif new.status = 'rejected' then
    perform public.rg_mail(p.email, 'RunGame: běh potřebuje doplnit',
      '<p>Tvůj běh ' || to_char(new.date,'DD. MM. YYYY') || ' jsme vrátili k doplnění.</p><p>Poznámka: ' || coalesce(new.note,'—') || '</p><p>Uprav ho ve svém účtu na <a href="https://rungame.cz/#ucet">rungame.cz</a>.</p><p>Tým RunGame</p>');
  end if;
  return new;
end $$;
drop trigger if exists rg_mail_acts on public.acts;
create trigger rg_mail_acts after update of status on public.acts
  for each row execute function public.rg_mail_acts();

-- =====================================================================
-- Po prvním přihlášení na webu se udělej adminem (e-mail změň na svůj):
--   update public.profiles set role = 'admin' where email = 'tvuj@email.cz';
-- =====================================================================

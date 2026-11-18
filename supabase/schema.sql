-- =====================================================================
--  AA HR Group — Supabase schema
--  Ascend Advisory Group · HR & Admin · Leave Application System
--
--  Run this whole file once in Supabase Dashboard → SQL Editor → New query.
--  Safe to re-run: tables use IF NOT EXISTS, functions use OR REPLACE.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  email       text not null,
  staff_no    text,
  department  text,
  position    text,
  phone       text,
  join_date   date,
  role        text not null default 'staff' check (role in ('staff', 'director', 'admin')),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.leave_types (
  id                  serial primary key,
  code                text unique not null,
  name                text not null,
  default_days        numeric(5,1),            -- NULL = unlimited (e.g. unpaid leave)
  calendar_days       boolean not null default false, -- true = count weekends/holidays too
  requires_attachment boolean not null default false,
  allow_half_day      boolean not null default true,
  allow_backdate      boolean not null default false,
  description         text,
  color               text not null default '#64748b',
  sort_order          int not null default 0,
  active              boolean not null default true
);

-- Per-staff override of the default entitlement for a given year
create table if not exists public.leave_entitlements (
  user_id        uuid not null references public.profiles(id) on delete cascade,
  leave_type_id  int  not null references public.leave_types(id) on delete cascade,
  year           int  not null,
  days           numeric(5,1) not null check (days >= 0),
  primary key (user_id, leave_type_id, year)
);

create table if not exists public.public_holidays (
  holiday_date date primary key,
  name         text not null
);

create table if not exists public.leave_applications (
  id                   bigserial primary key,
  user_id              uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  leave_type_id        int  not null references public.leave_types(id),
  start_date           date not null,
  end_date             date not null,
  half_day             text check (half_day in ('AM', 'PM')),
  days                 numeric(5,1) not null default 0,
  reason               text not null,
  contact_during_leave text,
  handover_to          text,
  attachment_path      text,
  status               text not null default 'pending'
                         check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  decided_by           uuid references public.profiles(id),
  decided_at           timestamptz,
  director_remarks     text,
  created_at           timestamptz not null default now(),
  check (end_date >= start_date)
);

create index if not exists leave_applications_user_idx   on public.leave_applications (user_id, start_date);
create index if not exists leave_applications_status_idx on public.leave_applications (status);

-- ---------------------------------------------------------------------
-- Default leave types (edit days later in the app: Settings page)
-- ---------------------------------------------------------------------
insert into public.leave_types
  (code, name, default_days, calendar_days, requires_attachment, allow_half_day, allow_backdate, description, color, sort_order)
values
  ('AL',  'Annual Leave',    14,   false, false, true,  false, 'Paid annual leave. Please apply in advance.',                       '#2563eb', 1),
  ('CL',  'Casual Leave',    3,    false, false, true,  false, 'Short leave for personal matters.',                                 '#0891b2', 2),
  ('EL',  'Emergency Leave', 3,    false, false, true,  true,  'For unforeseen emergencies. May be applied after the fact.',        '#dc2626', 3),
  ('SL',  'Sick Leave',      14,   false, true,  true,  true,  'Medical certificate (MC) is required.',                             '#16a34a', 4),
  ('UL',  'Unpaid Leave',    null, false, false, true,  false, 'Leave without pay. Subject to Director approval.',                  '#7c3aed', 6)
on conflict (code) do nothing;

-- Maternity Leave is not offered: remove it (or just hide it if it was ever used, to keep history)
delete from public.leave_types t
 where t.code = 'ML'
   and not exists (select 1 from public.leave_applications a where a.leave_type_id = t.id);
update public.leave_types set active = false where code = 'ML';

-- ---------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

-- Number of leave days between two dates (inclusive).
-- Working-day mode skips Saturdays, Sundays and public holidays.
create or replace function public.count_leave_days(p_start date, p_end date, p_calendar boolean default false)
returns numeric language sql stable security definer set search_path = public as $$
  select count(*)::numeric
  from generate_series(p_start, p_end, interval '1 day') as g(d)
  where p_calendar
     or (extract(isodow from g.d) < 6
         and not exists (select 1 from public.public_holidays h where h.holiday_date = g.d::date))
$$;

-- Leave balance per type for a user and year.
-- Staff can only see their own; Director / HR & Admin can see anyone.
create or replace function public.leave_balances(p_user uuid default null, p_year int default null)
returns table (leave_type_id int, code text, name text, color text,
               entitled numeric, used numeric, pending numeric, balance numeric)
language sql stable security definer set search_path = public as $$
  with params as (
    select coalesce(p_user, auth.uid()) as uid,
           coalesce(p_year, extract(year from current_date)::int) as yr
  )
  select t.id, t.code, t.name, t.color,
         coalesce(e.days, t.default_days),
         coalesce(sum(a.days) filter (where a.status = 'approved'), 0),
         coalesce(sum(a.days) filter (where a.status = 'pending'), 0),
         coalesce(e.days, t.default_days)
           - coalesce(sum(a.days) filter (where a.status in ('approved', 'pending')), 0)
  from params p
  cross join public.leave_types t
  left join public.leave_entitlements e
         on e.leave_type_id = t.id and e.user_id = p.uid and e.year = p.yr
  left join public.leave_applications a
         on a.leave_type_id = t.id and a.user_id = p.uid
        and extract(year from a.start_date) = p.yr
  where t.active
    and (p.uid = auth.uid() or public.my_role() in ('director', 'admin'))
  group by t.id, e.days
  order by t.sort_order
$$;

-- ---------------------------------------------------------------------
-- Validation when a staff submits a leave application
-- ---------------------------------------------------------------------
create or replace function public.before_leave_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t        public.leave_types;
  v_bal    numeric;
  v_ent    numeric;
begin
  if auth.uid() is not null then
    new.user_id := auth.uid();
  end if;
  new.status := 'pending';
  new.decided_by := null;
  new.decided_at := null;
  new.director_remarks := null;
  new.created_at := now();

  select * into t from public.leave_types where id = new.leave_type_id and active;
  if not found then
    raise exception 'Invalid leave type.';
  end if;

  if coalesce(trim(new.reason), '') = '' then
    raise exception 'Please state the reason for leave.';
  end if;

  if not t.allow_backdate and new.start_date < current_date then
    raise exception '% cannot start on a past date.', t.name;
  end if;

  if t.requires_attachment and coalesce(new.attachment_path, '') = '' then
    raise exception '% requires a supporting document (e.g. MC).', t.name;
  end if;

  if new.half_day is not null then
    if not t.allow_half_day or t.calendar_days or new.start_date <> new.end_date then
      raise exception 'Half-day is only allowed for a single working day.';
    end if;
  end if;

  new.days := public.count_leave_days(new.start_date, new.end_date, t.calendar_days);
  if new.half_day is not null then
    new.days := new.days * 0.5;
  end if;
  if new.days <= 0 then
    raise exception 'The selected dates fall on weekends / public holidays only.';
  end if;

  if exists (
    select 1 from public.leave_applications a
    where a.user_id = new.user_id
      and a.status in ('pending', 'approved')
      and a.start_date <= new.end_date and a.end_date >= new.start_date
      and not (a.start_date = a.end_date and new.start_date = new.end_date
               and a.half_day is not null and new.half_day is not null
               and a.half_day <> new.half_day)
  ) then
    raise exception 'You already have a leave application on these dates.';
  end if;

  select coalesce(e.days, t.default_days) into v_ent
  from (select 1) x
  left join public.leave_entitlements e
         on e.user_id = new.user_id and e.leave_type_id = t.id
        and e.year = extract(year from new.start_date)::int;

  if v_ent is not null then
    select v_ent - coalesce(sum(a.days), 0) into v_bal
    from public.leave_applications a
    where a.user_id = new.user_id and a.leave_type_id = t.id
      and a.status in ('approved', 'pending')
      and extract(year from a.start_date) = extract(year from new.start_date);
    if new.days > v_bal then
      raise exception 'Insufficient % balance: requested % day(s), available % day(s).',
        t.name, new.days, greatest(v_bal, 0);
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_before_leave_insert on public.leave_applications;
create trigger trg_before_leave_insert
  before insert on public.leave_applications
  for each row execute function public.before_leave_insert();

-- ---------------------------------------------------------------------
-- Director decision & staff cancellation (the ONLY ways to change status)
-- ---------------------------------------------------------------------
create or replace function public.decide_leave(p_id bigint, p_decision text, p_remarks text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  a public.leave_applications;
begin
  if public.my_role() is distinct from 'director' then
    raise exception 'Only the Director can approve or reject leave.';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Invalid decision.';
  end if;
  select * into a from public.leave_applications where id = p_id for update;
  if not found then raise exception 'Application not found.'; end if;
  if a.status <> 'pending' then raise exception 'This application has already been %.', a.status; end if;
  if a.user_id = auth.uid() then raise exception 'You cannot approve your own leave.'; end if;
  if p_decision = 'rejected' and coalesce(trim(p_remarks), '') = '' then
    raise exception 'Please give a reason for rejection.';
  end if;

  update public.leave_applications
     set status = p_decision, decided_by = auth.uid(), decided_at = now(),
         director_remarks = nullif(trim(p_remarks), '')
   where id = p_id;
end $$;

create or replace function public.cancel_leave(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.leave_applications
     set status = 'cancelled'
   where id = p_id and user_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'Only your own pending applications can be cancelled.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Auto-create a profile when a user is added in Supabase Auth.
-- The very first user becomes HR & Admin.
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    case when exists (select 1 from public.profiles) then 'staff' else 'admin' end
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles           enable row level security;
alter table public.leave_types        enable row level security;
alter table public.leave_entitlements enable row level security;
alter table public.public_holidays    enable row level security;
alter table public.leave_applications enable row level security;

-- profiles: everyone signed in can see the staff directory; only HR & Admin edits
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- leave types & holidays: readable by all, managed by HR & Admin
drop policy if exists leave_types_select on public.leave_types;
create policy leave_types_select on public.leave_types for select to authenticated using (true);
drop policy if exists leave_types_admin on public.leave_types;
create policy leave_types_admin on public.leave_types for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists holidays_select on public.public_holidays;
create policy holidays_select on public.public_holidays for select to authenticated using (true);
drop policy if exists holidays_admin on public.public_holidays;
create policy holidays_admin on public.public_holidays for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- entitlements: own rows, or Director / HR & Admin; managed by HR & Admin
drop policy if exists entitlements_select on public.leave_entitlements;
create policy entitlements_select on public.leave_entitlements for select to authenticated
  using (user_id = auth.uid() or public.my_role() in ('director', 'admin'));
drop policy if exists entitlements_admin on public.leave_entitlements;
create policy entitlements_admin on public.leave_entitlements for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- applications: staff see their own, Director / HR & Admin see all.
-- Insert own only (validated by trigger). No direct update/delete — use decide_leave / cancel_leave.
drop policy if exists applications_select on public.leave_applications;
create policy applications_select on public.leave_applications for select to authenticated
  using (user_id = auth.uid() or public.my_role() in ('director', 'admin'));
drop policy if exists applications_insert on public.leave_applications;
create policy applications_insert on public.leave_applications for insert to authenticated
  with check (user_id = auth.uid() and public.my_role() is not null);

-- ---------------------------------------------------------------------
-- Storage: private bucket for MC / supporting documents
-- Files are stored as  <user_id>/<filename>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('attachments', 'attachments', false)
on conflict (id) do nothing;

drop policy if exists attachments_insert on storage.objects;
create policy attachments_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists attachments_select on storage.objects;
create policy attachments_select on storage.objects for select to authenticated
  using (bucket_id = 'attachments'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or public.my_role() in ('director', 'admin')));

drop policy if exists attachments_delete on storage.objects;
create policy attachments_delete on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- Sign in with Staff ID: Staff IDs are unique (case-insensitive) and the
-- login page looks up the account email for the ID entered.
-- ---------------------------------------------------------------------
create unique index if not exists profiles_staff_no_key on public.profiles (lower(staff_no));

create or replace function public.login_email(p_login text)
returns text language sql stable security definer set search_path = public as $$
  select email from public.profiles
  where lower(staff_no) = lower(trim(p_login)) and active
  limit 1
$$;

-- HR & Admin sets a new 4-digit PIN (the account password) for a staff
create or replace function public.admin_set_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.my_role() is distinct from 'admin' then
    raise exception 'Only HR & Admin can reset passwords.';
  end if;
  if coalesce(p_password, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits.';
  end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_user;
  if not found then raise exception 'User not found.'; end if;
end $$;

-- HR & Admin creates a staff account with Staff ID + 4-digit PIN only.
-- Supabase Auth needs an email, so an internal one (<staffid>@aahr.local) is generated;
-- staff never see or use it. Also runnable from the SQL Editor to create the first admin.
create or replace function public.admin_create_staff(
  p_staff_no   text,
  p_full_name  text,
  p_password   text,
  p_role       text default 'staff',
  p_department text default null,
  p_position   text default null
) returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id    uuid := gen_random_uuid();
  v_no    text := upper(trim(p_staff_no));
  v_email text;
begin
  -- From the app: only HR & Admin. From the SQL Editor (no signed-in user): allowed.
  if auth.uid() is not null and public.my_role() is distinct from 'admin' then
    raise exception 'Only HR & Admin can add staff.';
  end if;
  if v_no = '' or v_no !~ '^[A-Z0-9_-]+$' then
    raise exception 'Staff ID may only contain letters, numbers, - and _.';
  end if;
  if coalesce(trim(p_full_name), '') = '' then
    raise exception 'Full name is required.';
  end if;
  if coalesce(p_password, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits.';
  end if;
  if p_role not in ('staff', 'director', 'admin') then
    raise exception 'Invalid role.';
  end if;
  if exists (select 1 from public.profiles where lower(staff_no) = lower(v_no)) then
    raise exception 'Staff ID % is already used.', v_no;
  end if;

  v_email := lower(regexp_replace(v_no, '[^A-Za-z0-9]', '', 'g')) || '@aahr.local';
  if exists (select 1 from auth.users where email = v_email) then
    v_email := lower(regexp_replace(v_no, '[^A-Za-z0-9]', '', 'g')) || '.' || substr(v_id::text, 1, 8) || '@aahr.local';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', trim(p_full_name)),
    now(), now(), '', '', '', ''
  );

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
          now(), now(), now());

  -- handle_new_user() has created the profile; fill in the details
  update public.profiles
     set staff_no = v_no, full_name = trim(p_full_name), role = p_role,
         department = nullif(trim(p_department), ''), position = nullif(trim(p_position), '')
   where id = v_id;

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Team leave calendar: every signed-in staff can see who is on (approved) leave.
-- Only name, department, position, leave type and dates are shared —
-- never the reason, remarks or attachment.
-- ---------------------------------------------------------------------
create or replace function public.team_leave(p_from date, p_to date)
returns table (application_id bigint, user_id uuid, full_name text, department text, staff_position text,
               leave_type text, color text, calendar_days boolean,
               start_date date, end_date date, half_day text, days numeric)
language sql stable security definer set search_path = public as $$
  select a.id, a.user_id, p.full_name, p.department, p.position,
         t.name, t.color, t.calendar_days,
         a.start_date, a.end_date, a.half_day, a.days
  from public.leave_applications a
  join public.profiles p on p.id = a.user_id
  join public.leave_types t on t.id = a.leave_type_id
  where a.status = 'approved'
    and a.start_date <= p_to and a.end_date >= p_from
    and p_to - p_from <= 62
    and public.my_role() is not null
  order by p.full_name, a.start_date
$$;

-- ---------------------------------------------------------------------
-- App settings (e.g. colour theme). Readable before sign-in so the login page
-- shows the chosen theme; only HR & Admin can change them.
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);
insert into public.app_settings (key, value) values ('theme', 'emerald') on conflict (key) do nothing;
alter table public.app_settings enable row level security;
drop policy if exists app_settings_select on public.app_settings;
create policy app_settings_select on public.app_settings for select to anon, authenticated using (true);
drop policy if exists app_settings_admin on public.app_settings;
create policy app_settings_admin on public.app_settings for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
grant select on public.app_settings to anon, authenticated;
grant insert, update on public.app_settings to authenticated;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
grant execute on function public.count_leave_days(date, date, boolean) to authenticated;
grant execute on function public.leave_balances(uuid, int)             to authenticated;
grant execute on function public.decide_leave(bigint, text, text)      to authenticated;
grant execute on function public.cancel_leave(bigint)                  to authenticated;
grant execute on function public.login_email(text)                     to anon, authenticated;
grant execute on function public.admin_set_password(uuid, text)        to authenticated;
revoke execute on function public.admin_set_password(uuid, text) from public, anon;
revoke execute on function public.team_leave(date, date) from public, anon;
grant  execute on function public.team_leave(date, date) to authenticated;
revoke execute on function public.admin_create_staff(text, text, text, text, text, text) from public, anon;
grant  execute on function public.admin_create_staff(text, text, text, text, text, text) to authenticated;
revoke execute on function public.decide_leave(bigint, text, text) from anon;
revoke execute on function public.cancel_leave(bigint) from anon;

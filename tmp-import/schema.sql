-- =====================================================================
-- 대똥여지도 Supabase 스키마 (v2, 2026-11-23)
-- Supabase 대시보드 → SQL Editor 에 전체를 붙여넣고 Run. 여러 번 실행해도 된다.
-- 그 다음: Authentication → Sign In / Providers → "Allow anonymous sign-ins" 켜기
--
-- 개인정보 원칙: 서버는 사용자의 현재 위치(좌표)를 받지 않는다.
--  - 주변 화장실 검색은 앱이 내장 데이터 + '바뀐 행' 동기화로 기기 안에서 한다.
--  - 현장 확인(200m)은 기기에서 판정하고, 서버에는 결과(on_site 여부)만 온다.
-- =====================================================================

create extension if not exists postgis with schema extensions;
set search_path = public, extensions;

-- ---------------------------------------------------------------------
-- 화장실
-- ---------------------------------------------------------------------
create table if not exists public.toilets (
  id                 text primary key default gen_random_uuid()::text,
  name               text not null check (char_length(name) between 1 and 80),
  address            text,
  latitude           double precision not null check (latitude between 33 and 39.5),
  longitude          double precision not null check (longitude between 124 and 132),
  geog               extensions.geography(Point, 4326),
  category           text not null default 'public_toilet'
                     check (category in ('public_toilet','open_toilet','station','park','public_office','other')),
  source             text not null default 'public',
  status             text not null default 'verified' check (status in ('verified','pending','rejected','closed')),
  open_hours         text,
  is_always_open     boolean not null default false,
  access_note        text check (access_note is null or char_length(access_note) <= 200),
  has_accessible     boolean,
  has_diaper_table   boolean,
  has_emergency_bell boolean,
  has_cctv           boolean,
  is_unisex          boolean,
  managing_org       text,
  phone              text,
  rating_avg         double precision,
  rating_count       integer not null default 0,
  has_paper          boolean,
  has_hot_water      boolean,
  has_bidet          boolean,
  confirm_count      integer not null default 0,
  deny_count         integer not null default 0,
  closed_count       integer not null default 0,
  created_by         uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

alter table public.toilets add column if not exists building_name text;
alter table public.toilets add column if not exists floor text;

-- 출처: public(행안부) / osm(OpenStreetMap) / community(사용자 제보)
alter table public.toilets drop constraint if exists toilets_source_check;
alter table public.toilets add constraint toilets_source_check check (source in ('public','osm','community'));
alter table public.toilets drop constraint if exists toilets_building_name_check;
alter table public.toilets add constraint toilets_building_name_check check (building_name is null or char_length(building_name) <= 60);
alter table public.toilets drop constraint if exists toilets_floor_check;
alter table public.toilets add constraint toilets_floor_check check (floor is null or char_length(floor) <= 20);

create index if not exists toilets_geog_idx on public.toilets using gist (geog);
create index if not exists toilets_updated_idx on public.toilets (updated_at);
create index if not exists toilets_created_by_idx on public.toilets (created_by, created_at);

-- 좌표 → geog, 수정 시 updated_at 갱신 (가져오기 때 넣은 updated_at 은 유지 → 앱 동기화 기준)
create or replace function public.toilets_before_write()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
  new.geog := st_setsrid(st_makepoint(new.longitude, new.latitude), 4326)::geography;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists toilets_before_write on public.toilets;
create trigger toilets_before_write
  before insert or update on public.toilets
  for each row execute function public.toilets_before_write();

-- ---------------------------------------------------------------------
-- 투표 (현장 확인) — 사용자당 화장실 1표, 바꾸면 덮어씀. 좌표는 저장하지 않음.
-- ---------------------------------------------------------------------
create table if not exists public.votes (
  toilet_id   text not null references public.toilets(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('confirm','deny','closed')),
  created_at  timestamptz not null default now(),
  primary key (toilet_id, user_id)
);
alter table public.votes drop column if exists distance_m;

-- ---------------------------------------------------------------------
-- 리뷰 — 사용자당 화장실당 하루 1개. 신고 3건 이상이면 자동 숨김.
-- ---------------------------------------------------------------------
create table if not exists public.reviews (
  id             uuid primary key default gen_random_uuid(),
  toilet_id      text not null references public.toilets(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  cleanliness    smallint not null check (cleanliness between 1 and 5),
  has_paper      boolean,
  has_hot_water  boolean,
  has_bidet      boolean,
  comment        text check (comment is null or char_length(comment) <= 300),
  on_site        boolean not null default false,
  review_date    date not null default ((now() at time zone 'Asia/Seoul')::date),
  created_at     timestamptz not null default now(),
  unique (toilet_id, user_id, review_date)
);
alter table public.reviews add column if not exists hidden boolean not null default false;
create index if not exists reviews_toilet_idx on public.reviews (toilet_id, created_at desc);

-- ---------------------------------------------------------------------
-- 위치 정보 보완 기록 / 신고
-- ---------------------------------------------------------------------
create table if not exists public.detail_edits (
  id            bigint generated always as identity primary key,
  toilet_id     text not null references public.toilets(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  building_name text,
  floor         text,
  access_note   text,
  created_at    timestamptz not null default now()
);
alter table public.detail_edits drop column if exists distance_m;

create table if not exists public.content_reports (
  id           bigint generated always as identity primary key,
  target_type  text not null check (target_type in ('review','toilet')),
  target_id    text not null,
  reporter     uuid not null references auth.users(id) on delete cascade,
  reason       text not null check (char_length(reason) between 1 and 200),
  created_at   timestamptz not null default now(),
  unique (target_type, target_id, reporter)
);

-- ---------------------------------------------------------------------
-- RLS: 읽기는 허용(반려·숨김 처리는 앱/정책에서), 쓰기는 아래 보안 함수(RPC)로만
-- ---------------------------------------------------------------------
alter table public.toilets         enable row level security;
alter table public.votes           enable row level security;
alter table public.reviews         enable row level security;
alter table public.detail_edits    enable row level security;
alter table public.content_reports enable row level security;

-- 반려된 화장실도 읽을 수 있어야 앱이 동기화 때 지도에서 지울 수 있다
drop policy if exists "toilets: 반려되지 않은 화장실은 누구나 조회" on public.toilets;
drop policy if exists "toilets: 누구나 조회" on public.toilets;
create policy "toilets: 누구나 조회" on public.toilets for select using (true);

drop policy if exists "votes: 내 투표만 조회" on public.votes;
create policy "votes: 내 투표만 조회" on public.votes for select using (user_id = auth.uid());

drop policy if exists "reviews: 누구나 조회" on public.reviews;
drop policy if exists "reviews: 숨김 아닌 리뷰 조회" on public.reviews;
create policy "reviews: 숨김 아닌 리뷰 조회" on public.reviews for select using (not hidden);

-- 예전 버전의 위치 기반 함수는 삭제 (서버가 위치를 받지 않도록)
drop function if exists public.toilets_nearby(double precision, double precision, double precision, int);
drop function if exists public.report_toilet(text, double precision, double precision, text, text, text, boolean, text, boolean, boolean, boolean, boolean, double precision, double precision);
drop function if exists public.report_toilet(text, double precision, double precision, text, text, text, boolean, text, text, text, boolean, boolean, boolean, boolean, double precision, double precision);
drop function if exists public.cast_vote(text, text, double precision, double precision);
drop function if exists public.submit_review(text, int, boolean, boolean, boolean, text, double precision, double precision);
drop function if exists public.suggest_location_details(text, double precision, double precision, text, text, text);

-- ---------------------------------------------------------------------
-- 검증 규칙 (앱의 VerificationPolicy 와 동일하게 유지)
-- ---------------------------------------------------------------------
create or replace function public.next_status(p_current text, p_confirm int, p_deny int, p_closed int)
returns text
language sql
immutable
as $$
  select case p_current
    when 'pending' then
      case when p_confirm - p_deny >= 3 then 'verified'
           when p_deny - p_confirm >= 3 then 'rejected'
           else 'pending' end
    when 'verified' then case when p_closed - p_confirm >= 3 then 'closed' else 'verified' end
    when 'closed'   then case when p_confirm - p_closed >= 3 then 'verified' else 'closed' end
    else p_current
  end;
$$;

create or replace function public.amenity_majority(p_toilet_id text, p_field text)
returns boolean
language sql
stable
set search_path = public
as $$
  with recent as (
    select case p_field
             when 'paper'     then has_paper
             when 'hot_water' then has_hot_water
             when 'bidet'     then has_bidet
           end as v
    from public.reviews
    where toilet_id = p_toilet_id and not hidden
      and (case p_field
             when 'paper'     then has_paper
             when 'hot_water' then has_hot_water
             when 'bidet'     then has_bidet
           end) is not null
    order by created_at desc
    limit 10
  )
  select case when count(*) = 0 then null
              else (count(*) filter (where v)) * 2 > count(*) end
  from recent;
$$;

-- 리뷰·투표 집계 다시 계산 (상태는 투표 결과로만 바뀜)
create or replace function public.recompute_toilet(p_toilet_id text, p_update_status boolean default false)
returns public.toilets
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_t       public.toilets;
  v_cnt     int;
  v_avg     double precision;
  v_confirm int;
  v_deny    int;
  v_closed  int;
begin
  select * into v_t from public.toilets where id = p_toilet_id for update;
  if not found then return null; end if;

  select count(*), avg(cleanliness)::double precision into v_cnt, v_avg
  from public.reviews where toilet_id = p_toilet_id and not hidden;

  select count(*) filter (where kind = 'confirm'),
         count(*) filter (where kind = 'deny'),
         count(*) filter (where kind = 'closed')
    into v_confirm, v_deny, v_closed
  from public.votes
  where toilet_id = p_toilet_id and created_at > now() - interval '180 days';

  update public.toilets
     set rating_count  = v_cnt,
         rating_avg    = v_avg,
         has_paper     = coalesce(public.amenity_majority(p_toilet_id, 'paper'), has_paper),
         has_hot_water = coalesce(public.amenity_majority(p_toilet_id, 'hot_water'), has_hot_water),
         has_bidet     = coalesce(public.amenity_majority(p_toilet_id, 'bidet'), has_bidet),
         confirm_count = v_confirm,
         deny_count    = v_deny,
         closed_count  = v_closed,
         status        = case when p_update_status
                              then public.next_status(v_t.status, v_confirm, v_deny, v_closed)
                              else status end
   where id = p_toilet_id
  returning * into v_t;
  return v_t;
end $$;

-- ---------------------------------------------------------------------
-- RPC: 새 화장실 제보 (제보자 위치는 받지 않음 — 500m 이내 확인은 앱에서)
-- ---------------------------------------------------------------------
create or replace function public.report_toilet(
  p_name text,
  p_lat double precision,
  p_lng double precision,
  p_address text default null,
  p_category text default 'open_toilet',
  p_open_hours text default null,
  p_is_always_open boolean default false,
  p_access_note text default null,
  p_building_name text default null,
  p_floor text default null,
  p_has_paper boolean default null,
  p_has_hot_water boolean default null,
  p_has_bidet boolean default null,
  p_has_accessible boolean default null
)
returns public.toilets
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_point geography;
  v_row   public.toilets;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  v_point := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;

  if exists (select 1 from public.toilets
             where status <> 'rejected' and st_dwithin(geog, v_point, 15)) then
    raise exception 'DUPLICATE';
  end if;

  if (select count(*) from public.toilets
      where created_by = v_uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'RATE_LIMITED';
  end if;

  insert into public.toilets (
    name, address, latitude, longitude, category, source, status,
    open_hours, is_always_open, access_note, building_name, floor,
    has_paper, has_hot_water, has_bidet, has_accessible, created_by
  ) values (
    trim(p_name), p_address, p_lat, p_lng, coalesce(p_category, 'open_toilet'), 'community', 'pending',
    p_open_hours, coalesce(p_is_always_open, false), nullif(trim(left(p_access_note, 200)), ''),
    nullif(trim(left(p_building_name, 60)), ''), nullif(trim(left(p_floor, 20)), ''),
    p_has_paper, p_has_hot_water, p_has_bidet, p_has_accessible, v_uid
  )
  returning * into v_row;

  return v_row;
end $$;

-- ---------------------------------------------------------------------
-- RPC: 현장 확인 투표 (200m 이내 확인은 앱에서, 좌표는 받지 않음)
-- ---------------------------------------------------------------------
create or replace function public.cast_vote(p_toilet_id text, p_kind text)
returns public.toilets
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_t   public.toilets;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if p_kind not in ('confirm','deny','closed') then raise exception 'INVALID_KIND'; end if;

  select * into v_t from public.toilets where id = p_toilet_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_t.created_by is not null and v_t.created_by = v_uid then raise exception 'OWN_REPORT'; end if;

  if (select count(*) from public.votes
      where user_id = v_uid and created_at > now() - interval '1 day') >= 60 then
    raise exception 'RATE_LIMITED';
  end if;

  insert into public.votes (toilet_id, user_id, kind, created_at)
  values (p_toilet_id, v_uid, p_kind, now())
  on conflict (toilet_id, user_id)
  do update set kind = excluded.kind, created_at = excluded.created_at;

  return public.recompute_toilet(p_toilet_id, true);
end $$;

-- ---------------------------------------------------------------------
-- RPC: 리뷰 작성 (on_site 는 앱이 기기에서 판정한 값)
-- ---------------------------------------------------------------------
create or replace function public.submit_review(
  p_toilet_id text,
  p_cleanliness int,
  p_has_paper boolean default null,
  p_has_hot_water boolean default null,
  p_has_bidet boolean default null,
  p_comment text default null,
  p_on_site boolean default false
)
returns public.toilets
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_t   public.toilets;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into v_t from public.toilets where id = p_toilet_id;
  if not found or v_t.status = 'rejected' then raise exception 'NOT_FOUND'; end if;

  -- 스팸 방지: 한 사람당 하루 리뷰 20개까지
  if (select count(*) from public.reviews
      where user_id = v_uid and created_at > now() - interval '1 day') >= 20 then
    raise exception 'RATE_LIMITED';
  end if;

  begin
    insert into public.reviews (toilet_id, user_id, cleanliness, has_paper, has_hot_water, has_bidet, comment, on_site)
    values (p_toilet_id, v_uid, greatest(1, least(5, p_cleanliness)),
            p_has_paper, p_has_hot_water, p_has_bidet,
            nullif(trim(left(p_comment, 300)), ''), coalesce(p_on_site, false));
  exception when unique_violation then
    raise exception 'ALREADY_REVIEWED_TODAY';
  end;

  return public.recompute_toilet(p_toilet_id, false);
end $$;

-- ---------------------------------------------------------------------
-- RPC: 건물·층·찾아가는 법 보완 (현장 확인은 앱에서)
-- ---------------------------------------------------------------------
create or replace function public.suggest_location_details(
  p_toilet_id text,
  p_building_name text default null,
  p_floor text default null,
  p_access_note text default null
)
returns public.toilets
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_t   public.toilets;
  v_b   text := nullif(trim(left(p_building_name, 60)), '');
  v_f   text := nullif(trim(left(p_floor, 20)), '');
  v_n   text := nullif(trim(left(p_access_note, 200)), '');
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into v_t from public.toilets where id = p_toilet_id for update;
  if not found or v_t.status = 'rejected' then raise exception 'NOT_FOUND'; end if;

  if (select count(*) from public.detail_edits
      where user_id = v_uid and created_at > now() - interval '1 day') >= 30 then
    raise exception 'RATE_LIMITED';
  end if;

  insert into public.detail_edits (toilet_id, user_id, building_name, floor, access_note)
  values (p_toilet_id, v_uid, v_b, v_f, v_n);

  update public.toilets
     set building_name = coalesce(v_b, building_name),
         floor         = coalesce(v_f, floor),
         access_note   = coalesce(v_n, access_note)
   where id = p_toilet_id
  returning * into v_t;
  return v_t;
end $$;

-- ---------------------------------------------------------------------
-- RPC: 부적절한 콘텐츠 신고 — 서로 다른 3명이 신고하면 리뷰 숨김 / 확인 대기 제보 반려
-- ---------------------------------------------------------------------
create or replace function public.report_content(p_target_type text, p_target_id text, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_count int;
  v_tid   text;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if p_target_type not in ('review','toilet') then raise exception 'INVALID_TARGET'; end if;

  -- 스팸 방지: 한 사람당 하루 신고 20건까지
  if (select count(*) from public.content_reports
      where reporter = v_uid and created_at > now() - interval '1 day') >= 20 then
    raise exception 'RATE_LIMITED';
  end if;

  insert into public.content_reports (target_type, target_id, reporter, reason)
  values (p_target_type, p_target_id, v_uid, left(coalesce(nullif(trim(p_reason), ''), '부적절'), 200))
  on conflict (target_type, target_id, reporter) do nothing;

  select count(*) into v_count from public.content_reports
  where target_type = p_target_type and target_id = p_target_id;

  if v_count >= 3 then
    if p_target_type = 'review' then
      update public.reviews set hidden = true where id::text = p_target_id returning toilet_id into v_tid;
      if v_tid is not null then perform public.recompute_toilet(v_tid, false); end if;
    else
      update public.toilets set status = 'rejected' where id = p_target_id and status = 'pending';
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- RPC: 내 데이터 전부 삭제 (리뷰·투표·보완 기록·신고·확인 대기 제보·익명 계정)
-- ---------------------------------------------------------------------
create or replace function public.delete_my_data()
returns void
language plpgsql
security definer
set search_path = public, extensions, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_ids text[];
  v_id  text;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select array_agg(distinct toilet_id) into v_ids from (
    select toilet_id from public.reviews where user_id = v_uid
    union select toilet_id from public.votes where user_id = v_uid
  ) s;

  delete from public.reviews where user_id = v_uid;
  delete from public.votes where user_id = v_uid;
  delete from public.detail_edits where user_id = v_uid;
  delete from public.content_reports where reporter = v_uid;
  delete from public.toilets where created_by = v_uid and status = 'pending';
  update public.toilets set created_by = null where created_by = v_uid;

  if v_ids is not null then
    foreach v_id in array v_ids loop
      perform public.recompute_toilet(v_id, true);
    end loop;
  end if;

  delete from auth.users where id = v_uid;
end $$;

-- ---------------------------------------------------------------------
-- 권한: 쓰기 함수는 로그인한 사용자(익명 포함)만
-- ---------------------------------------------------------------------
revoke execute on function public.recompute_toilet(text, boolean) from public, anon, authenticated;
revoke execute on function public.report_toilet(text, double precision, double precision, text, text, text, boolean, text, text, text, boolean, boolean, boolean, boolean) from public, anon;
revoke execute on function public.cast_vote(text, text) from public, anon;
revoke execute on function public.submit_review(text, int, boolean, boolean, boolean, text, boolean) from public, anon;
revoke execute on function public.suggest_location_details(text, text, text, text) from public, anon;
revoke execute on function public.report_content(text, text, text) from public, anon;
revoke execute on function public.delete_my_data() from public, anon;

grant execute on function public.report_toilet(text, double precision, double precision, text, text, text, boolean, text, text, text, boolean, boolean, boolean, boolean) to authenticated;
grant execute on function public.cast_vote(text, text) to authenticated;
grant execute on function public.submit_review(text, int, boolean, boolean, boolean, text, boolean) to authenticated;
grant execute on function public.suggest_location_details(text, text, text, text) to authenticated;
grant execute on function public.report_content(text, text, text) to authenticated;
grant execute on function public.delete_my_data() to authenticated;

-- ---------------------------------------------------------------------
-- 테이블 권한 (Data API 자동 권한을 끈 프로젝트용)
--  앱은 읽기만 직접 하고, 쓰기는 위 함수들로만 한다.
-- ---------------------------------------------------------------------
revoke all on public.toilets, public.votes, public.reviews,
              public.detail_edits, public.content_reports
  from anon, authenticated;
grant select on public.toilets to anon, authenticated;
grant select on public.reviews to anon, authenticated;
grant select on public.votes   to authenticated;
grant all on public.toilets, public.votes, public.reviews,
             public.detail_edits, public.content_reports to service_role;

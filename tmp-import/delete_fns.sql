-- ---------------------------------------------------------------------
-- 내 제보 삭제: 아직 '확인 대기'(다른 사람이 확인하기 전)일 때만.
--  다른 기기에도 사라지도록 실제 삭제 대신 status='rejected' 로 바꾼다 (동기화로 전파).
-- ---------------------------------------------------------------------
create or replace function public.delete_my_report(p_toilet_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_t   public.toilets;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into v_t from public.toilets where id = p_toilet_id for update;
  if not found or v_t.status = 'rejected' then raise exception 'NOT_FOUND'; end if;
  if v_t.source <> 'community' or v_t.created_by is distinct from v_uid then raise exception 'NOT_OWNER'; end if;
  if v_t.status <> 'pending' then raise exception 'ALREADY_VERIFIED'; end if;

  delete from public.votes        where toilet_id = p_toilet_id;
  delete from public.reviews      where toilet_id = p_toilet_id;
  delete from public.detail_edits where toilet_id = p_toilet_id;
  update public.toilets set status = 'rejected' where id = p_toilet_id;
end $$;

-- 내 리뷰 삭제 → 평점·편의시설 다시 계산
create or replace function public.delete_my_review(p_review_id uuid)
returns public.toilets
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_tid text;
  v_t   public.toilets;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  delete from public.reviews where id = p_review_id and user_id = v_uid returning toilet_id into v_tid;
  if v_tid is null then raise exception 'NOT_FOUND'; end if;
  perform public.recompute_toilet(v_tid, false);
  select * into v_t from public.toilets where id = v_tid;
  return v_t;
end $$;

revoke execute on function public.delete_my_report(text) from public, anon;
revoke execute on function public.delete_my_review(uuid) from public, anon;
grant execute on function public.delete_my_report(text) to authenticated;
grant execute on function public.delete_my_review(uuid) to authenticated;


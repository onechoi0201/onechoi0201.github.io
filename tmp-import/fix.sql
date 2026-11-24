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
  -- 아직 확인 전인 내 제보는 '숨김'(rejected) 처리 → 동기화로 모든 기기에서 사라진다
  update public.toilets set status = 'rejected', created_by = null
   where created_by = v_uid and status = 'pending';
  update public.toilets set created_by = null where created_by = v_uid;

  if v_ids is not null then
    foreach v_id in array v_ids loop
      perform public.recompute_toilet(v_id, true);
    end loop;
  end if;

  delete from auth.users where id = v_uid;
end $$;

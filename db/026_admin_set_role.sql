-- 026: change a member's role from the back office (members page). Only an admin can do it,
-- and nobody can change their own role (so the last admin can't lock themselves out). Safe to run more than once.
create or replace function public.admin_set_role(p_user uuid, p_role text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'admin' then raise exception 'not allowed'; end if;
  if p_role not in ('client','analyst','manager','admin') then raise exception 'bad role'; end if;
  if p_user = auth.uid() then raise exception 'not your own role'; end if;
  update profiles set role = p_role where id = p_user;
  return p_role;
end $$;
revoke all on function public.admin_set_role(uuid, text) from public;
grant execute on function public.admin_set_role(uuid, text) to authenticated;

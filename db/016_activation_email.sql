-- 016: email the client when the manager activates their account (Brevo transactional API, Arabic).
-- Needs the Brevo API key in app_secrets (run separately, typing the key yourself — never share it):
--   insert into public.app_secrets (name, value) values ('brevo_api_key', 'xkeysib-...')
--   on conflict (name) do update set value = excluded.value;
-- Without the key nothing is sent and nothing breaks.

insert into public.app_config values
  ('email_sender', '{"name":"توصيات","email":"noreply@notify.twsiat.com"}')
on conflict (key) do update set value = excluded.value;

create or replace function public.brevo_send(p_to text, p_name text, p_subject text, p_html text) returns void
language plpgsql security definer set search_path = public as $$
declare k text := (select value from app_secrets where name = 'brevo_api_key');
        snd jsonb := (select value from app_config where key = 'email_sender');
begin
  if k is null or p_to is null then return; end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object('sender', snd,
                               'to', jsonb_build_array(jsonb_build_object('email', p_to, 'name', coalesce(p_name, p_to))),
                               'subject', p_subject, 'htmlContent', p_html),
    headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'));
end $$;
revoke all on function public.brevo_send(text, text, text, text) from public, anon, authenticated;

create or replace function public.activation_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare em text := (select email from auth.users where id = new.id);
        url text := coalesce((select value #>> '{}' from app_config where key = 'site_url'), 'https://rooms.twsiat.com/');
        nm text := coalesce(new.display_name, '');
        room_ar text := case new.room when 2 then 'غرفة الحسابات الكبيرة (1,000$ وأكثر)' else 'غرفة الحسابات الصغيرة (أقل من 1,000$)' end;
        html text;
begin
  if new.ib_verified and not coalesce(old.ib_verified, false) then
    html := format($h$
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;background:#f4f6f9;padding:24px">
  <div style="max-width:480px;margin:auto;background:#ffffff;border-radius:12px;padding:28px;text-align:right;color:#1b2436">
    <h2 style="margin:0 0 12px;font-size:20px">تم تفعيل حسابك ✅</h2>
    <p style="font-size:15px;line-height:1.8;margin:0 0 8px">أهلاً %s،</p>
    <p style="font-size:15px;line-height:1.8;margin:0 0 20px">تأكدنا من حساب التداول وتفعّلت عضويتك. غرفتك: <b>%s</b>.<br>ادخل، وافق على شروط الغرفة، وبتشوف التوصيات وحجم اللوت المناسب لحسابك.</p>
    <p style="text-align:center;margin:0 0 20px">
      <a href="%srooms" style="background:#2e7d5b;color:#ffffff;text-decoration:none;padding:12px 28px;border-radius:8px;font-size:16px;display:inline-block">ادخل على غرفتك</a>
    </p>
    <p style="font-size:13px;color:#6b7280;line-height:1.7;margin:0">التداول فيه مخاطرة عالية بخسارة رأس المال. التوصيات للمعلومة وما بتضمن نتائج.</p>
    <hr style="border:none;border-top:1px solid #e5e7eb;margin:20px 0">
    <p style="font-size:12px;color:#9ca3af;margin:0">موقع توصيات · twsiat.com</p>
  </div>
</div>$h$, nm, room_ar, url);
    perform brevo_send(em, nm, 'تم تفعيل حسابك بغرفة التداول ✅', html);
  end if;
  return new;
end $$;

drop trigger if exists profiles_activation_notify on public.profiles;
create trigger profiles_activation_notify after update of ib_verified on public.profiles
  for each row execute function public.activation_notify();

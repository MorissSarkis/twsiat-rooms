'use client';
import { useEffect, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabase-browser';

const b64ToBytes = (s) => {
  const b = atob((s + '='.repeat((4 - (s.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
};

// Big, colourful card that turns on phone notifications for the rooms. Hides itself once they are on.
export default function PushPrompt() {
  const [st, setSt] = useState('loading'); // loading | unsupported | ios | ask | denied | on | justOn | busy | error
  const [msg, setMsg] = useState('');

  async function save(sub) {
    const sb = supabaseBrowser();
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return false;
    const j = sub.toJSON();
    const row = { user_id: user.id, endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth, ua: navigator.userAgent.slice(0, 200) };
    const { error } = await sb.from('push_subs').upsert(row, { onConflict: 'endpoint' });
    return !error;
  }

  useEffect(() => {
    (async () => {
      const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
      const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
      if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
        setSt(ios && !standalone ? 'ios' : 'unsupported'); return;
      }
      if (ios && !standalone) { setSt('ios'); return; }
      try {
        const reg = await navigator.serviceWorker.register('/sw.js');
        const sub = await reg.pushManager.getSubscription();
        if (sub && Notification.permission === 'granted') { await save(sub); setSt('on'); return; }
        setSt(Notification.permission === 'denied' ? 'denied' : 'ask');
      } catch { setSt('unsupported'); }
    })();
  }, []);

  async function enable() {
    setSt('busy'); setMsg('');
    try {
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') { setSt(perm === 'denied' ? 'denied' : 'ask'); return; }
      const { data: key } = await supabaseBrowser().rpc('push_public_key');
      if (!key) { setMsg('الإشعارات لسا قيد التجهيز، جرّب بعد شوي.'); setSt('error'); return; }
      const reg = await navigator.serviceWorker.ready;
      const sub = (await reg.pushManager.getSubscription()) || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(key) });
      if (!(await save(sub))) { setMsg('ما قدرنا نحفظ الاشتراك، جرّب كمان مرة.'); setSt('error'); return; }
      reg.showNotification('تم تفعيل الإشعارات ✅', { body: 'رح توصلك توصيات غرفتك وتحديثاتها هون أول بأول.', icon: '/icon-192.png?v=2', badge: '/badge.png?v=2', dir: 'rtl', lang: 'ar' });
      setSt('justOn');
    } catch { setMsg('صار خطأ. جرّب من Chrome على أندرويد أو Safari على آيفون.'); setSt('error'); }
  }

  if (st === 'loading' || st === 'on' || st === 'unsupported') return null;

  if (st === 'justOn') return (
    <div className="push push-ok">
      <div className="push-ic">✅</div>
      <div><b>تمام! الإشعارات مفعّلة على هالجهاز</b><div className="push-sub">رح يوصلك إشعار أول ما تنزل توصية بغرفتك.</div></div>
    </div>
  );

  return (
    <div className="push">
      <div className="push-ic bell">🔔</div>
      <div style={{ flex: 1 }}>
        <b className="push-t">فعّل إشعارات التوصيات على تلفونك</b>
        <div className="push-sub">بيوصلك إشعار فوري أول ما تنزل توصية بغرفتك، ولما تتفعّل أو تضرب الهدف أو الستوب. ببلاش وبدون تطبيق.</div>

        {st === 'ios' && (
          <ol className="push-steps">
            <li>اضغط زر المشاركة <b>⬆️</b> تحت بـ Safari</li>
            <li>اختار <b>«إضافة إلى الشاشة الرئيسية»</b></li>
            <li>افتح الموقع من الأيقونة الجديدة، واضغط زر التفعيل هون</li>
          </ol>
        )}
        {st === 'denied' && (
          <div className="push-warn">الإشعارات محظورة بهالمتصفح. افتح إعدادات الموقع (🔒 جنب العنوان) ← الإشعارات ← <b>سماح</b>، وبعدين حدّث الصفحة.</div>
        )}
        {msg && <div className="push-warn">{msg}</div>}
        {(st === 'ask' || st === 'busy' || st === 'error') && (
          <button className="push-btn" onClick={enable} disabled={st === 'busy'}>{st === 'busy' ? '...' : 'فعّل الإشعارات الآن'}</button>
        )}
      </div>
    </div>
  );
}

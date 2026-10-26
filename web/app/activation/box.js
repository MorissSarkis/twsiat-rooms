import { wa } from '@/lib/brand';
import ActivationForm from './form';
import { submitActivation } from './actions';

export const ACT_ERRORS = {
  phone: 'اكتب رقم واتساب مع المفتاح الدولي عشان نقدر نتواصل معك.',
  phone_needed: 'ضيف رقم واتساب أول، وبعدها بتفتحلك التنبيهات.',
  phone_bad: 'رقم التلفون مش صحيح. اكتبه مع المفتاح الدولي، مثلاً +971501234567',
  account: 'رقم الحساب لازم يكون أرقام بس (4 لـ 15 رقم).',
  act: 'ما قدرنا نبعت الطلب، جرّب مرة ثانية أو راسلنا على واتساب.',
};

// Where the member stands with activation, and the form when there's something to send
export default function ActivationBox({ profile, user, back }) {
  if (profile.ib_verified) return null;
  const mail = user?.email || '';
  if (profile.activation_rejected_at) {
    return (
      <div className="grid">
        <div className="card" style={{ borderColor: 'var(--sell)' }}>
          <b>طلب التفعيل ما انقبل</b>
          {profile.activation_note && <div style={{ marginTop: 6 }}>{profile.activation_note}</div>}
          <div className="muted" style={{ marginTop: 6, lineHeight: 1.8 }}>عدّل المعلومات وابعت مرة ثانية، أو راسلنا وبنساعدك.</div>
          <a className="btn ghost" style={{ marginTop: 10, width: '100%' }} href={wa('مرحبا، طلب التفعيل تبعي ما انقبل وبدي مساعدة. إيميلي: ' + mail)} target="_blank" rel="noopener">راسلنا على واتساب</a>
        </div>
        <div className="card"><ActivationForm action={submitActivation} back={back} profile={profile} /></div>
      </div>
    );
  }
  if (profile.activation_requested_at) {
    const help = profile.has_ib_account === false;
    return (
      <div className="card hl">
        <b>{help ? 'وصلنا طلبك ✅' : 'طلب التفعيل وصلنا ✅'}</b>
        <div className="muted" style={{ marginTop: 6, lineHeight: 1.8 }}>
          {help
            ? 'فريقنا رح يتواصل معك على واتساب ويساعدك تفتح أو تنقل حسابك تحت وكالتنا.'
            : 'فريقنا بيتأكد إنه الحساب تحت وكالتنا وبيفعّله، وبيوصلك إيميل لما يتفعّل.'}
        </div>
        <a className="btn ghost" style={{ marginTop: 10, width: '100%' }} href={wa('مرحبا، بعتت طلب تفعيل بموقع توصيات. إيميلي: ' + mail)} target="_blank" rel="noopener">سرّع على واتساب</a>
      </div>
    );
  }
  return <div className="card"><ActivationForm action={submitActivation} back={back} profile={profile} /></div>;
}

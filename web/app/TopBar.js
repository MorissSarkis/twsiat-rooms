import Link from 'next/link';
import { LOGO_URL } from '@/lib/brand';
// Short menu: Home · Rooms · Alerts, the rest under "More"
export default function TopBar({ profile }) {
  const staff = profile && ['analyst','manager','admin'].includes(profile.role);
  return (
    <header className="top">
      <Link href={profile ? '/home' : '/'} className="brand"><img src={LOGO_URL} alt="موقع توصيات" width={34} height={34} className="logo" /><span>موقع توصيات</span></Link>
      <nav className="nav">
        {profile ? (
          <>
            <Link href="/home">الرئيسية</Link>
            <Link href="/rooms">الغرف</Link>
            <Link href="/alerts">التنبيهات</Link>
            <details className="more">
              <summary>المزيد ▾</summary>
              <div className="more-menu">
                <Link href="/community">غرفة المجتمع</Link>
                <Link href="/levels">المستويات</Link>
                <Link href="/record">سجل الأداء</Link>
                {staff && <Link href="/admin">الباك أوفيس</Link>}
                <form action="/auth/signout" method="post"><button className="linkbtn">خروج</button></form>
              </div>
            </details>
          </>
        ) : (
          <>
            <Link href="/record">سجل الأداء</Link>
            <Link href="/login">دخول</Link>
          </>
        )}
      </nav>
    </header>
  );
}

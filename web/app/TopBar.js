import Link from 'next/link';
import { LOGO_URL } from '@/lib/brand';
export default function TopBar({ profile }) {
  const staff = profile && ['analyst','manager','admin'].includes(profile.role);
  return (
    <header className="top">
      <Link href="/" className="brand"><img src={LOGO_URL} alt="موقع توصيات" width={34} height={34} className="logo" /><span>غرفة التداول</span></Link>
      <nav className="nav">
        {profile && <Link href="/rooms">غرف التوصيات</Link>}
        {profile && <Link href="/community">غرفة المجتمع</Link>}
        {profile && <Link href="/levels">المستويات</Link>}
        <Link href="/record">سجل الأداء</Link>
        {staff && <Link href="/admin">الباك أوفيس</Link>}
        {profile ? <form action="/auth/signout" method="post"><button className="btn ghost" style={{minHeight:34,padding:'0 12px'}}>خروج</button></form>
                 : <Link href="/login">دخول</Link>}
      </nav>
    </header>
  );
}

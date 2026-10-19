import TopBar from '../../TopBar';
import { currentUser } from '@/lib/supabase-server';
import NewSignalForm from './form';

export const dynamic = 'force-dynamic';

export default async function NewSignal() {
  const { sb, profile } = await currentUser();
  if (!profile || !['analyst', 'manager', 'admin'].includes(profile.role)) {
    return (<><TopBar profile={profile} /><main className="wrap"><div className="card">هالصفحة للفريق بس.</div></main></>);
  }
  return (<><TopBar profile={profile} /><NewSignalForm symbols={(await sb.rpc('list_symbols')).data} canPublish={['manager', 'admin'].includes(profile.role)} /></>);
}

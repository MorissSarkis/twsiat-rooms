import { redirect } from 'next/navigation';
import TopBar from '../../TopBar';
import { currentUser } from '@/lib/supabase-server';
import BatchForm from './form';

export const dynamic = 'force-dynamic';

export default async function Batch() {
  const { sb, user, profile } = await currentUser();
  if (!user) redirect('/login');
  if (!['manager', 'admin'].includes(profile?.role)) redirect('/admin');
  const { data: symbols } = await sb.rpc('list_symbols');
  return (<><TopBar profile={profile} /><BatchForm symbols={(symbols || []).map((s) => ({ code: s.code, name: s.name, digits: s.digits }))} /></>);
}

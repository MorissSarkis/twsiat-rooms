import { redirect } from 'next/navigation';
import { currentUser } from '@/lib/supabase-server';
export default async function Home() {
  const { user } = await currentUser();
  redirect(user ? '/rooms' : '/login');
}

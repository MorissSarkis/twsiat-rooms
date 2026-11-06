import { redirect } from 'next/navigation';
import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import AccountForms from './forms';

export const dynamic = 'force-dynamic';

export default async function Account() {
  const { user, profile } = await currentUser();
  if (!user) redirect('/login');
  return (
    <>
      <TopBar profile={profile} />
      <AccountForms
        email={user.email}
        pendingEmail={user.new_email || null}
        profile={{
          display_name: profile?.display_name || '', broker: profile?.broker, broker_account: profile?.broker_account,
          balance_usd: profile?.balance_usd, room: profile?.room, ib_verified: !!profile?.ib_verified,
          upgrade_requested_at: profile?.upgrade_requested_at, upgrade_balance: profile?.upgrade_balance, upgrade_note: profile?.upgrade_note,
        }}
      />
    </>
  );
}

import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

export const dynamic = 'force-dynamic';

const cell = (v) => {
  const s = v == null ? '' : String(v);
  return /[",\n\r]/.test(s) || /^[=+\-@]/.test(s) ? `"${s.replace(/^([=+\-@])/, "'$1").replace(/"/g, '""')}"` : s;
};

// members as a CSV file (opens in Excel with Arabic names intact)
export async function GET(request) {
  const sb = supabaseServer();
  const u = new URL(request.url);
  const { data, error } = await sb.rpc('admin_members', {
    p_search: u.searchParams.get('q') || null, p_status: u.searchParams.get('s') || null, p_limit: 5000, p_offset: 0,
  });
  if (error) return new NextResponse('not allowed', { status: 403 });
  const head = ['name', 'email', 'signed_up', 'last_login', 'login_with', 'ib_client', 'activation_requested', 'broker', 'broker_account', 'balance_usd', 'room', 'alerts', 'alerts_paid_until'];
  const lines = (data || []).map((m) => [
    m.name, m.email, m.signed_up?.slice(0, 10), m.last_login?.slice(0, 10), m.provider, m.ib_verified ? 'yes' : 'no',
    m.activation_requested_at?.slice(0, 10), m.broker, m.broker_account, m.balance_usd, m.room, m.alerts_reason, m.alerts_paid_until?.slice(0, 10),
  ].map(cell).join(','));
  const csv = '﻿' + [head.join(','), ...lines].join('\r\n');
  return new NextResponse(csv, { headers: {
    'Content-Type': 'text/csv; charset=utf-8',
    'Content-Disposition': `attachment; filename="twsiat-members-${new Date().toISOString().slice(0, 10)}.csv"`,
    'Cache-Control': 'no-store',
  } });
}

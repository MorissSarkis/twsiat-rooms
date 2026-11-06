'use server';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';
import { checkItem, orderTypeOf } from '@/lib/batch';

async function manager() {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) throw new Error('not signed in');
  const { data: p } = await sb.from('profiles').select('role').eq('id', user.id).single();
  if (!['manager', 'admin'].includes(p?.role)) throw new Error('not allowed');
  return { sb, user };
}

async function lastPrices(sb, symbols) {
  const out = {};
  await Promise.all([...new Set(symbols.filter(Boolean))].map(async (s) => {
    const { data } = await sb.from('prices_m5').select('close,spread,t').eq('symbol', s).order('t', { ascending: false }).limit(1);
    if (data?.[0]) out[s] = data[0];
  }));
  return out;
}

// live prices for the preview
export async function previewPrices(symbols) {
  const { sb } = await manager();
  const p = await lastPrices(sb, symbols);
  return Object.fromEntries(Object.entries(p).map(([k, v]) => [k, { close: Number(v.close), spread: Number(v.spread || 0), t: v.t }]));
}

// publish the checked items; every item is re-checked here against the live price
export async function publishBatch(items, rooms, hours) {
  const { sb, user } = await manager();
  if (!rooms?.length) return [{ n: 0, ok: false, text: 'اختار غرفة وحدة على الأقل' }];
  const { data: known } = await sb.rpc('list_symbols');
  const codes = (known || []).map((s) => s.code);
  const prices = await lastPrices(sb, items.map((i) => i.symbol));
  const res = [];
  for (const it of items) {
    const p = prices[it.symbol];
    if (!p) { res.push({ n: it.n, ok: false, text: 'ما في سعر حي لهالأداة' }); continue; }
    const live = it.side === 'BUY' ? Number(p.close) + Number(p.spread || 0) : Number(p.close);
    const errs = checkItem(it, codes, live);
    if (errs.length) { res.push({ n: it.n, ok: false, text: errs.join(' · ') }); continue; }
    const order_type = orderTypeOf(it, Number(p.close));
    const entry = it.market ? live : it.entry;
    const expires_at = it.market ? null : new Date(Date.now() + (Number(hours) || 24) * 36e5).toISOString();
    // keep a record of who published (same as the one-by-one form)
    const { data: sug, error: e1 } = await sb.from('suggestions').insert({
      source: 'analyst', created_by: user.id, symbol: it.symbol, side: it.side, order_type, entry, stop_loss: it.sl,
      tp1: it.tp1, tp2: it.tp2, tp3: it.tp3, expires_at: expires_at || new Date(Date.now() + 864e5).toISOString(),
      check_passed: true, check_reasons: [{ rule: 'batch', ok: true, detail: 'نشر دفعة' }],
    }).select('id').single();
    if (e1) { res.push({ n: it.n, ok: false, text: 'ما انتشرت: ' + e1.message }); continue; }
    const { data: sig, error: e2 } = await sb.from('signals').insert({
      suggestion_id: sug.id, rooms, symbol: it.symbol, side: it.side, order_type, entry,
      stop_loss: it.sl, tp1: it.tp1, tp2: it.tp2, tp3: it.tp3, expires_at,
    }).select('id').single();
    if (e2) {
      await sb.from('suggestions').update({ status: 'rejected', decided_by: user.id, decided_at: new Date().toISOString(), decision_note: 'ما انتشرت: ' + e2.message }).eq('id', sug.id);
      res.push({ n: it.n, ok: false, text: 'ما انتشرت: ' + e2.message }); continue;
    }
    await sb.from('suggestions').update({ status: 'approved', decided_by: user.id, decided_at: new Date().toISOString(), decision_note: 'نشر دفعة' }).eq('id', sug.id);
    res.push({ n: it.n, ok: true, text: `انتشرت #${sig.id} · ${order_type} · دخول ${entry}` });
  }
  revalidatePath('/admin'); revalidatePath('/rooms');
  return res;
}

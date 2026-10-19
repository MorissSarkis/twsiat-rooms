'use client';
import { useState } from 'react';
import Link from 'next/link';

// Display categories, in this order. `from` = the group names stored in app_config 'symbols'.
const CATS = [
  { key: 'fx',     label: 'العملات',        from: ['عملات'] },
  { key: 'cmd',    label: 'السلع',          from: ['طاقة', 'سلع'] },
  { key: 'metal',  label: 'المعادن',        from: ['معادن'] },
  { key: 'stock',  label: 'الأسهم',         from: ['أسهم'] },
  { key: 'index',  label: 'المؤشرات',       from: ['مؤشرات'] },
  { key: 'crypto', label: 'عملات رقمية', from: ['كريبتو', 'عملات رقمية'] },
];

export default function SymbolPicker({ list, current }) {
  const cats = CATS.map((c) => ({ ...c, items: list.filter((x) => c.from.includes(x.group)) }));
  const known = new Set(CATS.flatMap((c) => c.from));
  const other = list.filter((x) => !known.has(x.group));
  if (other.length) cats.push({ key: 'other', label: 'أخرى', items: other });
  const [open, setOpen] = useState(null);
  const active = cats.find((c) => c.items.some((x) => x.code === current))?.key;
  const shown = cats.find((c) => c.key === open);

  return (
    <div className="picker">
      <div className="cats">
        {cats.map((c) => (
          <button key={c.key} type="button" disabled={!c.items.length}
            className={`cat ${open === c.key ? 'open' : ''} ${active === c.key ? 'has' : ''}`}
            onClick={() => setOpen(open === c.key ? null : c.key)} aria-expanded={open === c.key}>
            <span>{c.label}</span>
            <span className="muted">{c.items.length ? c.items.length : 'قريباً'}</span>
            {c.items.length > 0 && <span className="arrow">▾</span>}
          </button>
        ))}
      </div>
      {shown && (
        <div className="panel tabs">
          {shown.items.map((x) => (
            <Link key={x.code} href={`/levels?s=${x.code}`} className={x.code === current ? 'on' : ''} onClick={() => setOpen(null)}>{x.name}</Link>
          ))}
        </div>
      )}
    </div>
  );
}

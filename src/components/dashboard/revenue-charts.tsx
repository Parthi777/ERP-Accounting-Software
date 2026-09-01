'use client';

import * as React from 'react';
import {
  Area,
  AreaChart,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';

import { formatINR, formatINRShort, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

/**
 * Dashboard charts.
 *
 * Both read from posted journal lines. Spec §8 warns against decorative charts,
 * so there are exactly two: revenue over time, and where that revenue came from.
 * Colours come from the §7 palette rather than Recharts' defaults.
 */

const MIX_COLORS = ['#2563eb', '#8b5cf6', '#10b981', '#f59e0b'];

export function RevenueTrendChart({
  data,
}: {
  readonly data: readonly { readonly date: string; readonly amount: number }[];
}) {
  if (data.length === 0) {
    return <EmptyChart message="No posted revenue in this period." />;
  }

  return (
    <ResponsiveContainer width="100%" height={260}>
      <AreaChart data={[...data]} margin={{ top: 8, right: 8, bottom: 0, left: 8 }}>
        <defs>
          <linearGradient id="revenue-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#2563eb" stopOpacity={0.22} />
            <stop offset="100%" stopColor="#2563eb" stopOpacity={0.02} />
          </linearGradient>
        </defs>

        <XAxis
          dataKey="date"
          tickFormatter={(value: string) => formatDate(value).slice(0, 6)}
          tick={{ fontSize: 11, fill: '#94a3b8' }}
          axisLine={false}
          tickLine={false}
          minTickGap={24}
        />
        <YAxis
          tickFormatter={(value: number) => formatINRShort(value as Paise)}
          tick={{ fontSize: 11, fill: '#94a3b8' }}
          axisLine={false}
          tickLine={false}
          width={72}
        />
        <Tooltip
          cursor={{ stroke: '#cbd5e1', strokeDasharray: '3 3' }}
          contentStyle={{
            borderRadius: 10,
            border: '1px solid #e8eef7',
            boxShadow: '0 8px 24px -12px rgba(15,23,42,0.2)',
            fontSize: 12,
          }}
          labelFormatter={(value) => formatDate(String(value))}
          // Recharts types the tooltip value as a broad ValueType; narrow it here
          // rather than widening formatINR, which should only ever see paise.
          formatter={(value) => [formatINR(Number(value) as Paise), 'Revenue']}
        />
        <Area
          type="monotone"
          dataKey="amount"
          stroke="#2563eb"
          strokeWidth={2}
          fill="url(#revenue-fill)"
          // Spec §8 asks for restraint; the line draws once and stays put.
          isAnimationActive={false}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}

export function RevenueMixChart({
  data,
}: {
  readonly data: readonly { readonly label: string; readonly amount: number }[];
}) {
  const total = data.reduce((sum, slice) => sum + slice.amount, 0);

  if (total === 0) {
    return <EmptyChart message="No posted revenue to break down." />;
  }

  return (
    <div className="flex flex-col items-center gap-4 sm:flex-row">
      <div className="relative size-[180px] shrink-0">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie
              data={[...data]}
              dataKey="amount"
              nameKey="label"
              innerRadius={58}
              outerRadius={86}
              paddingAngle={2}
              stroke="none"
              isAnimationActive={false}
            >
              {data.map((slice, index) => (
                <Cell key={slice.label} fill={MIX_COLORS[index % MIX_COLORS.length]} />
              ))}
            </Pie>
            <Tooltip
              contentStyle={{
                borderRadius: 10,
                border: '1px solid #e8eef7',
                fontSize: 12,
              }}
              formatter={(value, name) => [formatINR(Number(value) as Paise), String(name)]}
            />
          </PieChart>
        </ResponsiveContainer>

        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-[11px] text-ink-400">Total</span>
          <span className="numeric text-sm font-semibold text-ink-900">
            {formatINRShort(total as Paise)}
          </span>
        </div>
      </div>

      <ul className="w-full space-y-2">
        {data.map((slice, index) => (
          <li key={slice.label} className="flex items-center gap-2 text-sm">
            <span
              className="size-2.5 shrink-0 rounded-full"
              style={{ background: MIX_COLORS[index % MIX_COLORS.length] }}
              aria-hidden
            />
            <span className="flex-1 truncate text-ink-600">{slice.label}</span>
            <span className="numeric text-ink-900">{formatINRShort(slice.amount as Paise)}</span>
            <span className="w-12 text-right text-xs text-ink-400">
              {((slice.amount / total) * 100).toFixed(1)}%
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function EmptyChart({ message }: { readonly message: string }) {
  return (
    <div className="flex h-[220px] items-center justify-center rounded-lg border border-dashed border-ink-200 text-sm text-ink-400">
      {message}
    </div>
  );
}

import { NextResponse, type NextRequest } from 'next/server';

import { getDashboard } from '@/server/services/dashboard/dashboard-service';
import { toAppError } from '@/server/errors';

export const dynamic = 'force-dynamic';

/**
 * Dashboard KPIs as JSON, for client-side refresh and future export.
 *
 * The service performs the permission check and omits margin figures entirely for
 * roles without `dashboard.view_margin`, so this handler does no filtering of its
 * own — there is nothing sensitive left in the payload to filter (spec §10, §52).
 */
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = request.nextUrl;
    const today = new Date();
    const firstOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);

    const data = await getDashboard({
      from: searchParams.get('from') ?? toIso(firstOfMonth),
      to: searchParams.get('to') ?? toIso(today),
      branchId: searchParams.get('branch') === 'all' ? null : searchParams.get('branch'),
    });

    return NextResponse.json(data);
  } catch (error) {
    const appError = toAppError(error);
    console.error('[api/dashboard/kpis]', appError.message);
    return NextResponse.json(appError.toResponseBody(), { status: appError.status });
  }
}

function toIso(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

import { NextResponse } from 'next/server';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { hrClient } from '@/server/services/hr/hr-client';

export const dynamic = 'force-dynamic';

/**
 * A claim's receipt (photo or PDF), fetched from the HR app through this server
 * so the HR key never reaches a browser. Only for someone who may see claims,
 * and only for a claim of their own dealer (RLS decides whether it is found).
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  await requirePermission('hr.claims.view');
  const { id } = await params;
  const which = new URL(request.url).searchParams.get('which') === 'pdf' ? 'pdf' : 'photo';

  const supabase = await createSupabaseServerClient();
  const { data: claim } = await supabase.from('employee_claims').select('hr_claim_id').eq('id', id).maybeSingle();
  if (!claim) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  const file = await hrClient.file(claim.hr_claim_id, which);
  if (!file || !file.body) return NextResponse.json({ error: 'The HR app has no such file, or could not be reached.' }, { status: 502 });
  return new NextResponse(file.body, {
    headers: {
      'content-type': file.headers.get('content-type') ?? (which === 'pdf' ? 'application/pdf' : 'image/jpeg'),
      'cache-control': 'private, max-age=300',
    },
  });
}

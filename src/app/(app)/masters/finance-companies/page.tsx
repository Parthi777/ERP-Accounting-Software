import { redirect } from 'next/navigation';

/** Listed under both Finance and Masters in spec §9; one implementation. */
export default function Page() {
  redirect('/finance/companies');
}

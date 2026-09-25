import { redirect } from 'next/navigation';

/**
 * Job cards are no longer used (0088): a service is billed directly, by the
 * customer's name, mobile and vehicle number. The old address lands on billing.
 */
export default function ServicePage() {
  redirect('/service/billing');
}

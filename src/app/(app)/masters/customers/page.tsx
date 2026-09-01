import { redirect } from 'next/navigation';

/**
 * Spec §9 lists Customers under both "Customers" and "Masters". They are the same
 * master, so this route sends you to the one implementation rather than
 * maintaining two that can drift apart.
 */
export default function MastersCustomersPage() {
  redirect('/customers');
}

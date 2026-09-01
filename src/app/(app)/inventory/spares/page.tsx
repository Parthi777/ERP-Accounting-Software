import { redirect } from 'next/navigation';

/**
 * Spec §9 lists these under both Inventory and Masters. They are one master, so
 * this points at the single implementation rather than maintaining two.
 */
export default function Page() {
  redirect('/masters/spares');
}

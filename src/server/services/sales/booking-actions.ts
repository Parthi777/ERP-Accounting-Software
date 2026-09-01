'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/sales/booking-service';
import { toAppError } from '@/server/errors';
import * as advances from '@/server/services/sales/booking-advance-service';

export async function createBookingAction(
  input: service.CreateBookingInput,
): Promise<service.BookingResult> {
  try {
    const result = await service.createBooking(input);
    if (result.ok) {
      revalidatePath('/bookings');
      revalidatePath('/vehicles');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function cancelBookingAction(id: string, reason: string): Promise<service.BookingResult> {
  try {
    const result = await service.cancelBooking(id, reason);
    if (result.ok) {
      revalidatePath('/bookings');
      revalidatePath(`/bookings/${id}`);
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function refundBookingAdvanceAction(input: {
  bookingId: string;
  amount: number;
  mode: 'CASH' | 'BANK';
  reason: string;
  bankAccountId?: string | null;
}): Promise<advances.RefundResult> {
  try {
    const result = await advances.refundBookingAdvance(input);
    if (result.ok) {
      revalidatePath('/bookings');
      revalidatePath('/bookings/advances');
      revalidatePath(`/bookings/${input.bookingId}`);
      revalidatePath('/cash-book');
      revalidatePath('/bank/book');
      revalidatePath('/accounting/journals');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

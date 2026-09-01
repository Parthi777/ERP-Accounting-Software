import { z } from 'zod';

/**
 * Customer schemas — spec §11.
 *
 * The same rules the database enforces, expressed once and shared by the form and
 * the server action. Duplicating them in two places is how a client-side check and
 * a database constraint drift apart; the pattern here keeps the message the user
 * sees identical to the rule that actually holds.
 *
 * `customer_code` is deliberately absent: it is issued by the database (§60.6) and
 * accepting one from the client would let a caller choose their own Customer ID.
 */

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .transform((value) => (value === '' ? undefined : value));

const MOBILE = /^[6-9][0-9]{9}$/;
const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$/;
const PAN = /^[A-Z]{5}[0-9]{4}[A-Z]$/;
const PINCODE = /^[1-9][0-9]{5}$/;

export const customerSchema = z
  .object({
    name: z
      .string()
      .trim()
      .min(2, 'Enter the customer name.')
      .max(150, 'Name is too long.'),

    customer_type: z.enum(['INDIVIDUAL', 'BUSINESS']).default('INDIVIDUAL'),

    mobile: z
      .string()
      .trim()
      .regex(MOBILE, 'Enter a 10-digit mobile number starting 6–9.'),

    alternate_mobile: z
      .string()
      .trim()
      .optional()
      .transform((value) => (value === '' ? undefined : value))
      .refine((value) => value === undefined || MOBILE.test(value), {
        message: 'Enter a 10-digit mobile number starting 6–9.',
      }),

    email: z
      .string()
      .trim()
      .optional()
      .transform((value) => (value === '' ? undefined : value))
      .refine((value) => value === undefined || z.string().email().safeParse(value).success, {
        message: 'Enter a valid email address.',
      }),

    address_line1: optionalText(200),
    address_line2: optionalText(200),
    city: optionalText(100),
    state: optionalText(100),
    state_code: optionalText(2),

    pincode: z
      .string()
      .trim()
      .optional()
      .transform((value) => (value === '' ? undefined : value))
      .refine((value) => value === undefined || PINCODE.test(value), {
        message: 'Enter a valid 6-digit PIN code.',
      }),

    gstin: z
      .string()
      .trim()
      .toUpperCase()
      .optional()
      .transform((value) => (value === '' ? undefined : value))
      .refine((value) => value === undefined || GSTIN.test(value), {
        message: 'Enter a valid 15-character GSTIN.',
      }),

    pan: z
      .string()
      .trim()
      .toUpperCase()
      .optional()
      .transform((value) => (value === '' ? undefined : value))
      .refine((value) => value === undefined || PAN.test(value), {
        message: 'Enter a valid 10-character PAN.',
      }),

    origin_branch_id: z.string().uuid().optional().or(z.literal('')).transform((v) => (v ? v : undefined)),
    notes: optionalText(1000),
    status: z.enum(['ACTIVE', 'INACTIVE', 'BLOCKED']).default('ACTIVE'),
  })
  // Mirrors customers_business_gstin_check: a registered business needs a GSTIN.
  .refine((values) => values.customer_type !== 'BUSINESS' || Boolean(values.gstin), {
    message: 'A business customer must have a GSTIN.',
    path: ['gstin'],
  })
  // The GSTIN embeds the state code; a mismatch is a data-entry error worth catching.
  .refine(
    (values) => !values.gstin || !values.state_code || values.gstin.slice(0, 2) === values.state_code,
    {
      message: 'The GSTIN does not start with this state code.',
      path: ['gstin'],
    },
  );

export type CustomerInput = z.input<typeof customerSchema>;
export type CustomerValues = z.output<typeof customerSchema>;

/** Search accepts a Customer ID, a mobile number, a name fragment or a GSTIN. */
export const customerSearchSchema = z.object({
  q: z.string().trim().max(100).optional(),
  status: z.enum(['ALL', 'ACTIVE', 'INACTIVE', 'BLOCKED']).default('ACTIVE'),
  page: z.coerce.number().int().min(1).default(1),
});

export type CustomerSearch = z.output<typeof customerSearchSchema>;

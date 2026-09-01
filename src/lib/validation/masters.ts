import { z } from 'zod';

/**
 * Master data schemas — spec §5, §16, §25, §28, §29.
 *
 * Each mirrors the CHECK constraints on its table. The database is the authority;
 * these exist so the user gets the message before the round trip, and so the
 * server can reject the same input the same way when a request arrives without
 * having gone through the form.
 */

const trimmed = (max: number) => z.string().trim().max(max);
const optional = (max: number) =>
  trimmed(max)
    .optional()
    .transform((v) => (v === '' ? undefined : v));

const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$/;
const MOBILE = /^[6-9][0-9]{9}$/;

// ─────────────────────────────────────────────────────────────────────────────
// HSN / SAC codes
// ─────────────────────────────────────────────────────────────────────────────
export const hsnSchema = z.object({
  code: trimmed(8).regex(/^[0-9]{4,8}$/, 'HSN and SAC codes are 4 to 8 digits.'),
  code_type: z.enum(['HSN', 'SAC']).default('HSN'),
  description: trimmed(200).min(2, 'Enter a description.'),
  status: z.enum(['ACTIVE', 'INACTIVE']).default('ACTIVE'),
});
export type HsnInput = z.input<typeof hsnSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// Tax codes — effective-dated (spec §16)
// ─────────────────────────────────────────────────────────────────────────────
export const taxCodeSchema = z
  .object({
    code: trimmed(30).regex(/^[A-Z][A-Z0-9_]{1,30}$/, 'Use capitals, digits and underscore, e.g. GST18.'),
    name: trimmed(100).min(2, 'Enter a name.'),
    hsn_code_id: z.string().uuid().optional().or(z.literal('')).transform((v) => (v ? v : undefined)),
    cgst_rate: z.coerce.number().min(0).max(50),
    sgst_rate: z.coerce.number().min(0).max(50),
    cess_rate: z.coerce.number().min(0).max(50).default(0),
    effective_from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a start date.'),
    effective_to: z
      .string()
      .optional()
      .transform((v) => (v === '' ? undefined : v))
      .refine((v) => v === undefined || /^\d{4}-\d{2}-\d{2}$/.test(v), 'Choose a valid end date.'),
    status: z.enum(['ACTIVE', 'INACTIVE']).default('ACTIVE'),
  })
  .refine(
    (v) => !v.effective_to || v.effective_to >= v.effective_from,
    { message: 'The end date cannot precede the start date.', path: ['effective_to'] },
  );
export type TaxCodeInput = z.input<typeof taxCodeSchema>;

/**
 * IGST is not a form field. The constraint `igst_rate = cgst_rate + sgst_rate`
 * makes it derivable, and asking a user to enter a number the database will
 * reject if it disagrees is a trap rather than a choice.
 */
export function deriveIgst(cgst: number, sgst: number): number {
  return cgst + sgst;
}

// ─────────────────────────────────────────────────────────────────────────────
// Vehicle models and variants
// ─────────────────────────────────────────────────────────────────────────────
export const vehicleModelSchema = z.object({
  brand: trimmed(60).min(1, 'Enter a brand.'),
  name: trimmed(100).min(1, 'Enter a model name.'),
  model_code: trimmed(30).regex(/^[A-Z0-9][A-Z0-9._-]{1,29}$/, 'Capitals, digits, dot, dash or underscore.'),
  category: z.enum(['SCOOTER', 'MOTORCYCLE', 'MOPED', 'ELECTRIC', 'THREE_WHEELER']).default('SCOOTER'),
  fuel_type: z.enum(['PETROL', 'ELECTRIC', 'CNG', 'HYBRID']).default('PETROL'),
  hsn_code_id: z.string().uuid().optional().or(z.literal('')).transform((v) => (v ? v : undefined)),
  tax_code: optional(30),
  status: z.enum(['ACTIVE', 'DISCONTINUED']).default('ACTIVE'),
});
export type VehicleModelInput = z.input<typeof vehicleModelSchema>;

export const vehicleVariantSchema = z.object({
  model_id: z.string().uuid('Choose a model.'),
  name: trimmed(100).min(1, 'Enter a variant name.'),
  variant_code: trimmed(30).regex(/^[A-Z0-9][A-Z0-9._-]{1,29}$/, 'Capitals, digits, dot, dash or underscore.'),
  engine_cc: z.coerce.number().min(0).max(2000).optional().or(z.literal('')).transform((v) => (v === '' ? undefined : Number(v))),
  transmission: optional(40),
  brake_type: optional(40),
  start_type: optional(40),
  status: z.enum(['ACTIVE', 'DISCONTINUED']).default('ACTIVE'),
});
export type VehicleVariantInput = z.input<typeof vehicleVariantSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// Accessories and spares (spec §28, §29)
// ─────────────────────────────────────────────────────────────────────────────
export const inventoryItemSchema = z.object({
  item_code: trimmed(30).regex(/^[A-Z0-9][A-Z0-9._/-]{1,29}$/, 'Capitals, digits, dot, slash, dash or underscore.'),
  name: trimmed(150).min(2, 'Enter an item name.'),
  item_type: z.enum(['ACCESSORY', 'SPARE']),
  brand: optional(60),
  category: optional(60),
  uom: z.enum(['NOS', 'SET', 'PAIR', 'LTR', 'KG', 'MTR', 'BOX']).default('NOS'),
  hsn_code_id: z.string().uuid().optional().or(z.literal('')).transform((v) => (v ? v : undefined)),
  tax_code: optional(30),
  standard_cost: z.coerce.number().min(0).default(0),
  selling_price: z.coerce.number().min(0).default(0),
  reorder_level: z.coerce.number().min(0).default(0),
  is_fitment: z.coerce.boolean().default(false),
  status: z.enum(['ACTIVE', 'INACTIVE']).default('ACTIVE'),
});
export type InventoryItemInput = z.input<typeof inventoryItemSchema>;

// ─────────────────────────────────────────────────────────────────────────────
// Finance companies (spec §25)
// ─────────────────────────────────────────────────────────────────────────────
export const financeCompanySchema = z.object({
  code: trimmed(30).regex(/^[A-Z0-9][A-Z0-9._-]{1,29}$/, 'Capitals, digits, dot, dash or underscore.'),
  name: trimmed(150).min(2, 'Enter the company name.'),
  contact_person: optional(100),
  mobile: z
    .string()
    .trim()
    .optional()
    .transform((v) => (v === '' ? undefined : v))
    .refine((v) => v === undefined || MOBILE.test(v), 'Enter a 10-digit mobile number starting 6–9.'),
  email: z
    .string()
    .trim()
    .optional()
    .transform((v) => (v === '' ? undefined : v))
    .refine((v) => v === undefined || z.string().email().safeParse(v).success, 'Enter a valid email address.'),
  gstin: z
    .string()
    .trim()
    .toUpperCase()
    .optional()
    .transform((v) => (v === '' ? undefined : v))
    .refine((v) => v === undefined || GSTIN.test(v), 'Enter a valid 15-character GSTIN.'),
  ledger_account_id: z.string().uuid().optional().or(z.literal('')).transform((v) => (v ? v : undefined)),
  commission_percent: z.coerce.number().min(0).max(100).default(0),
  status: z.enum(['ACTIVE', 'INACTIVE']).default('ACTIVE'),
});
export type FinanceCompanyInput = z.input<typeof financeCompanySchema>;

// ─────────────────────────────────────────────────────────────────────────────
// Suppliers (spec §41, §44)
// ─────────────────────────────────────────────────────────────────────────────
// No `code` field: supplier_code is issued by the database on insert, the same
// way customer_code is. A client-supplied identifier would not be unique.
export const supplierSchema = z.object({
  name: trimmed(150).min(2, 'Enter the supplier name.'),
  supplier_type: z.enum(['GOODS', 'SERVICE', 'OEM']).default('GOODS'),
  contact_person: optional(100),
  mobile: z
    .string()
    .trim()
    .optional()
    .transform((v) => (v === '' ? undefined : v))
    .refine((v) => v === undefined || MOBILE.test(v), 'Enter a 10-digit mobile number starting 6–9.'),
  email: z
    .string()
    .trim()
    .optional()
    .transform((v) => (v === '' ? undefined : v))
    .refine((v) => v === undefined || z.string().email().safeParse(v).success, 'Enter a valid email address.'),
  gstin: z
    .string()
    .trim()
    .toUpperCase()
    .optional()
    .transform((v) => (v === '' ? undefined : v))
    .refine((v) => v === undefined || GSTIN.test(v), 'Enter a valid 15-character GSTIN.'),
  city: optional(80),
  state: optional(80),
  credit_days: z.coerce.number().int().min(0).max(365).default(0),
  status: z.enum(['ACTIVE', 'INACTIVE', 'BLOCKED']).default('ACTIVE'),
});
export type SupplierInput = z.input<typeof supplierSchema>;

/** Which master a generic request is addressing. */
export const MASTER_KINDS = [
  'hsn',
  'tax',
  'vehicle_model',
  'vehicle_variant',
  'inventory_item',
  'finance_company',
  'supplier',
] as const;

export type MasterKind = (typeof MASTER_KINDS)[number];

export const MASTER_SCHEMAS = {
  hsn: hsnSchema,
  tax: taxCodeSchema,
  vehicle_model: vehicleModelSchema,
  vehicle_variant: vehicleVariantSchema,
  inventory_item: inventoryItemSchema,
  finance_company: financeCompanySchema,
  supplier: supplierSchema,
} as const;

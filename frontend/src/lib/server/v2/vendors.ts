import { error, type Cookies } from '@sveltejs/kit';
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import { apiStatus } from '#lib/api-errors.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];
type Context = { cookies: Cookies };

export const VENDOR_FIELDS = [
  'name',
  'email',
  'phone',
  'website',
  'industry',
  'currency',
  'address_line',
  'city',
  'state',
  'postcode',
  'country',
  'description'
] as const;

export function vendorFormBody(form: FormData): FormBody<Schemas['VendorRequest']> {
  const body: FormBody<Schemas['VendorRequest']> = {};
  for (const field of VENDOR_FIELDS) {
    if (form.has(field))
      body[field] = form.get(field)?.toString().trim() || (field === 'name' ? '' : null);
  }
  body.is_active = form.get('is_active') === 'on';
  for (const field of ['assigned_to', 'teams'] as const) {
    if (form.has(`${field}_present`)) body[field] = form.getAll(field).map(String).filter(Boolean);
  }
  return body;
}

export async function listVendors(context: Context, params = new URLSearchParams()) {
  const query = new URLSearchParams();
  for (const field of ['search', 'offset', 'limit']) {
    const value = params.get(field);
    if (value) query.set(field, value);
  }
  if (!query.has('limit')) query.set('limit', '25');
  const response: Schemas['VendorListResponse'] = await apiRequest(
    `/vendors/?${query}`,
    {},
    context
  );
  return response;
}

export async function getVendor(context: Context, id: string) {
  try {
    const response: Schemas['Vendor'] = await apiRequest(`/vendors/${id}/`, {}, context);
    return response;
  } catch (err) {
    if (apiStatus(err) === 404) error(404, 'Vendor not found.');
    throw err;
  }
}

export async function createVendor(context: Context, body: FormBody<Schemas['VendorRequest']>) {
  const response: Schemas['Vendor'] = await apiRequest(
    '/vendors/',
    { method: 'POST', body },
    context
  );
  return response;
}

export async function updateVendor(
  context: Context,
  id: string,
  body: FormBody<Schemas['PatchedVendorRequest']>
) {
  const response: Schemas['Vendor'] = await apiRequest(
    `/vendors/${id}/`,
    { method: 'PATCH', body },
    context
  );
  return response;
}

export async function deleteVendor(context: Context, id: string) {
  await apiRequest<void>(`/vendors/${id}/`, { method: 'DELETE' }, context);
}

export function billFormBody(form: FormData): FormBody<Schemas['BillRequest']> {
  const body: FormBody<Schemas['BillRequest']> = {};
  for (const field of [
    'bill_number',
    'bill_date',
    'due_date',
    'currency',
    'total_amount',
    'amount_paid',
    'notes'
  ] as const) {
    if (form.has(field))
      body[field] =
        form.get(field)?.toString().trim() ||
        (field === 'due_date' || field === 'currency'
          ? null
          : field === 'total_amount' || field === 'amount_paid'
            ? '0'
            : '');
  }
  // "Paid in full" checkbox: the backend derives PAID status from amount_paid.
  if (form.get('paid_in_full') === 'on') body.amount_paid = body.total_amount ?? '0';
  return body;
}

export async function listBills(context: Context, params = new URLSearchParams()) {
  const query = new URLSearchParams();
  for (const field of ['vendor', 'status', 'overdue', 'limit', 'offset']) {
    const value = params.get(field);
    if (value) query.set(field, value);
  }
  if (!query.has('limit')) query.set('limit', '25');
  const response: Schemas['BillListResponse'] = await apiRequest(
    `/vendors/bills/?${query}`,
    {},
    context
  );
  return response;
}

export async function getBill(context: Context, id: string) {
  try {
    const response: Schemas['Bill'] = await apiRequest(`/vendors/bills/${id}/`, {}, context);
    return response;
  } catch (err) {
    if (apiStatus(err) === 404) error(404, 'Bill not found.');
    throw err;
  }
}

export async function createBill(context: Context, body: FormBody<Schemas['BillRequest']>) {
  const response: Schemas['Bill'] = await apiRequest(
    '/vendors/bills/',
    { method: 'POST', body },
    context
  );
  return response;
}

export async function updateBill(
  context: Context,
  id: string,
  body: FormBody<Schemas['PatchedBillRequest']>
) {
  const response: Schemas['Bill'] = await apiRequest(
    `/vendors/bills/${id}/`,
    { method: 'PATCH', body },
    context
  );
  return response;
}

export async function deleteBill(context: Context, id: string) {
  await apiRequest<void>(`/vendors/bills/${id}/`, { method: 'DELETE' }, context);
}

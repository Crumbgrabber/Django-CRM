/**
 * The arithmetic the invoice and estimate builders share.
 *
 * THE SERVER IS THE AUTHORITY ON THE MONEY. `Invoice.recalculate_totals()`
 * and `Estimate.recalculate_totals()` recompute every figure on save; what is
 * computed here is a preview of what they will decide, in their order:
 * subtotal (the sum of each line's net amount, see `lineAmount`), then the
 * discount, then tax on the discounted amount, then shipping added untaxed
 * (invoices only: an estimate has no shipping, so its builder passes none). If
 * the two ever disagree, the server is right and this file has a bug.
 *
 * The sums run in whole cents and round where the server's Decimals do, half
 * up, so a float never moves a cent.
 */

/**
 * A figure as a builder holds it: a number from an input, a decimal string from
 * the API, or nothing yet.
 */
export type Figure = number | string | null | undefined;

/**
 * A line as the builders edit it. A line started from a deal also carries the
 * deal line's discount (`discount_type`, `discount_value`); a typed line has
 * none.
 */
export type Line = {
  name: string;
  description: string;
  quantity: Figure;
  unit_price: Figure;
  product: string | null;
  discount_type?: string;
  discount_value?: Figure;
};

export const num = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);

/**
 * A figure in hundredths (cents of money, hundredths of a percent), rounded
 * half up as `quantize(CENT, ROUND_HALF_UP)` does: away from zero.
 * `toFixed(6)` first, so 1.005 is not read as 1.00499...
 */
export function hundredths(v: Figure) {
  const n = num(v);
  const h = Math.round(Number((Math.abs(n) * 100).toFixed(6)));
  return n < 0 ? -h : h;
}

/** Whole `n / d` rounded half up (away from zero), exact for integers. */
export function divHalfUp(n: number, d: number) {
  const q = Math.floor((2 * Math.abs(n) + d) / (2 * d));
  return n < 0 ? -q : q;
}

/**
 * A line in cents: `gross` is quantity x unit price (`line_gross`) and `net`
 * is that less the line's discount (`line_discount`), each to the cent.
 */
function lineCents(line: Line) {
  const gross = divHalfUp(hundredths(line.quantity) * hundredths(line.unit_price), 100);
  const value = hundredths(line.discount_value);
  const off = line.discount_type === 'PERCENTAGE' ? divHalfUp(gross * value, 10000) : value;
  return { gross, net: gross - off };
}

/** An empty line, the shape both builders edit. */
export const blankLine = (): Line => ({
  name: '',
  description: '',
  quantity: 1,
  unit_price: 0,
  product: null
});

/**
 * What a line adds to the subtotal: quantity x unit price less the line's own
 * discount, the server's `LineAmounts.net_amount`. PERCENTAGE takes that share;
 * any other type with a value takes it as a flat amount, as the server does.
 */
export const lineAmount = (line: Line) => lineCents(line).net / 100;

/**
 * Each line with its `gross` (quantity x unit price) and `amount` (after its
 * own discount), and the lines worth sending: a name, a quantity above zero
 * and a positive gross. The API refuses a quantity of zero or less and a
 * negative price (`LineAmountsMixin`), so a line that would be refused is never
 * offered to it; a half-typed row is dropped rather than blocking save. A line
 * discounted to nothing is still a line, so the check is on the gross.
 */
export function lineTotals(items: Line[]) {
  const lines = items.map((i) => {
    const { gross, net } = lineCents(i);
    return { ...i, gross: gross / 100, amount: net / 100 };
  });
  const usable = lines.filter(
    (l) => l.name.trim() && num(l.quantity) > 0 && num(l.unit_price) >= 0 && l.gross > 0
  );
  return { lines, usable };
}

/** The ladder over the usable lines, in the server's order. Do not reorder. */
export function documentTotals({
  lines,
  discountType = '',
  discountValue = 0,
  taxRate = 0,
  shipping = 0
}: {
  lines: Array<{ amount: number }>;
  discountType?: string;
  discountValue?: Figure;
  taxRate?: Figure;
  shipping?: Figure;
}) {
  const subtotal = lines.reduce((a, l) => a + hundredths(l.amount), 0);
  const discount =
    discountType === 'PERCENTAGE'
      ? divHalfUp(subtotal * hundredths(discountValue), 10000)
      : discountType === 'FIXED'
        ? hundredths(discountValue)
        : 0;
  // Capped at the subtotal, as the server caps it.
  const discountAmount = Math.min(discount, subtotal);
  const taxable = subtotal - discountAmount;
  const taxAmount = divHalfUp(taxable * hundredths(taxRate), 10000);
  return {
    subtotal: subtotal / 100,
    discountAmount: discountAmount / 100,
    taxAmount: taxAmount / 100,
    total: (taxable + taxAmount + hundredths(shipping)) / 100
  };
}

/**
 * The usable lines as the API's nested `line_items`. Only the keys the line
 * create serializers accept; the server computes every per-line figure. A
 * line's discount goes only when it has one.
 */
export function linePayload(usable: Line[]) {
  return usable.map((l) => {
    const row: Record<string, string | number> = {
      name: l.name.trim(),
      description: (l.description || '').trim(),
      quantity: num(l.quantity),
      unit_price: num(l.unit_price)
    };
    if (l.product) row.product = l.product;
    if (num(l.discount_value)) {
      row.discount_type = l.discount_type || '';
      row.discount_value = num(l.discount_value);
    }
    return row;
  });
}

/** Rounded to the cent, as the server stores money, so a float sum does not
    refuse a discount that exactly matches it.
 */
const cents = (v: number) => Math.round(v * 100) / 100;

/**
 * The server's bounds on a discount, in its order and its words
 * (`LineAmountsMixin.validate` for a line, `validate_document_discount` for a
 * document): not negative, a percentage not over 100, and a flat amount not
 * over what it comes off. Returns the message, or '' when the API would take
 * it. A hint only: the API still refuses the rest.
 *
 * @param cap what a flat discount comes off
 */
function discountError(type: string, value: Figure, cap: number, capMessage: string) {
  const v = num(value);
  if (v < 0) return 'A discount cannot be negative.';
  if (type === 'PERCENTAGE') return v > 100 ? 'A percentage discount cannot exceed 100.' : '';
  return v > cents(cap) ? capMessage : '';
}

/**
 * A document's own discount against its subtotal. The builders send a
 * discount only once a type is chosen, so no type is nothing to check.
 */
export const documentDiscountError = (type: string, value: Figure, subtotal: number) =>
  type ? discountError(type, value, subtotal, 'A discount cannot exceed the subtotal.') : '';

/**
 * A line's own discount against its gross. A line only carries one from the
 * deal it came from, and lowering its quantity or price afterwards can leave
 * a flat discount bigger than the line.
 */
export const lineDiscountError = (line: Line) =>
  num(line.discount_value)
    ? discountError(
        line.discount_type ?? '',
        line.discount_value,
        num(line.quantity) * num(line.unit_price),
        "A discount cannot exceed the line's amount."
      )
    : '';

/**
 * The server's bounds on a document's tax rate (a percentage, 0 to 100) and
 * shipping (never negative), in its words. '' when the API would take it.
 */
export function taxRateError(value: Figure) {
  const v = num(value);
  if (v < 0) return 'Tax rate cannot be negative.';
  return v > 100 ? 'Tax rate cannot exceed 100.' : '';
}

export const shippingError = (value: Figure) =>
  num(value) < 0 ? 'Shipping cannot be negative.' : '';

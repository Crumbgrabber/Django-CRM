<script lang="ts">
  import { resolve } from '$app/paths';
  import { money, shortDate } from '#lib/v2/format.js';
  import type { components } from '#lib/api-schema.js';
  let {
    bills,
    showVendor = false,
    currency
  }: { bills: components['schemas']['Bill'][]; showVendor?: boolean; currency: string } = $props();
</script>

{#if bills.length}
  <table class="v2-table">
    <thead
      ><tr
        ><th>Bill number</th>{#if showVendor}<th>Vendor</th>{/if}<th>Bill date</th><th>Due date</th
        ><th>Total</th><th>Paid</th><th>Balance due</th><th>Status</th></tr
      ></thead
    >
    <tbody>
      {#each bills as bill (bill.id)}
        <tr>
          <td data-m="title"
            ><a
              href={resolve('/(app)/vendors/[id]/bills/[billId]', {
                id: bill.vendor,
                billId: bill.id
              })}>{bill.bill_number || 'Unnumbered bill'}</a
            ></td
          >
          {#if showVendor}<td data-m="meta"
              ><a href={resolve('/(app)/vendors/[id]', { id: bill.vendor })}>{bill.vendor_name}</a
              ></td
            >{/if}
          <td data-m="meta">Bill date: {shortDate(bill.bill_date)}</td>
          <td data-m="meta">Due: {bill.due_date ? shortDate(bill.due_date) : 'Not recorded'}</td>
          <td data-m="meta">Total: {money(bill.total_amount, bill.currency || currency)}</td>
          <td data-m="meta">Paid: {money(bill.amount_paid, bill.currency || currency)}</td>
          <td data-m="lead">Balance due: {money(bill.balance_due, bill.currency || currency)}</td>
          <td data-m="tag"
            >{bill.status.replaceAll('_', ' ')}{#if bill.is_overdue}<strong class="overdue"
                >Overdue</strong
              >{/if}</td
          >
        </tr>
      {/each}
    </tbody>
  </table>
{:else}<p>No bills found.</p>{/if}

<style>
  .overdue {
    display: block;
    color: var(--v2-danger, #b42318);
  }
  a {
    display: inline-flex;
    align-items: center;
    min-height: 44px;
    overflow-wrap: anywhere;
  }
</style>

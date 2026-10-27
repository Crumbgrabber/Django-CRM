<script lang="ts">
  import { enhance } from '$app/forms';
  import { resolve } from '$app/paths';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import ConfirmAction from '#lib/v2/components/ConfirmAction.svelte';
  import type { components } from '#lib/api-schema.js';
  import type { FormBody } from '#lib/api-helpers.js';
  type Values = FormBody<components['schemas']['BillRequest']>;
  let {
    data,
    form
  }: {
    data: {
      vendor: components['schemas']['Vendor'] | null;
      vendors?: components['schemas']['Vendor'][];
      bill: components['schemas']['Bill'] | null;
    };
    form: { error?: string; message?: string; values?: Values } | null;
  } = $props();
  const fields = [
    ['bill_number', 'Bill number', 'text'],
    ['bill_date', 'Bill date (billing period end)', 'date'],
    ['due_date', 'Due date', 'date'],
    ['currency', 'Currency (three-letter code)', 'text'],
    ['total_amount', 'Total', 'number'],
    ['amount_paid', 'Paid', 'number']
  ] as const;
  const value = (field: keyof Values): string =>
    String(
      form?.values?.[field] ??
        data.bill?.[field as keyof typeof data.bill] ??
        (field === 'currency' ? data.vendor?.currency || 'USD' : field === 'amount_paid' ? '0' : '')
    );
</script>

<svelte:head><title>{data.bill ? 'Edit bill' : 'New bill'}</title></svelte:head>
<PageHeader title={data.bill ? 'Edit bill' : 'New bill'} center>
  {#snippet crumb()}{#if data.vendor}<a
        href={resolve('/(app)/vendors/[id]', { id: data.vendor.id })}>{data.vendor.name}</a
      >{:else}<a href={resolve('/(app)/bills')}>Bills</a>{/if}{/snippet}
  {#snippet sub()}{#if data.vendor}Vendor: {data.vendor.name}{:else}Choose the vendor this bill is
      from.{/if}{#if data.bill}
      · {data.bill.status.replaceAll('_', ' ')}{/if}{/snippet}
</PageHeader>
<div class="v2-scroll v2-pad">
  {#if form?.error}<p role="alert">{form.error}</p>{/if}
  {#if form?.message}<p role="status">{form.message}</p>{/if}
  <form class="v2-form" method="POST" action="?/save" use:enhance>
    {#if !data.vendor}
      <div class="v2-field">
        <label for="vendor">Vendor</label>
        <select class="v2-input" id="vendor" name="vendor" required>
          <option value="">Choose a vendor</option>
          {#each data.vendors ?? [] as v (v.id)}<option
              value={v.id}
              selected={form?.values?.vendor === v.id}>{v.name}</option
            >{/each}
        </select>
        {#if !data.vendors?.length}<p>
            No vendors yet. <a href={resolve('/(app)/vendors/new')}>Add a vendor</a> first.
          </p>{/if}
      </div>
    {/if}
    {#each fields as [field, label, type] (field)}
      <div class="v2-field">
        <label for={field}>{label}</label>
        <input
          class="v2-input"
          id={field}
          name={field}
          {type}
          value={value(field)}
          required={['bill_date', 'currency', 'total_amount', 'amount_paid'].includes(field)}
          step={type === 'number' ? '0.01' : undefined}
          min={type === 'number' ? '0' : undefined}
          maxlength={field === 'currency' ? 3 : undefined}
        />
      </div>
    {/each}
    <label class="paid"
      ><input type="checkbox" name="paid_in_full" checked={data.bill?.status === 'PAID'} /> Paid in full
      (sets Paid to the total)</label
    >
    <div class="v2-field">
      <label for="notes">Notes</label><textarea class="v2-input" id="notes" name="notes" rows="5"
        >{value('notes')}</textarea
      >
    </div>
    <div class="buttons">
      <button class="v2-btn v2-btn-primary" type="submit">Save</button><a
        class="v2-btn"
        href={data.vendor
          ? resolve('/(app)/vendors/[id]', { id: data.vendor.id })
          : resolve('/(app)/bills')}>Cancel</a
      >
    </div>
  </form>
  {#if data.bill}
    <div class="buttons">
      <ConfirmAction
        action="?/status"
        label={data.bill.status === 'VOID' ? 'Un-void' : 'Void'}
        explain={data.bill.status === 'VOID'
          ? 'Restore this bill. Its status will follow the amounts paid.'
          : 'Void this bill and exclude it from balance due totals.'}
      />
      <ConfirmAction action="?/delete" explain="Permanently delete this bill." />
    </div>
  {/if}
</div>

<style>
  .paid {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    min-height: 44px;
  }
  input,
  select,
  textarea {
    max-width: 100%;
    min-width: 0;
  }
  .buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    margin-top: 24px;
  }
  .buttons :global(button),
  .buttons a {
    min-height: 44px;
  }
</style>

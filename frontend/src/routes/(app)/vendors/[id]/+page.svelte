<script lang="ts">
  import { resolve } from '$app/paths';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import ConfirmAction from '#lib/v2/components/ConfirmAction.svelte';
  import BillsTable from '../BillsTable.svelte';
  import { money } from '#lib/v2/format.js';
  import type { PageProps } from './$types';
  let { data, form }: PageProps = $props();
</script>

<svelte:head><title>{data.vendor.name} | Vendors</title></svelte:head>
<PageHeader title={data.vendor.name} record>
  {#snippet crumb()}<a href={resolve('/(app)/vendors')}>Vendors</a>{/snippet}
  {#snippet sub()}{data.vendor.is_active ? 'Active' : 'Inactive'}{/snippet}
  {#snippet actions()}
    <a class="v2-btn" href={resolve('/(app)/vendors/[id]/edit', { id: data.vendor.id })}
      >Edit vendor</a
    >
    {#if data.vendor.can_delete}<ConfirmAction
        action="?/delete"
        explain="Permanently delete this vendor."
      />{/if}
  {/snippet}
</PageHeader>
<div class="v2-scroll v2-pad">
  {#if form?.error}<p role="alert">{form.error}</p>{/if}
  <dl>
    {#each ['email', 'phone', 'website', 'industry', 'currency', 'address_line', 'city', 'state', 'postcode', 'country', 'description'] as field (field)}
      <div>
        <dt>{field.replaceAll('_', ' ')}</dt>
        <dd>{data.vendor[field as keyof typeof data.vendor] || 'Not recorded'}</dd>
      </div>
    {/each}
  </dl>
  {#if data.billsOn}
    <section aria-labelledby="bills-heading">
      <h2 id="bills-heading">Bills</h2>
      <a class="v2-btn" href={resolve('/(app)/vendors/[id]/bills/new', { id: data.vendor.id })}
        >Add bill</a
      >
      <p>
        Balance due: {#each data.balances as balance (balance.currency)}<span
            >{money(balance.amount, balance.currency)}
          </span>{:else}{money(0, data.vendor.currency || undefined)}{/each}
      </p>
      <BillsTable bills={data.bills} currency={data.org.currency} />
    </section>
  {/if}
</div>

<style>
  section {
    margin-top: 32px;
  }
  section a {
    min-height: 44px;
  }
  dl {
    max-width: 720px;
  }
  dl > div {
    padding: 12px 0;
    border-bottom: 1px solid var(--v2-line);
  }
  dt {
    text-transform: capitalize;
    font-weight: 600;
  }
  dd {
    margin: 6px 0 0;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
</style>

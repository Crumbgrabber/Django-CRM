<script lang="ts">
  import { resolve } from '$app/paths';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import BillsTable from '../vendors/BillsTable.svelte';
  import type { PageProps } from './$types';
  let { data }: PageProps = $props();
  const pageQuery = (offset: number) =>
    new URLSearchParams({
      status: data.status,
      overdue: String(data.overdue),
      offset: String(offset)
    });
</script>

<svelte:head><title>Bills</title></svelte:head>
<PageHeader title="Bills">
  {#snippet sub()}Bills we pay to vendors. {data.bills.count} bills.{/snippet}
  {#snippet actions()}<a class="v2-btn" href={resolve('/(app)/vendors')}>Vendors</a><a
      class="v2-btn v2-btn-primary"
      href={resolve('/(app)/bills/new')}>New bill</a
    >{/snippet}
</PageHeader>
<div class="v2-scroll v2-pad">
  <form method="GET" class="filters">
    <label for="status">Status</label>
    <select class="v2-input" id="status" name="status">
      <option value="">All statuses</option>
      {#each ['UNPAID', 'PARTIALLY_PAID', 'PAID', 'VOID'] as status (status)}<option
          value={status}
          selected={data.status === status}>{status.replaceAll('_', ' ')}</option
        >{/each}
    </select>
    <label class="overdue"
      ><input type="checkbox" name="overdue" value="true" checked={data.overdue} /> Overdue only</label
    >
    <button class="v2-btn" type="submit">Apply filters</button>
  </form>
  <BillsTable bills={data.bills.results} showVendor currency={data.org.currency} />
  <nav class="pagination" aria-label="Bill pages">
    {#if data.bills.previous}<a
        class="v2-btn"
        href="{resolve('/(app)/bills')}?{pageQuery(Math.max(0, data.offset - 25))}">Previous</a
      >{/if}
    {#if data.bills.next}<a
        class="v2-btn"
        href="{resolve('/(app)/bills')}?{pageQuery(data.offset + 25)}">Next</a
      >{/if}
  </nav>
</div>

<style>
  .filters,
  .pagination {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 12px;
    margin-bottom: 20px;
  }
  select {
    width: auto;
    max-width: 100%;
    min-width: 0;
  }
  .overdue,
  button,
  a {
    min-height: 44px;
  }
  .overdue {
    display: inline-flex;
    align-items: center;
    gap: 8px;
  }
</style>

<script lang="ts">
  import { resolve } from '$app/paths';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import EmptyState from '#lib/v2/components/EmptyState.svelte';
  import type { PageProps } from './$types';
  let { data }: PageProps = $props();
</script>

<svelte:head><title>Vendors</title></svelte:head>
<PageHeader title="Vendors">
  {#snippet sub()}Companies and people you pay. {data.vendors.count} vendors.{/snippet}
  {#snippet actions()}<a class="v2-btn v2-btn-primary" href={resolve('/(app)/vendors/new')}
      >New vendor</a
    >{/snippet}
</PageHeader>
<div class="v2-scroll v2-pad">
  <form method="GET" class="search">
    <label for="search">Search vendors</label>
    <input id="search" name="search" value={data.search} placeholder="Vendor name" />
    <button class="v2-btn" type="submit">Search</button>
  </form>
  {#if data.vendors.results.length}
    <table class="v2-table">
      <thead><tr><th>Name</th><th>Email</th><th>Phone</th><th>Status</th></tr></thead>
      <tbody>
        {#each data.vendors.results as vendor (vendor.id)}
          <tr>
            <td data-m="title"
              ><a href={resolve('/(app)/vendors/[id]', { id: vendor.id })}>{vendor.name}</a></td
            >
            <td data-m="meta">{vendor.email || 'No email'}</td>
            <td data-m="meta">{vendor.phone || 'No phone'}</td>
            <td data-m="tag">{vendor.is_active ? 'Active' : 'Inactive'}</td>
          </tr>
        {/each}
      </tbody>
    </table>
    <nav class="pagination" aria-label="Vendor pages">
      {#if data.vendors.previous}<a
          class="v2-btn"
          href="{resolve('/(app)/vendors')}?{new URLSearchParams({
            search: data.search,
            offset: String(Math.max(0, data.offset - 25))
          })}">Previous</a
        >{/if}
      {#if data.vendors.next}<a
          class="v2-btn"
          href="{resolve('/(app)/vendors')}?{new URLSearchParams({
            search: data.search,
            offset: String(data.offset + 25)
          })}">Next</a
        >{/if}
    </nav>
  {:else}
    <EmptyState
      title={data.search ? 'No matching vendors' : 'No vendors yet'}
      body="Add a vendor to keep their contact details in one place."
    />
  {/if}
</div>

<style>
  .search,
  .pagination {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    align-items: center;
    margin-bottom: 20px;
  }
  input {
    min-width: 0;
    max-width: 100%;
    padding: 10px;
    border: 1px solid var(--v2-line);
    border-radius: 6px;
  }
  a,
  button {
    min-height: 44px;
  }
</style>

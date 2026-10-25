<script>
  import { resolve } from '$app/paths';
  import { page } from '$app/state';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import FilterBar from '#lib/v2/components/FilterBar.svelte';
  import Pill from '#lib/v2/components/Pill.svelte';
  import EmptyState from '#lib/v2/components/EmptyState.svelte';
  import { count, shortDate } from '#lib/v2/format.js';
  import {
    PROJECT_STATUS_LABEL,
    PROJECT_STATUS_TONE,
    BILLING_TYPE_LABEL,
    hoursText,
    rowBurn
  } from '#lib/v2/projects.js';
  import { Briefcase, Plus, Search } from '@lucide/svelte';

  /** @type {{ data: any }} */
  let { data } = $props();

  let projects = $derived(data.projects);

  /** The filters in the URL, kept by the search form so a search narrows them. */
  let kept = $derived(
    [...page.url.searchParams.entries()].filter(([key]) => key !== 'q' && key !== 'offset')
  );
</script>

<PageHeader title="Projects">
  {#snippet sub()}
    <span class="v2-num">{count(data.totals.count)}</span>
    {data.totals.count === 1 ? 'project' : 'projects'}
  {/snippet}
  {#snippet actions()}
    <a class="v2-btn v2-btn-primary" href={resolve('projects/new')}><Plus />New project</a>
  {/snippet}
</PageHeader>

<FilterBar
  page="projects"
  url={page.url}
  people={data.people}
  accounts={data.accounts}
  meId={data.meId}
  meta="Newest first"
/>

<div class="v2-pad" style="padding-top:10px;flex:none">
  <form method="GET" class="search" role="search">
    {#each kept as [key, value], i (`${key}-${i}`)}
      <input type="hidden" name={key} {value} />
    {/each}
    <input
      class="v2-input"
      type="search"
      name="q"
      value={data.q}
      placeholder="Search by name"
      aria-label="Search projects by name"
    />
    <button class="v2-btn" type="submit"><Search size={13} />Search</button>
  </form>
</div>

{#if projects.length === 0}
  <div class="v2-scroll">
    <EmptyState
      title={data.q || page.url.search ? 'No projects match' : 'No projects yet'}
      body={data.q || page.url.search
        ? 'Nothing matches this view. Clear a filter or the search to see more.'
        : 'A project holds the work for a client: its tasks, the time logged on it, and the invoices that bill it. Start one here, or from a won deal.'}
    >
      {#snippet icon()}<Briefcase size={21} />{/snippet}
      {#snippet actions()}
        <a class="v2-btn v2-btn-primary" href={resolve('projects/new')}>New project</a>
      {/snippet}
    </EmptyState>
  </div>
{:else}
  <div class="v2-scroll">
    <div class="v2-table-wrap">
      <table class="v2-table">
        <thead>
          <tr>
            <th>Project</th>
            <th>Status</th>
            <th>Budget used</th>
            <th class="v2-r">Logged</th>
            <th>Due</th>
            <th>Billing</th>
          </tr>
        </thead>
        <tbody>
          {#each projects as p (p.id)}
            {@const burn = rowBurn(p.burn)}
            <tr>
              <td data-m="title">
                <a class="v2-row-link" href={resolve(`projects/${p.id}`)}>
                  <div class="v2-table-primary">{p.name}</div>
                  <div class="v2-table-secondary">{p.account.name}</div>
                </a>
              </td>
              <td data-m="tag">
                <Pill tone={PROJECT_STATUS_TONE[p.status] ?? 'slate'}>
                  {PROJECT_STATUS_LABEL[p.status] ?? p.status}
                </Pill>
              </td>
              <td data-m="bar" class="burn-cell">
                {#if burn}
                  <div class="v2-bar" role="img" aria-label={burn.label}>
                    <i style="width:{burn.width}%;background:var(--v2-{burn.tone})"></i>
                  </div>
                  <div class="burn-label" style="color:var(--v2-{burn.tone})">{burn.label}</div>
                {:else}
                  <span class="v2-sub burn-label">No budget set</span>
                {/if}
              </td>
              <td class="v2-r v2-num" data-m="meta" data-l="logged">
                {hoursText(p.burn.logged_hours)}
              </td>
              <td data-m="meta">{p.due_date ? `Due ${shortDate(p.due_date)}` : ''}</td>
              <td data-m="hide" class="v2-sub">{BILLING_TYPE_LABEL[p.billing_type] ?? ''}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
    <p class="v2-sub v2-pad" style="font-size:12px;padding-bottom:24px">
      Showing <span class="v2-num">{projects.length}</span> of
      <span class="v2-num">{count(data.totals.count)}</span>
    </p>
  </div>
{/if}

<style>
  .search {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }
  .search .v2-input {
    flex: 1 1 14rem;
    min-width: 0;
    max-width: 28rem;
  }
  .burn-cell {
    min-width: 140px;
  }
  .burn-label {
    font-size: 11.5px;
    margin-top: 4px;
  }
  @media (max-width: 768px) {
    .search .v2-input,
    .search .v2-btn {
      min-height: 44px;
    }
    .search .v2-input {
      max-width: none;
    }
  }
</style>

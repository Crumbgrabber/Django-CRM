<script>
  import { resolve } from '$app/paths';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import ProjectForm from '#lib/v2/components/ProjectForm.svelte';
  import { isOrgAdmin } from '#lib/admin.js';
  import { ChevronRight } from '@lucide/svelte';

  /** @type {import('./$types').PageProps} */
  let { data, form } = $props();

  /** Only a refused save carries per-field messages; a form that would not build has none. */
  let fieldErrors = $derived(
    form && 'fieldErrors' in form
      ? /** @type {Record<string, string> | undefined} */ (form.fieldErrors)
      : undefined
  );
</script>

<PageHeader title="New project" record center width="62ch">
  {#snippet crumb()}
    <a href={resolve('projects')}>Projects</a>
    <ChevronRight size={12} />
    <span>New</span>
  {/snippet}
</PageHeader>

<div class="v2-scroll">
  <div class="v2-pad">
    {#if data.fromDeal}
      <p class="v2-sub note">
        Filled from the deal {data.fromDeal.name}. Nothing is saved until you create the project.
      </p>
    {:else if data.draftMissed}
      <p class="v2-sub note">
        That deal could not be opened, so the form starts empty. Pick the account below.
      </p>
    {/if}
    <ProjectForm
      action="?/create"
      submitLabel="Create project"
      values={data.values}
      typed={form?.values}
      error={form?.error}
      accounts={data.accounts}
      deals={data.deals}
      people={data.people}
      peopleFailed={data.peopleFailed}
      stored={data.stored}
      customFields={data.customFields}
      isAdmin={isOrgAdmin(data)}
      {fieldErrors}
      cancelHref={data.fromDeal?.id ? `/pipeline/${data.fromDeal.id}` : '/projects'}
    />
  </div>
</div>

<style>
  .note {
    max-width: 62ch;
    margin: 16px auto 0;
    font-size: 12.5px;
  }
</style>

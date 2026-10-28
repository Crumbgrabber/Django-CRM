<script lang="ts">
  import { enhance } from '$app/forms';
  import { resolve } from '$app/paths';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import { CURRENCY_CODES } from '#lib/constants/filters.js';
  import type { components } from '#lib/api-schema.js';
  import type { FormBody } from '#lib/api-helpers.js';
  type Vendor = components['schemas']['Vendor'];
  type Values = FormBody<components['schemas']['VendorRequest']>;
  let {
    data,
    form
  }: {
    data: {
      org: { currency: string };
      vendor: Vendor | null;
      options: {
        industries: { value: string; label: string }[];
        countries: { value: string; label: string }[];
      };
      people: {
        people: { id: string; name: string }[];
        teams: { id: string; name: string }[];
        options_failed: boolean;
      };
    };
    form: { error?: string; values?: Values } | null;
  } = $props();
  const fields = [
    ['name', 'Name', 'text'],
    ['email', 'Email', 'email'],
    ['phone', 'Phone', 'tel'],
    ['website', 'Website', 'url'],
    ['address_line', 'Address', 'text'],
    ['city', 'City', 'text'],
    ['state', 'State', 'text'],
    ['postcode', 'Postal code', 'text']
  ] as const;
  const value = (field: keyof Values): string =>
    String(form?.values?.[field] ?? data.vendor?.[field as keyof Vendor] ?? '');
  const selected = (field: 'assigned_to' | 'teams'): string[] => {
    const v = form?.values?.[field] ?? data.vendor?.[field] ?? [];
    return Array.isArray(v) ? v.map(String) : [];
  };
  const currency = $derived(
    data.vendor ? value('currency') : value('currency') || data.org.currency
  );
</script>

<svelte:head><title>{data.vendor ? 'Edit vendor' : 'New vendor'}</title></svelte:head>
<PageHeader title={data.vendor ? 'Edit vendor' : 'New vendor'} center>
  {#snippet crumb()}<a href={resolve('/(app)/vendors')}>Vendors</a>{/snippet}
</PageHeader>
<div class="v2-scroll v2-pad">
  <form class="v2-form" method="POST" action="?/save" use:enhance>
    {#if form?.error}<p role="alert">{form.error}</p>{/if}
    {#each fields as [field, label, type] (field)}
      <div class="v2-field">
        <label for={field}>{label}</label>
        <input
          class="v2-input"
          id={field}
          name={field}
          {type}
          value={value(field)}
          required={field === 'name'}
          maxlength={field === 'name' ? 255 : undefined}
        />
      </div>
    {/each}
    <div class="v2-field">
      <label for="currency">Currency</label>
      <select class="v2-input" id="currency" name="currency">
        <option value="">Not recorded</option>
        {#if currency && !CURRENCY_CODES.some((c) => c.value === currency)}<option
            value={currency}
            selected>{currency}</option
          >{/if}
        {#each CURRENCY_CODES.filter((c) => c.value) as option (option.value)}<option
            value={option.value}
            selected={option.value === currency}>{option.label}</option
          >{/each}
      </select>
    </div>
    {#each ['industry', 'country'] as field (field)}
      {@const options = field === 'industry' ? data.options.industries : data.options.countries}
      {@const current = value(field as 'industry' | 'country')}
      <div class="v2-field">
        <label for={field}>{field === 'industry' ? 'Industry' : 'Country'}</label>
        <select class="v2-input" id={field} name={field}>
          <option value="">Not recorded</option>
          {#if current && !options.some((o) => o.value === current)}<option value={current} selected
              >{current}</option
            >{/if}
          {#each options as option (option.value)}<option
              value={option.value}
              selected={option.value === current}>{option.label}</option
            >{/each}
        </select>
      </div>
    {/each}
    {#if data.people.options_failed}
      <p>People and teams could not be loaded. Existing assignments will be kept.</p>
    {:else}
      {#each ['assigned_to', 'teams'] as field (field)}
        {@const key = field as 'assigned_to' | 'teams'}
        {@const options = key === 'assigned_to' ? data.people.people : data.people.teams}
        <div class="v2-field">
          <label for={field}>{key === 'assigned_to' ? 'Assigned to' : 'Teams'}</label>
          <input type="hidden" name={`${field}_present`} value="1" />
          <select class="v2-input" id={field} name={field} multiple>
            {#each selected(key).filter((id) => !options.some((o) => o.id === id)) as id (id)}<option
                value={id}
                selected>{id}</option
              >{/each}
            {#each options as option (option.id)}<option
                value={option.id}
                selected={selected(key).includes(option.id)}>{option.name}</option
              >{/each}
          </select>
        </div>
      {/each}
    {/if}
    <div class="v2-field">
      <label for="description">Notes</label><textarea
        class="v2-input"
        id="description"
        name="description"
        rows="5">{value('description')}</textarea
      >
    </div>
    <label class="active"
      ><input
        type="checkbox"
        name="is_active"
        checked={form?.values ? form.values.is_active === true : data.vendor?.is_active !== false}
      /> Active</label
    >
    <div class="buttons">
      <button class="v2-btn v2-btn-primary" type="submit">Save vendor</button>
      <a
        class="v2-btn"
        href={data.vendor
          ? resolve('/(app)/vendors/[id]', { id: data.vendor.id })
          : resolve('/(app)/vendors')}>Cancel</a
      >
    </div>
  </form>
</div>

<style>
  input,
  select,
  textarea {
    max-width: 100%;
    min-width: 0;
  }
  .active,
  .buttons {
    display: flex;
    align-items: center;
    gap: 12px;
    min-height: 44px;
  }
  .buttons {
    flex-wrap: wrap;
    margin-top: 24px;
  }
  button,
  a {
    min-height: 44px;
  }
</style>

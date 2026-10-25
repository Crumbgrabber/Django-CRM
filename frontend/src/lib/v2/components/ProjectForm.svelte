<script>
  import { enhance } from '$app/forms';
  import { resolve } from '$app/paths';
  import { untrack } from 'svelte';
  import { asInternalPath } from '#lib/utils/paths.js';
  import RecordFieldInputs from '#lib/v2/components/RecordFieldInputs.svelte';
  import { CURRENCY_CODES } from '#lib/constants/filters.js';
  import { missingOption, missingOptions, inactiveOptionLabel } from '#lib/v2/pickers.js';
  import {
    PROJECT_STATUSES,
    PROJECT_STATUS_LABEL,
    BILLING_TYPES,
    BILLING_TYPE_LABEL,
    hoursText
  } from '#lib/v2/projects.js';
  import { money } from '#lib/v2/format.js';
  import { Plus, X } from '@lucide/svelte';

  /**
   * The new and edit project form. Values are what the record holds (or the
   * draft from a deal); `typed` is what a refused save sent back, which wins.
   * A stored account, deal, person or currency the pickers cannot offer is
   * kept as its own option, so saving something else never clears it.
   *
   * The people and rates lists post a `__rendered` marker only when the
   * people loaded: without it the action sends neither list, and a page that
   * could not load the team cannot empty the project of it.
   *
   * The money fields (billing type, currency, budgets, rates) are an admin's:
   * a member's form shows them read-only on edit, hides them on create, and
   * sends none of them. The account is set by anyone on create, then only by
   * an admin. The API ignores what a member sends for any of these anyway.
   *
   * @type {{
   *   action: string,
   *   submitLabel: string,
   *   values: Record<string, any>,
   *   typed?: Record<string, any> | null,
   *   error?: string | null,
   *   accounts: { id: string, name: string }[],
   *   deals?: { id: string, name: string }[] | null,
   *   people: { id: string, name: string }[],
   *   peopleFailed?: boolean,
   *   stored?: { account?: any, deal?: any, people?: any[] },
   *   customFields?: any[],
   *   fieldErrors?: Record<string, string> | null,
   *   edit?: boolean,
   *   isAdmin?: boolean,
   *   cancelHref: string
   * }}
   */
  let {
    action,
    submitLabel,
    values,
    typed = null,
    error = null,
    accounts,
    deals = null,
    people,
    peopleFailed = false,
    stored = {},
    customFields = [],
    fieldErrors = null,
    edit = false,
    isAdmin = false,
    cancelHref
  } = $props();

  let v = $derived({ ...values, ...(typed ?? {}) });

  let billingType = $state(
    untrack(() => typed?.billing_type || values.billing_type || 'time_and_materials')
  );
  /** @type {{ key: number, profile: string, hourly_rate: string }[]} */
  let rates = $state(
    untrack(() =>
      (typed?.rates ?? values.rates ?? []).map((/** @type {any} */ r, /** @type {number} */ i) => ({
        key: i,
        profile: r.profile ?? '',
        hourly_rate: r.hourly_rate == null ? '' : String(r.hourly_rate)
      }))
    )
  );
  let nextKey = $state(untrack(() => rates.length + 1));
  let busy = $state(false);

  let extraAccount = $derived(missingOption(accounts, stored.account));
  let extraDeal = $derived(deals ? missingOption(deals, stored.deal) : null);
  let extraPeople = $derived(missingOptions(people, stored.people ?? []));
  let allPeople = $derived([
    ...people,
    ...extraPeople.map((p) => ({ id: p.id, name: inactiveOptionLabel(p.name) }))
  ]);
  let currencies = $derived(
    CURRENCY_CODES.filter((c) => c.value).some((c) => c.value === v.currency) || !v.currency
      ? CURRENCY_CODES.filter((c) => c.value)
      : [{ value: v.currency, label: v.currency }, ...CURRENCY_CODES.filter((c) => c.value)]
  );
  let assigned = $derived(new Set(v.assigned_to ?? []));
  let accountName = $derived(
    [...accounts, stored.account].find((a) => a?.id === v.account)?.name ?? ''
  );
  let personName = $derived(
    (/** @type {string} */ id) => allPeople.find((p) => p.id === id)?.name ?? 'Someone'
  );
  /** @param {unknown} value */
  const isSet = (value) => value !== null && value !== undefined && value !== '';

  function addRate() {
    rates.push({ key: nextKey, profile: '', hourly_rate: '' });
    nextKey += 1;
  }
  /** @param {number} key */
  function dropRate(key) {
    rates = rates.filter((r) => r.key !== key);
  }
</script>

<form
  method="POST"
  {action}
  class="pf"
  use:enhance={() => {
    busy = true;
    return async ({ update }) => {
      busy = false;
      await update({ reset: false });
    };
  }}
>
  {#if error}
    <p class="pf-error" role="alert">{error}</p>
  {/if}

  <label class="v2-field">
    <span class="v2-label">Project</span>
    <input
      class="v2-input"
      name="name"
      required
      maxlength="255"
      value={v.name ?? ''}
      placeholder="Website rebuild, phase one"
    />
  </label>

  {#if isAdmin || !edit}
    <label class="v2-field">
      <span class="v2-label">Account</span>
      <select class="v2-input" name="account" required value={v.account ?? ''}>
        <option value="">Choose the client…</option>
        {#if extraAccount}
          <option value={extraAccount.id}>{extraAccount.name}</option>
        {/if}
        {#each accounts as a (a.id)}
          <option value={a.id}>{a.name}</option>
        {/each}
      </select>
    </label>
  {:else}
    <div class="v2-field">
      <span class="v2-label">Account</span>
      <p class="pf-static">{accountName || 'Not set'}</p>
    </div>
  {/if}

  {#if deals}
    <label class="v2-field">
      <span class="v2-label">From deal</span>
      <select class="v2-input" name="deal" value={v.deal ?? ''}>
        <option value="">None</option>
        {#if extraDeal}
          <option value={extraDeal.id}>{extraDeal.name}</option>
        {/if}
        {#each deals as d (d.id)}
          <option value={d.id}>{d.name}</option>
        {/each}
      </select>
    </label>
  {/if}

  <div class="pf-row">
    <label class="v2-field">
      <span class="v2-label">Status</span>
      <select class="v2-input" name="status" value={v.status || 'active'}>
        {#each PROJECT_STATUSES as s (s)}
          <option value={s}>{PROJECT_STATUS_LABEL[s]}</option>
        {/each}
      </select>
    </label>
    {#if isAdmin}
      <label class="v2-field">
        <span class="v2-label">Billing</span>
        <select class="v2-input" name="billing_type" bind:value={billingType}>
          {#each BILLING_TYPES as b (b)}
            <option value={b}>{BILLING_TYPE_LABEL[b]}</option>
          {/each}
        </select>
      </label>
      <label class="v2-field">
        <span class="v2-label">Currency</span>
        <select class="v2-input" name="currency" value={v.currency ?? ''}>
          {#each currencies as c (c.value)}
            <option value={c.value}>{c.value}</option>
          {/each}
        </select>
      </label>
    {/if}
  </div>

  {#if isAdmin}
    <div class="pf-row">
      <label class="v2-field">
        <span class="v2-label">Budget hours</span>
        <input
          class="v2-input"
          name="budget_hours"
          type="number"
          inputmode="decimal"
          min="0"
          step="0.01"
          value={v.budget_hours ?? ''}
          placeholder="Optional"
        />
      </label>
      <label class="v2-field">
        <span class="v2-label">{billingType === 'fixed_fee' ? 'Fixed fee' : 'Budget amount'}</span>
        <input
          class="v2-input"
          name="budget_amount"
          type="number"
          inputmode="decimal"
          min="0"
          step="0.01"
          value={v.budget_amount ?? ''}
          placeholder="Optional"
        />
      </label>
      <label class="v2-field">
        <span class="v2-label">Hourly rate</span>
        <input
          class="v2-input"
          name="hourly_rate"
          type="number"
          inputmode="decimal"
          min="0"
          step="0.01"
          value={v.hourly_rate ?? ''}
          placeholder="Optional"
        />
      </label>
    </div>
    <p class="v2-sub pf-hint">
      Time logged on the project takes the person's own rate below, else this hourly rate. You hear
      at 80% and at 100% of either budget.
    </p>
  {:else if edit}
    <div class="v2-field">
      <span class="v2-label">Billing, set by an admin</span>
      <dl class="v2-kv pf-kv">
        <dt>Billing</dt>
        <dd>{BILLING_TYPE_LABEL[v.billing_type] ?? ''}</dd>
        <dt>Currency</dt>
        <dd>{v.currency ?? ''}</dd>
        <dt>Budget hours</dt>
        <dd>{isSet(v.budget_hours) ? hoursText(v.budget_hours) : 'Not set'}</dd>
        <dt>{v.billing_type === 'fixed_fee' ? 'Fixed fee' : 'Budget amount'}</dt>
        <dd>{isSet(v.budget_amount) ? money(v.budget_amount, v.currency) : 'Not set'}</dd>
        <dt>Hourly rate</dt>
        <dd>{isSet(v.hourly_rate) ? `${money(v.hourly_rate, v.currency)}/hr` : 'Not set'}</dd>
        {#each rates as r (r.key)}
          <dt>{personName(r.profile)}</dt>
          <dd>{isSet(r.hourly_rate) ? `${money(r.hourly_rate, v.currency)}/hr` : 'Not set'}</dd>
        {/each}
      </dl>
    </div>
  {:else}
    <p class="v2-sub pf-hint">
      An admin sets the billing, budgets and rates once the project exists.
    </p>
  {/if}

  <div class="pf-row">
    <label class="v2-field">
      <span class="v2-label">Start</span>
      <input class="v2-input" type="date" name="start_date" value={v.start_date ?? ''} />
    </label>
    <label class="v2-field">
      <span class="v2-label">Due</span>
      <input class="v2-input" type="date" name="due_date" value={v.due_date ?? ''} />
    </label>
  </div>

  <fieldset class="v2-field pf-set">
    <legend class="v2-label">People</legend>
    {#if peopleFailed}
      <p class="v2-sub pf-hint">
        The team could not be loaded, so the people and rates are left as they are.
      </p>
    {:else}
      <input type="hidden" name="assigned__rendered" value="1" />
      <div class="pf-people">
        {#each allPeople as p (p.id)}
          <label class="pf-check">
            <input type="checkbox" name="assigned_to" value={p.id} checked={assigned.has(p.id)} />
            <span>{p.name}</span>
          </label>
        {:else}
          <p class="v2-sub pf-hint">Nobody to add yet.</p>
        {/each}
      </div>
    {/if}
  </fieldset>

  {#if isAdmin && !peopleFailed}
    <fieldset class="v2-field pf-set">
      <legend class="v2-label">Rates per person</legend>
      <input type="hidden" name="rates__rendered" value="1" />
      {#each rates as r (r.key)}
        <div class="pf-rate">
          <select class="v2-input" name="rate_profile" bind:value={r.profile} aria-label="Person">
            <option value="">Choose a person…</option>
            {#each allPeople as p (p.id)}
              <option value={p.id}>{p.name}</option>
            {/each}
          </select>
          <input
            class="v2-input"
            name="rate_amount"
            type="number"
            inputmode="decimal"
            min="0"
            step="0.01"
            bind:value={r.hourly_rate}
            placeholder="Rate per hour"
            aria-label="Rate per hour"
          />
          <button
            type="button"
            class="v2-btn pf-drop"
            onclick={() => dropRate(r.key)}
            aria-label="Remove this rate"
            title="Remove this rate"
          >
            <X size={13} />
          </button>
        </div>
      {/each}
      <button type="button" class="v2-btn" onclick={addRate}><Plus size={13} />Add a rate</button>
    </fieldset>
  {/if}

  <label class="v2-field">
    <span class="v2-label">Description</span>
    <textarea class="v2-input" name="description" rows="4" value={v.description ?? ''}></textarea>
  </label>

  <RecordFieldInputs
    fields={customFields}
    typed={typed?.custom_fields}
    errors={fieldErrors}
    {edit}
    heading="Details"
  />

  <div class="pf-actions">
    <button class="v2-btn v2-btn-primary" type="submit" disabled={busy}>{submitLabel}</button>
    <a class="v2-btn" href={resolve(asInternalPath(cancelHref))}>Cancel</a>
  </div>
</form>

<style>
  .pf {
    padding-top: 18px;
    padding-bottom: 36px;
    max-width: 62ch;
    margin-left: auto;
    margin-right: auto;
  }
  .pf-error {
    color: var(--v2-rust);
    font-size: 12.5px;
    margin: 0 0 14px;
  }
  .pf-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }
  .pf-row > .v2-field {
    flex: 1 1 150px;
    min-width: 0;
  }
  .pf-hint {
    font-size: 11.5px;
    margin: -6px 0 16px;
  }
  .pf-set {
    border: 0;
    padding: 0;
    margin: 0 0 16px;
    min-width: 0;
  }
  .pf-set legend {
    margin-bottom: 6px;
  }
  .pf-people {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 2px 12px;
    max-height: 240px;
    overflow-y: auto;
  }
  .pf-check {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 36px;
    font-size: 13px;
    cursor: pointer;
    min-width: 0;
    overflow-wrap: anywhere;
  }
  .pf-rate {
    display: grid;
    grid-template-columns: minmax(0, 2fr) minmax(0, 1fr) auto;
    gap: 8px;
    margin-bottom: 8px;
  }
  .pf-static {
    margin: 0;
    font-size: 13px;
    font-weight: 500;
    overflow-wrap: anywhere;
  }
  .pf-kv {
    margin-top: 4px;
  }
  .pf-actions {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
    margin-top: 8px;
  }
  @media (max-width: 768px) {
    .pf-check,
    .pf-actions .v2-btn,
    .pf-set .v2-btn,
    .pf .v2-input {
      min-height: 44px;
    }
  }
</style>

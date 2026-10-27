<script lang="ts">
  import { resolve } from '$app/paths';
  import { enhance, type SubmitFunction } from '$app/forms';
  import { onMount, untrack } from 'svelte';
  import { asInternalPath } from '#lib/utils/paths.js';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import ConfirmAction from '#lib/v2/components/ConfirmAction.svelte';
  import Pill from '#lib/v2/components/Pill.svelte';
  import StatCard from '#lib/v2/components/StatCard.svelte';
  import Avatar from '#lib/v2/components/Avatar.svelte';
  import Timeline from '#lib/v2/components/Timeline.svelte';
  import CustomFieldsCard from '#lib/v2/components/CustomFieldsCard.svelte';
  import CommentComposer from '#lib/v2/components/CommentComposer.svelte';
  import FileList from '#lib/v2/components/FileList.svelte';
  import { money, longDate, shortDate, shortAge, hoursMinutes as hm } from '#lib/v2/format.js';
  import {
    INVOICE_STATUS_TONE,
    TASK_STATUS,
    TASK_STATUS_TONE,
    invoiceStatusLabel
  } from '#lib/v2/enums.js';
  import {
    BILL_GROUPINGS,
    BILLING_TYPE_LABEL,
    PROJECT_STATUS_LABEL,
    PROJECT_STATUS_TONE,
    billActionUrl,
    burnMeter,
    defaultBillable,
    hoursText,
    unratedText
  } from '#lib/v2/projects.js';
  import { isOrgAdmin } from '#lib/admin.js';
  import { isBilled } from '#lib/v2/time-entry.js';
  import { ChevronRight, Play, Plus, Square, Trash2 } from '@lucide/svelte';
  import type { components } from '#lib/api-schema.js';
  import type { PageProps } from './$types';

  let { data, form }: PageProps = $props();

  let project = $derived(data.project);
  let burn = $derived(project.burn);
  let hoursMeter = $derived(burnMeter(burn.hours_percent));
  let amountMeter = $derived(burnMeter(burn.amount_percent));
  let isFixedFee = $derived(project.billing_type === 'fixed_fee');
  let billable = $derived(defaultBillable(project.billing_type));
  let isAdmin = $derived(isOrgAdmin(data));
  /** Rates kept for someone no longer on the project, listed after the team. */
  let offTeamRates = $derived(
    project.rates.filter((r) => !project.assigned_to.some((p) => p.id === r.profile.id))
  );

  const TABS: { key: string; label: string; on: 'tasks' | 'timesheet' | 'invoices' | null }[] = [
    { key: 'overview', label: 'Overview', on: null },
    { key: 'tasks', label: 'Tasks', on: 'tasks' },
    { key: 'time', label: 'Time', on: 'timesheet' },
    { key: 'invoices', label: 'Invoices', on: 'invoices' },
    { key: 'files', label: 'Files', on: null },
    { key: 'comments', label: 'Comments', on: null }
  ];
  let tabs = $derived(TABS.filter((t) => !t.on || data.on[t.on]));

  /* A link to a tab works without JavaScript (the page reloads on it); with
     it, the tab switches in place. A refused write reopens its own tab. */
  let tab = $state(
    untrack(() => {
      if (form?.timeError) return 'time';
      if (form?.noteError) return 'comments';
      return TABS.some((t) => t.key === data.tab) ? data.tab : 'overview';
    })
  );
  let shown = $derived(tabs.some((t) => t.key === tab) ? tab : 'overview');

  function pick(e: MouseEvent, key: string) {
    e.preventDefault();
    tab = key;
  }

  /* ── time, as on the ticket page ─────────────────────────────────────── */
  let entries = $derived(data.time.entries);
  let sinceLoad = $state(0);
  onMount(() => {
    const opened = Date.now();
    const id = setInterval(() => {
      sinceLoad = Math.floor((Date.now() - opened) / 60000);
    }, 30000);
    return () => clearInterval(id);
  });
  type TimeEntry = components['schemas']['TimeEntry'];
  const runningMinutes = (entry: TimeEntry) =>
    Math.floor((Date.parse(data.time.now) - Date.parse(entry.started_at)) / 60000) + sinceLoad;
  const isMine = (entry: TimeEntry) => entry.profile?.user_details?.id === data.time.viewerUserId;
  let myTimer = $derived((entries ?? []).find((e) => !e.ended_at && isMine(e)));
  let timeBusy = $state(false);
  let confirmDelete = $state('');

  const timeSubmit: SubmitFunction = () => {
    timeBusy = true;
    return async ({ update }) => {
      timeBusy = false;
      await update({ reset: false });
    };
  };

  /** Task titles by id, for the time rows and the log form. */
  let taskTitles = $derived(new Map((data.tasks ?? []).map((t) => [t.id, t.title])));
  let tasksView = $state('list');

  let amountMode = $state('amount');
  let billing = $state(false);
</script>

<PageHeader title={project.name} record>
  {#snippet crumb()}
    <a href={resolve('projects')}>Projects</a>
    {#if project.account.id}
      <ChevronRight size={12} />
      <a href={resolve(`accounts/${project.account.id}`)}>{project.account.name}</a>
    {/if}
  {/snippet}
  {#snippet sub()}
    <Pill tone={PROJECT_STATUS_TONE[project.status] ?? 'slate'}>
      {PROJECT_STATUS_LABEL[project.status] ?? project.status}
    </Pill>
    <span>{BILLING_TYPE_LABEL[project.billing_type] ?? ''}</span>
    {#if project.deal}
      <span>· from <a href={resolve(`pipeline/${project.deal.id}`)}>{project.deal.name}</a></span>
    {/if}
    {#if project.estimate}
      <span>· from estimate <span class="v2-num">{project.estimate.estimate_number}</span></span>
    {/if}
  {/snippet}
  {#snippet actions()}
    {#if data.canEdit}
      <a class="v2-btn" href={resolve(`projects/${project.id}/edit`)}>Edit</a>
    {/if}
    {#if data.offers.billTime}
      <a class="v2-btn" href={resolve(asInternalPath(`/projects/${project.id}?bill=1`))}
        >Bill time</a
      >
    {/if}
    {#if data.canDelete}
      <ConfirmAction
        action="?/delete"
        label="Delete"
        confirmLabel="Delete for good"
        explain="Deletes {project.name}. Its tasks, time and invoices stay, no longer linked to it."
      />
    {/if}
  {/snippet}
</PageHeader>

{#if form?.error}
  <div class="v2-pad" style="padding-top:12px;flex:none">
    <p class="p-error" role="alert">{form.error}</p>
  </div>
{/if}

<nav class="v2-tabs" aria-label="Project sections">
  {#each tabs as t (t.key)}
    <a
      href={resolve(asInternalPath(`/projects/${project.id}?tab=${t.key}`))}
      aria-current={shown === t.key ? 'page' : undefined}
      onclick={(e) => pick(e, t.key)}
    >
      {t.label}
    </a>
  {/each}
</nav>

<div class="v2-scroll">
  <div class="v2-pad" style="padding-top:16px;padding-bottom:36px">
    {#if data.bill.open}
      {@const u = data.bill.unbilled}
      <section class="v2-card panel" aria-labelledby="bill-head">
        <div class="panel-head">
          <div class="v2-label" id="bill-head">Bill time</div>
          <a class="v2-btn v2-btn-sm" href={resolve(`projects/${project.id}`)}>Close</a>
        </div>
        <form method="GET" class="bill-date">
          <input type="hidden" name="bill" value="1" />
          <label class="v2-field">
            <span class="v2-label">Bill up to</span>
            <input class="v2-input" type="date" name="up_to" value={data.bill.upTo} />
          </label>
          <button class="v2-btn" type="submit">Check</button>
        </form>
        {#if u === null}
          <p class="v2-sub panel-text">
            The preview could not be loaded. The invoice still takes every billable entry not yet
            billed up to this date.
          </p>
        {:else if u.entry_count === 0}
          <p class="v2-sub panel-text">
            Nothing to bill up to {longDate(data.bill.upTo)}. Every billable entry before then is
            already billed.
          </p>
        {:else}
          <p class="panel-text">
            <b class="v2-num">{u.entry_count}</b>
            {u.entry_count === 1 ? 'entry' : 'entries'},
            <b class="v2-num">{hoursText(u.hours)}</b>,
            <b class="v2-num">{money(u.value, u.currency ?? project.currency)}</b>
            not yet billed, up to {longDate(data.bill.upTo)}.
          </p>
          {#if unratedText(u.unrated_count)}
            <p class="panel-text unrated">{unratedText(u.unrated_count)}</p>
          {/if}
        {/if}
        <form
          method="POST"
          action={billActionUrl(data.bill.upTo)}
          class="bill-go"
          use:enhance={() => {
            billing = true;
            return async ({ update }) => {
              billing = false;
              await update({ reset: false });
            };
          }}
        >
          <input type="hidden" name="up_to" value={data.bill.upTo} />
          <label class="v2-field">
            <span class="v2-label">Invoice lines</span>
            <select class="v2-input" name="group_by" value="entry">
              {#each BILL_GROUPINGS as g (g.value)}
                <option value={g.value}>{g.label}</option>
              {/each}
            </select>
          </label>
          <button
            class="v2-btn v2-btn-primary"
            type="submit"
            disabled={billing || (u !== null && u.entry_count === 0)}
          >
            Create draft invoice
          </button>
        </form>
        <p class="v2-hint">
          The entries are marked billed. Cancelling the invoice frees them to be billed again.
        </p>
        {#if form?.billError}
          <p class="v2-error" role="alert">{form.billError}</p>
        {/if}
      </section>
    {/if}

    {#if shown === 'overview'}
      <div class="v2-stats">
        <StatCard
          label="Hours logged"
          value={hoursText(burn.logged_hours)}
          tone={hoursMeter?.tone ?? 'ink'}
          detail={project.budget_hours !== null
            ? `${burn.hours_percent ?? 0}% of ${hoursText(project.budget_hours)}`
            : 'No hours budget'}
        />
        <StatCard
          label="Billable value"
          value={money(burn.billable_value, project.currency)}
          tone={amountMeter?.tone ?? 'slate'}
          detail={project.budget_amount !== null
            ? `${burn.amount_percent ?? 0}% of ${money(project.budget_amount, project.currency)}`
            : 'No budget amount'}
        />
        <StatCard
          label="Not yet billed"
          value={money(burn.unbilled_value, project.currency)}
          tone={burn.unbilled_value > 0 ? 'clay' : 'slate'}
          detail="Billable time with no invoice"
        />
        {#if burn.invoiced_amount !== null}
          <StatCard
            label="Invoiced"
            value={money(burn.invoiced_amount, project.currency)}
            tone="slate"
            detail={isFixedFee && project.budget_amount !== null
              ? `of a ${money(project.budget_amount, project.currency)} fee`
              : 'Invoices not cancelled'}
          />
        {/if}
      </div>

      {#if hoursMeter || amountMeter}
        <div class="meters">
          {#if hoursMeter}
            <div>
              <div class="meter-head">
                <span class="v2-label">Hours budget</span>
                <span class="v2-num" style="color:var(--v2-{hoursMeter.tone})"
                  >{hoursMeter.percent}%</span
                >
              </div>
              <div class="v2-bar" role="img" aria-label="{hoursMeter.percent}% of the hours budget">
                <i style="width:{hoursMeter.width}%;background:var(--v2-{hoursMeter.tone})"></i>
              </div>
              <div class="v2-bar-legend">
                <span>{hoursText(burn.logged_hours)} logged</span>
                <span>{hoursText(project.budget_hours)} budget</span>
              </div>
            </div>
          {/if}
          {#if amountMeter}
            <div>
              <div class="meter-head">
                <span class="v2-label">{isFixedFee ? 'Fee' : 'Budget amount'}</span>
                <span class="v2-num" style="color:var(--v2-{amountMeter.tone})"
                  >{amountMeter.percent}%</span
                >
              </div>
              <div class="v2-bar" role="img" aria-label="{amountMeter.percent}% of the budget">
                <i style="width:{amountMeter.width}%;background:var(--v2-{amountMeter.tone})"></i>
              </div>
              <div class="v2-bar-legend">
                <span>{money(burn.billable_value, project.currency)} billable</span>
                <span>{money(project.budget_amount, project.currency)} budget</span>
              </div>
            </div>
          {/if}
        </div>
      {/if}

      {#if data.offers.invoiceAmount}
        <details class="v2-card panel" open={Boolean(form?.amountError)}>
          <summary class="v2-btn">Invoice an amount</summary>
          <form method="POST" action="?/invoiceAmount" class="amount-form" use:enhance>
            <input type="hidden" name="budget_amount" value={project.budget_amount ?? ''} />
            <div class="amount-modes" role="radiogroup" aria-label="Invoice">
              <label class="amount-mode">
                <input type="radio" name="mode" value="amount" bind:group={amountMode} />
                An amount
              </label>
              {#if project.budget_amount !== null}
                <label class="amount-mode">
                  <input type="radio" name="mode" value="percent" bind:group={amountMode} />
                  A percentage of the fee
                </label>
              {/if}
            </div>
            <label class="v2-field">
              <span class="v2-label">
                {amountMode === 'percent' ? 'Percentage' : `Amount in ${project.currency}`}
              </span>
              <input
                class="v2-input"
                name="value"
                type="number"
                inputmode="decimal"
                min="0.01"
                max={amountMode === 'percent' ? '100' : undefined}
                step="0.01"
                required
              />
            </label>
            <label class="v2-field">
              <span class="v2-label">Line description</span>
              <input
                class="v2-input"
                name="description"
                maxlength="255"
                placeholder="{project.name}, fixed fee"
              />
            </label>
            <button class="v2-btn v2-btn-primary" type="submit">Create draft invoice</button>
            {#if form?.amountError}
              <p class="v2-error" role="alert">{form.amountError}</p>
            {/if}
            <p class="v2-hint">
              One line, in {project.currency}, for {project.account.name}. It opens as a draft for
              you to check and send.
            </p>
          </form>
        </details>
      {/if}

      <div class="overview">
        <div>
          <div class="v2-label section-head">Project</div>
          <dl class="v2-kv">
            <dt>Account</dt>
            <dd>
              {#if project.account.id}
                <a href={resolve(`accounts/${project.account.id}`)}>{project.account.name}</a>
              {:else}
                {project.account.name}
              {/if}
            </dd>
            {#if project.deal}
              <dt>Deal</dt>
              <dd><a href={resolve(`pipeline/${project.deal.id}`)}>{project.deal.name}</a></dd>
            {/if}
            <dt>Billing</dt>
            <dd>{BILLING_TYPE_LABEL[project.billing_type] ?? ''}</dd>
            <dt>Hourly rate</dt>
            <dd class="v2-num">
              {project.hourly_rate !== null
                ? `${money(project.hourly_rate, project.currency)}/hr`
                : 'Not set'}
            </dd>
            <dt>Budget hours</dt>
            <dd>{project.budget_hours !== null ? hoursText(project.budget_hours) : 'Not set'}</dd>
            <dt>{isFixedFee ? 'Fee' : 'Budget'}</dt>
            <dd class="v2-num">
              {project.budget_amount !== null
                ? money(project.budget_amount, project.currency)
                : 'Not set'}
            </dd>
            <dt>Start</dt>
            <dd>{project.start_date ? longDate(project.start_date) : 'Not set'}</dd>
            <dt>Due</dt>
            <dd>{project.due_date ? longDate(project.due_date) : 'Not set'}</dd>
            {#if project.tags.length}
              <dt>Tags</dt>
              <dd class="tags">
                {#each project.tags as tag (tag)}<Pill>{tag}</Pill>{/each}
              </dd>
            {/if}
          </dl>
          {#if project.description}
            <div class="v2-label section-head">Description</div>
            <p class="description">{project.description}</p>
          {/if}
          {#if data.customFields?.length}
            <CustomFieldsCard fields={data.customFields} />
          {/if}
        </div>

        <div>
          <div class="v2-label section-head">People</div>
          {#each project.assigned_to as p (p.id)}
            {@const rate = project.rates.find((r) => r.profile.id === p.id)}
            <div class="person">
              <Avatar name={p.name} size={24} />
              <span class="person-name">{p.name}</span>
              {#if rate && rate.hourly_rate !== null}
                <span class="v2-num v2-sub">{money(rate.hourly_rate, project.currency)}/hr</span>
              {/if}
            </div>
          {:else}
            <p class="v2-sub small">Nobody is on this project yet.</p>
          {/each}
          {#each offTeamRates as r (r.profile.id)}
            <div class="person">
              <Avatar name={r.profile.name} size={24} />
              <span class="person-name">{r.profile.name}</span>
              <span class="v2-num v2-sub">{money(r.hourly_rate, project.currency)}/hr</span>
            </div>
          {/each}
          <p class="v2-hint">
            Time logged here takes the person's rate on this project, else the project's hourly
            rate.
          </p>
        </div>
      </div>
    {:else if shown === 'tasks'}
      <div class="tab-head">
        <span class="v2-sub">
          {data.tasks === null
            ? ''
            : `${data.tasks.length} ${data.tasks.length === 1 ? 'task' : 'tasks'}`}
        </span>
        <div class="seg" role="group" aria-label="View">
          <button
            type="button"
            aria-pressed={tasksView === 'list'}
            onclick={() => (tasksView = 'list')}>List</button
          >
          <button
            type="button"
            aria-pressed={tasksView === 'board'}
            onclick={() => (tasksView = 'board')}>By status</button
          >
        </div>
        <a
          class="v2-btn v2-btn-primary"
          href={resolve(asInternalPath(`/tasks/new?project=${project.id}`))}
          ><Plus size={13} />New task</a
        >
      </div>
      {#if data.tasks === null}
        <p class="v2-sub small">The tasks could not be loaded. Nothing else here is affected.</p>
      {:else if data.tasks.length === 0}
        <p class="v2-sub small">No tasks yet. Add the first piece of work for this project.</p>
      {:else if tasksView === 'list'}
        <div class="v2-card" style="overflow:hidden">
          <div class="v2-table-wrap">
            <table class="v2-table">
              <thead>
                <tr>
                  <th>Task</th>
                  <th>Status</th>
                  <th>Due</th>
                  <th>People</th>
                  {#if data.on.timesheet && !myTimer}<th class="v2-r">Timer</th>{/if}
                </tr>
              </thead>
              <tbody>
                {#each data.tasks as t (t.id)}
                  <tr>
                    <td data-m="title">
                      <a class="v2-row-link" href={resolve(`tasks/${t.id}`)}>
                        <span class="v2-table-primary">{t.title}</span>
                      </a>
                    </td>
                    <td data-m="tag"><Pill tone={TASK_STATUS_TONE[t.status]}>{t.status}</Pill></td>
                    <td data-m="meta">{t.due_date ? `Due ${shortDate(t.due_date)}` : ''}</td>
                    <td data-m="meta" class="v2-sub">{t.assigned_names.join(', ')}</td>
                    {#if data.on.timesheet && !myTimer}
                      <td class="v2-r" data-m="meta">
                        <form method="POST" action="?/startTimer" use:enhance={timeSubmit}>
                          <input type="hidden" name="task" value={t.id} />
                          <input type="hidden" name="billable" value={String(billable)} />
                          <button class="v2-btn v2-btn-sm" disabled={timeBusy}>
                            <Play size={11} />Start
                          </button>
                        </form>
                      </td>
                    {/if}
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>
      {:else}
        <div class="lanes">
          {#each TASK_STATUS as status (status)}
            {@const lane = data.tasks.filter((t) => t.status === status)}
            <section class="lane">
              <div class="v2-lane-head">
                <span class="v2-label">{status}</span>
                <span class="v2-num">{lane.length}</span>
              </div>
              {#each lane as t (t.id)}
                <a class="v2-deal-card" href={resolve(`tasks/${t.id}`)}>
                  <div style="font-weight:600">{t.title}</div>
                  {#if t.due_date}
                    <div class="v2-sub" style="font-size:11.5px">Due {shortDate(t.due_date)}</div>
                  {/if}
                </a>
              {:else}
                <p class="v2-sub small">Nothing here.</p>
              {/each}
            </section>
          {/each}
        </div>
      {/if}
    {:else if shown === 'time'}
      <section class="v2-card panel">
        <div class="time-head">
          <div class="time-title">
            <div class="v2-label">Time</div>
            <div class="v2-sub small">
              <b class="v2-num">{hoursText(burn.logged_hours)}</b> logged by everyone ·
              {hoursText(burn.billable_hours)} billable ·
              <a href={resolve(asInternalPath(`/timesheet/report?project=${project.id}`))}
                >Who logged it</a
              >
            </div>
          </div>
          {#if myTimer}
            <form method="POST" action="?/stopTimer" use:enhance={timeSubmit}>
              <input type="hidden" name="entry_id" value={myTimer.id} />
              <button class="v2-btn v2-btn-primary" disabled={timeBusy}>
                <Square size={12} />Stop {hm(runningMinutes(myTimer))}
              </button>
            </form>
          {:else if data.canEdit}
            <form method="POST" action="?/startTimer" use:enhance={timeSubmit}>
              <input type="hidden" name="billable" value={String(billable)} />
              <button class="v2-btn" disabled={timeBusy}><Play size={12} />Start timer</button>
            </form>
          {/if}
          {#if data.canEdit}
            <details class="time-log">
              <summary class="v2-btn"><Plus size={12} />Log time</summary>
              <form method="POST" action="?/logTime" use:enhance={timeSubmit} class="time-form">
                <label class="v2-field">
                  <span class="v2-label">Minutes</span>
                  <input
                    class="v2-input"
                    name="minutes"
                    type="number"
                    inputmode="numeric"
                    min="1"
                    max="1440"
                    step="1"
                    value="30"
                    required
                  />
                </label>
                {#if isAdmin}
                  <label class="v2-field">
                    <span class="v2-label">Rate per hour</span>
                    <input
                      class="v2-input"
                      name="hourly_rate"
                      type="number"
                      inputmode="decimal"
                      min="0"
                      step="0.01"
                      placeholder="From the project"
                    />
                  </label>
                {/if}
                {#if data.tasks?.length}
                  <label class="v2-field wide">
                    <span class="v2-label">Task</span>
                    <select class="v2-input" name="task">
                      <option value="">No task</option>
                      {#each data.tasks as t (t.id)}
                        <option value={t.id}>{t.title}</option>
                      {/each}
                    </select>
                  </label>
                {/if}
                <label class="v2-field wide">
                  <span class="v2-label">What was done</span>
                  <input
                    class="v2-input"
                    name="description"
                    placeholder="Drafted the homepage copy"
                    required
                  />
                </label>
                <div class="wide time-foot">
                  {#if billable}
                    <label class="check">
                      <input type="checkbox" name="billable" checked />
                      Billable
                    </label>
                  {/if}
                  <button class="v2-btn v2-btn-primary" disabled={timeBusy}>Log time</button>
                </div>
                <p class="v2-hint wide">
                  {isAdmin
                    ? "Counted back from now. With no rate typed, the entry takes the person's rate on this project, else the project's hourly rate."
                    : "Counted back from now. The entry takes your rate on this project, else the project's hourly rate."}
                </p>
              </form>
            </details>
          {/if}
        </div>

        {#if form?.timeError}
          <p class="v2-error" role="alert">
            <span>{form.timeError}</span>
            {#if form.runningProjectId}
              <a href={resolve(`projects/${form.runningProjectId}`)}>Open that project</a>
            {:else if form.runningTicketId}
              <a href={resolve(`tickets/${form.runningTicketId}`)}>Open that ticket</a>
            {/if}
          </p>
        {/if}

        {#if entries === null}
          <p class="v2-sub small">
            The time entries could not be loaded. Nothing else on this project is affected.
          </p>
        {:else if entries.length === 0}
          <p class="v2-sub small">
            No time logged yet. Start the timer, or log a session you have already worked.
          </p>
        {:else}
          <div class="v2-table-wrap" style="margin-top:10px">
            <table class="v2-table">
              <thead>
                <tr>
                  <th>What was done</th>
                  <th>Who</th>
                  <th>When</th>
                  <th class="v2-r">Logged</th>
                  <th class="v2-r">Billing</th>
                </tr>
              </thead>
              <tbody>
                {#each entries as e (e.id)}
                  <tr>
                    <td data-m="title">
                      {e.description || 'No description'}
                      {#if !e.ended_at}<span class="running">Running</span>{/if}
                      {#if e.task && taskTitles.get(e.task)}
                        <span class="v2-sub entry-task">{taskTitles.get(e.task)}</span>
                      {/if}
                    </td>
                    <td data-m="meta">
                      {e.profile?.user_details?.name || e.profile?.user_details?.email || 'Someone'}
                    </td>
                    <td data-m="meta">{shortAge(e.started_at)} ago</td>
                    <td class="v2-num v2-r" data-m="tag">
                      {e.ended_at ? hm(e.duration_minutes) : hm(runningMinutes(e))}
                    </td>
                    <td class="v2-r row-actions">
                      {#if !e.ended_at}
                        <form method="POST" action="?/stopTimer" use:enhance={timeSubmit}>
                          <input type="hidden" name="entry_id" value={e.id} />
                          <button class="v2-btn v2-btn-sm" disabled={timeBusy}>
                            <Square size={11} />Stop
                          </button>
                        </form>
                      {:else if isBilled(e)}
                        {#if e.invoice}
                          <a class="v2-sub" href={resolve(`invoices/${e.invoice}`)}>Invoiced</a>
                        {:else}
                          <span class="v2-sub">Invoiced</span>
                        {/if}
                      {:else if confirmDelete === e.id}
                        <form method="POST" action="?/deleteTime" use:enhance={timeSubmit}>
                          <input type="hidden" name="entry_id" value={e.id} />
                          <button class="v2-btn v2-btn-sm danger" disabled={timeBusy}>Delete</button
                          >
                        </form>
                        <button
                          type="button"
                          class="v2-btn v2-btn-sm"
                          onclick={() => (confirmDelete = '')}>Keep</button
                        >
                      {:else}
                        {#if !billable}
                          <!-- A non-billable project's time stays non-billable. -->
                          <span class="v2-sub">Not billable</span>
                        {:else}
                          <form method="POST" action="?/setBillable" use:enhance={timeSubmit}>
                            <input type="hidden" name="entry_id" value={e.id} />
                            <input
                              type="hidden"
                              name="billable"
                              value={e.billable ? 'false' : 'true'}
                            />
                            <button
                              class="v2-btn v2-btn-sm"
                              class:billable={e.billable}
                              disabled={timeBusy}
                              title={e.billable ? 'Mark as non-billable' : 'Mark as billable'}
                            >
                              {#if e.billable}
                                {e.hourly_rate
                                  ? money(e.hourly_rate, e.currency) + '/hr'
                                  : 'Billable'}
                              {:else}
                                Not billable
                              {/if}
                            </button>
                          </form>
                        {/if}
                        <button
                          type="button"
                          class="v2-btn v2-btn-sm"
                          aria-label="Delete this entry"
                          title="Delete this entry"
                          onclick={() => (confirmDelete = e.id)}
                        >
                          <Trash2 size={11} />
                        </button>
                      {/if}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        {/if}
      </section>
    {:else if shown === 'invoices'}
      {#if project.invoices.length === 0}
        <p class="v2-sub small">
          No invoices for this project yet.
          {#if data.offers.billTime}Bill its time from the button at the top.{/if}
        </p>
      {:else}
        <div class="v2-card" style="overflow:hidden">
          <div class="v2-table-wrap">
            <table class="v2-table">
              <thead>
                <tr>
                  <th>Invoice</th>
                  <th>Status</th>
                  <th>Issued</th>
                  <th class="v2-r">Total</th>
                </tr>
              </thead>
              <tbody>
                {#each project.invoices as inv (inv.id)}
                  <tr>
                    <td data-m="title">
                      <a class="v2-row-link" href={resolve(`invoices/${inv.id}`)}>
                        <span class="v2-table-primary">{inv.invoice_number || 'Draft'}</span>
                      </a>
                    </td>
                    <td data-m="tag">
                      <Pill tone={INVOICE_STATUS_TONE[inv.status] ?? 'slate'}>
                        {invoiceStatusLabel(inv.status)}
                      </Pill>
                    </td>
                    <td data-m="meta">{inv.issue_date ? shortDate(inv.issue_date) : ''}</td>
                    <td class="v2-r v2-num" data-m="meta"
                      >{money(inv.total_amount, inv.currency)}</td
                    >
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>
        {#if burn.invoiced_amount !== null}
          <p class="v2-sub small" style="margin-top:10px">
            {money(burn.invoiced_amount, project.currency)} invoiced{isFixedFee &&
            project.budget_amount !== null
              ? ` of a ${money(project.budget_amount, project.currency)} fee`
              : ''}, not counting cancelled invoices.
          </p>
        {/if}
      {/if}
    {:else if shown === 'files'}
      <CommentComposer
        error={form?.noteError}
        placeholder="A note to go with the file (optional)"
      />
      <FileList files={data.files} empty="No files on this project yet." />
    {:else if shown === 'comments'}
      <CommentComposer error={form?.noteError} />
      {#if data.comments.length}
        <Timeline events={data.comments} />
      {:else}
        <p class="v2-sub small">No comments yet.</p>
      {/if}
    {/if}
  </div>
</div>

<style>
  .p-error {
    margin: 0;
    padding: 9px 12px;
    font-size: 12.5px;
    color: var(--v2-clay);
    background: color-mix(in srgb, var(--v2-clay) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--v2-clay) 25%, transparent);
    border-radius: 7px;
  }
  .small {
    font-size: 12.5px;
    margin: 0;
  }
  .panel {
    margin-bottom: 18px;
    padding: 13px 15px;
  }
  .panel-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .panel-text {
    font-size: 13px;
    margin: 10px 0;
  }
  .bill-date,
  .bill-go {
    display: flex;
    align-items: flex-end;
    gap: 10px;
    flex-wrap: wrap;
    margin-top: 10px;
  }
  .bill-date .v2-field,
  .bill-go .v2-field {
    margin-bottom: 0;
    flex: 1 1 180px;
  }
  details.panel > summary {
    list-style: none;
    cursor: pointer;
  }
  details.panel > summary::-webkit-details-marker {
    display: none;
  }
  .amount-form {
    margin-top: 12px;
    padding-top: 12px;
    border-top: 1px solid var(--v2-line);
  }
  .amount-modes {
    display: flex;
    gap: 16px;
    flex-wrap: wrap;
    margin-bottom: 12px;
  }
  .amount-mode,
  .check {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12.5px;
    cursor: pointer;
  }
  .meters {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
    gap: 16px;
    margin-bottom: 20px;
  }
  .meter-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 6px;
  }
  .overview {
    display: grid;
    grid-template-columns: minmax(0, 3fr) minmax(0, 2fr);
    gap: 24px;
  }
  .section-head {
    margin: 4px 0 10px;
  }
  .description {
    font-size: 13px;
    line-height: 1.6;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    margin: 0 0 16px;
  }
  .tags {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }
  .person {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 36px;
  }
  .person-name {
    font-size: 13px;
    font-weight: 550;
    min-width: 0;
    overflow-wrap: anywhere;
    margin-right: auto;
  }
  .tab-head {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
    margin-bottom: 12px;
  }
  .tab-head > .v2-sub {
    margin-right: auto;
    font-size: 12.5px;
  }
  .seg {
    display: flex;
    border: 1px solid var(--v2-line);
    border-radius: 7px;
    overflow: hidden;
  }
  .seg button {
    padding: 5px 11px;
    font: inherit;
    font-size: 12px;
    color: var(--v2-slate);
    background: var(--v2-card);
    border: 0;
    cursor: pointer;
  }
  .seg button + button {
    border-left: 1px solid var(--v2-line);
  }
  .seg button[aria-pressed='true'] {
    color: var(--v2-ink);
    font-weight: 600;
    background: var(--v2-hover);
  }
  .lanes {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
  }
  .time-head {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    flex-wrap: wrap;
  }
  .time-title {
    margin-right: auto;
  }
  .time-log > summary {
    list-style: none;
    cursor: pointer;
  }
  .time-log > summary::-webkit-details-marker {
    display: none;
  }
  .time-log[open] {
    flex: 1 0 100%;
  }
  .time-form {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    margin-top: 12px;
    padding-top: 13px;
    border-top: 1px solid var(--v2-line);
  }
  .time-form .v2-field {
    margin-bottom: 0;
  }
  .wide {
    grid-column: 1 / -1;
  }
  .time-foot {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .running {
    margin-left: 6px;
    font-size: 11px;
    font-weight: 600;
    color: var(--v2-ember);
  }
  .entry-task {
    display: block;
    font-size: 11.5px;
  }
  .row-actions {
    white-space: nowrap;
  }
  .row-actions form {
    display: inline;
  }
  .billable {
    color: var(--v2-moss);
  }
  .unrated {
    color: var(--v2-clay);
  }
  .danger {
    color: var(--v2-rust);
  }
  @media (max-width: 768px) {
    .overview,
    .lanes,
    .time-form {
      grid-template-columns: 1fr;
    }
    .panel .v2-btn,
    .tab-head .v2-btn,
    .seg button,
    .row-actions .v2-btn,
    .panel .v2-input {
      min-height: 44px;
    }
    .row-actions {
      white-space: normal;
      display: flex;
      gap: 6px;
      flex-wrap: wrap;
      margin-top: 6px;
    }
  }
</style>

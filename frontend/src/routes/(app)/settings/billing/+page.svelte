<script>
  /**
   * Settings › Billing, drawn entirely from the server's answer: a member sees
   * the plan's name; an admin also sees its state and the plans, each with the
   * button the server gives it. Choose and Manage leave for a page the server
   * names, and nothing from that page runs here. Switch and Keep stay here; a
   * switch shows the server's sentence and waits for a second click.
   */
  import { enhance } from '$app/forms';
  import { Check } from '@lucide/svelte';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import Pill from '#lib/v2/components/Pill.svelte';
  import SettingsCrumb from '#lib/v2/components/SettingsCrumb.svelte';
  import { planButton } from '#lib/v2/billing.js';

  /** @type {import('./$types').PageProps} */
  let { data, form } = $props();

  /** @type {import('#lib/server/v2/billing.js').Billing} */
  let answer = $derived(data.answer);
  let plans = $derived(answer.plans ?? []);
  let busy = $state(false);
  /** The plan whose switch is waiting for its confirmation. */
  let armed = $state(/** @type {string | null} */ (null));

  // A refusal shows under the button that was pressed, else in the top card.
  let refusedPlan = $derived(
    form?.error && plans.some((p) => p.key === form.plan && planButton(p)) ? form.plan : null
  );

  /** @type {import('$app/forms').SubmitFunction} */
  const submitting = () => {
    busy = true;
    return async ({ update }) => {
      // A redirect never settles: the browser is on its way out.
      await update();
      busy = false;
      armed = null;
    };
  };
</script>

<!-- A page the back button restores from the payment page would keep its buttons disabled. -->
<svelte:window
  onpageshow={(e) => {
    if (e.persisted) busy = false;
  }}
/>

<PageHeader title="Billing">
  {#snippet crumb()}<SettingsCrumb />{/snippet}
  {#snippet sub()}The plan this organization is on.{/snippet}
</PageHeader>

<div class="v2-scroll">
  <div class="v2-pad bl-page">
    {#if answer.notice}
      <div class="bl-notice" role="alert">{answer.notice.sentence}</div>
    {/if}

    <section class="v2-card bl-current" aria-labelledby="bl-current">
      <div class="v2-label" id="bl-current">Current plan</div>
      <div class="bl-name">{answer.plan.name}</div>
      {#if answer.state}
        <p class="bl-state">{answer.state.sentence}</p>
      {:else if answer.plans === null}
        <p class="v2-sub bl-state">
          Only an organization admin can see the billing details or change the plan.
        </p>
      {/if}
      {#if answer.canManage}
        <form method="POST" action="?/manage" use:enhance={submitting} class="bl-manage">
          <button type="submit" class="v2-btn v2-btn-primary bl-tap" disabled={busy}>
            Manage billing
          </button>
          <span class="v2-hint">Change the card, see invoices or cancel.</span>
        </form>
      {/if}
      {#if form?.message}
        <p class="bl-done" role="status">{form.message}</p>
      {/if}
      {#if form?.error && !refusedPlan}
        <p class="v2-error" role="alert">{form.error}</p>
      {/if}
    </section>

    {#if plans.length}
      <h2 class="bl-h">Plans</h2>
      <div class="bl-plans">
        {#each plans as plan (plan.key)}
          {@const button = planButton(plan)}
          <section class="v2-card bl-plan" aria-labelledby={`bl-plan-${plan.key}`}>
            <div class="bl-plan-head">
              <h3 id={`bl-plan-${plan.key}`}>{plan.name}</h3>
              {#if plan.current}<Pill tone="moss">Current</Pill>{/if}
            </div>
            {#if plan.priceText}<div class="bl-price">{plan.priceText}</div>{/if}
            {#if plan.features.length}
              <ul class="bl-features">
                {#each plan.features as feature, i (i)}
                  <li><Check size={14} aria-hidden="true" />{feature}</li>
                {/each}
              </ul>
            {/if}
            {#if button}
              <div class="bl-plan-action" aria-live="polite">
                {#if button.action === 'switch' && armed === plan.key}
                  <form method="POST" action="?/switch" use:enhance={submitting}>
                    <input type="hidden" name="plan" value={plan.key} />
                    {#if button.confirm}<p class="bl-confirm">{button.confirm}</p>{/if}
                    <div class="bl-confirm-row">
                      <button type="submit" class="v2-btn v2-btn-primary bl-tap" disabled={busy}>
                        Confirm
                      </button>
                      <button
                        type="button"
                        class="v2-btn bl-tap"
                        disabled={busy}
                        onclick={() => (armed = null)}
                      >
                        Cancel
                      </button>
                    </div>
                  </form>
                {:else if button.action === 'switch'}
                  <button
                    type="button"
                    class="v2-btn bl-tap"
                    disabled={busy}
                    onclick={() => (armed = plan.key)}
                  >
                    {button.label}
                  </button>
                {:else}
                  <form
                    method="POST"
                    action={button.action === 'choose' ? '?/choose' : '?/keep'}
                    use:enhance={submitting}
                  >
                    <input type="hidden" name="plan" value={plan.key} />
                    <button type="submit" class="v2-btn bl-tap" disabled={busy}>
                      {button.label}
                    </button>
                  </form>
                {/if}
              </div>
            {/if}
            {#if refusedPlan === plan.key}
              <p class="v2-error" role="alert">{form?.error}</p>
            {/if}
          </section>
        {/each}
      </div>
      <p class="v2-sub bl-foot">
        Choosing a plan or managing billing takes you to the payment provider's page, which brings
        you back here when you are done. Switching between plans happens on this page.
      </p>
    {/if}
  </div>
</div>

<style>
  .bl-page {
    padding-top: 18px;
    padding-bottom: 32px;
    max-width: 960px;
  }
  .bl-notice {
    border: 1px solid color-mix(in srgb, var(--v2-rust) 28%, transparent);
    background: color-mix(in srgb, var(--v2-rust) 9%, transparent);
    border-radius: var(--v2-radius);
    padding: 12px 15px;
    margin-bottom: 16px;
    font-size: 13px;
    font-weight: 600;
  }
  .bl-current {
    padding: 16px;
    margin-bottom: 24px;
  }
  .bl-name {
    font-size: 20px;
    font-weight: 650;
    letter-spacing: -0.02em;
    margin-top: 4px;
    overflow-wrap: anywhere;
  }
  .bl-state {
    font-size: 13px;
    margin: 6px 0 0;
  }
  .bl-manage {
    margin-top: 14px;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px 12px;
  }
  .bl-manage .v2-hint {
    margin-top: 0;
  }
  .bl-h {
    font-size: 14px;
    font-weight: 650;
    margin: 0 0 12px;
  }
  .bl-plans {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 14px;
  }
  .bl-plan {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-width: 0;
  }
  .bl-plan-head {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .bl-plan-head h3 {
    margin: 0;
    font-size: 15px;
    font-weight: 650;
    overflow-wrap: anywhere;
  }
  .bl-price {
    font-size: 13px;
    font-weight: 600;
  }
  .bl-features {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 5px;
    font-size: 12.5px;
    line-height: 1.45;
  }
  .bl-features li {
    display: flex;
    gap: 7px;
    align-items: flex-start;
    overflow-wrap: anywhere;
  }
  .bl-features :global(svg) {
    flex: none;
    margin-top: 2px;
    color: var(--v2-moss);
  }
  .bl-plan-action {
    margin-top: auto;
    padding-top: 6px;
  }
  .bl-confirm {
    font-size: 12.5px;
    line-height: 1.45;
    margin: 0 0 10px;
  }
  .bl-confirm-row {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .bl-done {
    font-size: 13px;
    font-weight: 600;
    margin: 10px 0 0;
  }
  .bl-foot {
    font-size: 11.5px;
    margin-top: 14px;
    max-width: 64ch;
  }
  @media (max-width: 768px) {
    .bl-tap {
      min-height: 44px;
      justify-content: center;
    }
    .bl-plan-action .bl-tap {
      width: 100%;
    }
  }
</style>

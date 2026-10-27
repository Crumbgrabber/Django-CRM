<script lang="ts">
  import { resolve } from '$app/paths';
  /**
   * Who can get in, and how much they can do.
   *
   * ROLE IS DISPLAYED HERE, DECIDED ON THE SERVER.
   * `role` comes from the Profile the API returned. This page renders it and
   * offers to change it; the server decides whether the change is allowed. Two
   * rules the endpoint enforces and this page mirrors as hints only, nobody
   * changes their own role, and the org keeps at least one admin. Mirroring
   * them is a courtesy so a button does not 400; it is not the control. The
   * real enforcement is in common/views/user_views.py, because anyone can skip
   * this page entirely with curl, which is exactly how a member used to PATCH
   * themselves to admin before that path was closed.
   *
   * The row that matters most is the quiet one: a deactivated account with a
   * not-yet-revoked API token. Deactivating a login already stops that token at
   * the door; resolve_valid_pat rejects a token whose profile.is_active is
   * false, but it is dormant, not revoked, and would authenticate again the
   * moment the account is reactivated. That is why the count is here: an
   * offboarding to-do, not a live breach.
   */
  import { isOrgAdmin } from '#lib/admin.js';
  import ConfirmAction from '#lib/v2/components/ConfirmAction.svelte';
  import PageHeader from '#lib/v2/components/PageHeader.svelte';
  import StatCard from '#lib/v2/components/StatCard.svelte';
  import Pill from '#lib/v2/components/Pill.svelte';
  import Avatar from '#lib/v2/components/Avatar.svelte';
  import NextAction from '#lib/v2/components/NextAction.svelte';
  import { count, relativeDays } from '#lib/v2/format.js';
  import { ROLE_LABEL, ROLE_TONE } from '#lib/v2/enums.js';
  import { enhance, type SubmitFunction } from '$app/forms';
  import { UserPlus, KeyRound } from '@lucide/svelte';
  import type { PageProps } from './$types';

  let { data, form }: PageProps = $props();

  let inviting = $state(false);
  let editingId = $state<string | null>(null);
  let busy = $state(false);

  /** A submit handler that flips `busy` while the action runs. */
  const working: SubmitFunction = () => {
    busy = true;
    return async ({ update }) => {
      await update();
      busy = false;
    };
  };

  /** Keep unsaved ticks on a failed save; the reload re-syncs them on success. */
  const membersSubmit: SubmitFunction = () => {
    busy = true;
    return async ({ update }) => {
      await update({ reset: false });
      busy = false;
    };
  };

  /** The invite form both submits and, on success, closes itself. */
  const inviteSubmit: SubmitFunction = () => {
    busy = true;
    return async ({ update, result }) => {
      await update();
      busy = false;
      if (result?.type === 'success' && result?.data?.invited) inviting = false;
    };
  };

  /** The edit form closes itself once the save succeeds. */
  const editSubmit: SubmitFunction = () => {
    busy = true;
    return async ({ update, result }) => {
      await update({ reset: false });
      busy = false;
      if (result?.type === 'success' && result?.data?.edited) editingId = null;
    };
  };
</script>

{#if data.forbidden}
  <PageHeader title="Team and access" />
  <div class="v2-pad" style="padding-top:40px">
    <NextAction
      label="Admins only"
      text="Managing people, roles and access is limited to organization admins. Ask an admin on your team if you need someone added or a role changed."
    />
  </div>
{:else}
  <PageHeader title="Team and access">
    {#snippet sub()}
      <span class="v2-num">{count(data.totals.count)}</span> people ·
      <span class="v2-num">{count(data.totals.admins)}</span> admins
    {/snippet}
    {#snippet actions()}
      <button class="v2-btn v2-btn-primary" onclick={() => (inviting = !inviting)}>
        <UserPlus />Add user
      </button>
    {/snippet}
  </PageHeader>

  <div class="v2-pad" style="padding-top:16px;flex:none">
    <div class="v2-stats">
      <StatCard label="Active people" value={count(data.totals.count)} tone="ink" />
      <StatCard
        label="Admins"
        value={count(data.totals.admins)}
        tone="clay"
        detail="Can change roles and org settings"
      />
      <StatCard
        label="Never signed in"
        value={count(data.totals.never_signed_in)}
        tone={data.totals.never_signed_in ? 'clay' : 'slate'}
        detail={data.totals.never_signed_in ? 'Invited, seat unclaimed' : 'Everyone has signed in'}
      />
      <StatCard label="Deactivated" value={count(data.totals.deactivated)} tone="slate" />
    </div>
  </div>

  <div class="v2-scroll">
    <div class="v2-pad" style="padding-bottom:32px">
      {#if inviting}
        <form
          method="POST"
          action="?/invite"
          use:enhance={inviteSubmit}
          class="v2-card"
          style="padding:14px 15px;margin-bottom:18px;display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap"
        >
          <div style="flex:1;min-width:180px">
            <label class="v2-label" for="invite-name" style="display:block;margin-bottom:4px">
              Name
            </label>
            <input id="invite-name" name="name" class="v2-input" style="width:100%" />
          </div>
          <div style="flex:1;min-width:220px">
            <label class="v2-label" for="invite-email" style="display:block;margin-bottom:4px">
              Email
            </label>
            <input
              id="invite-email"
              name="email"
              type="email"
              required
              class="v2-input"
              style="width:100%"
              placeholder="name@company.com"
            />
          </div>
          <div style="flex:1;min-width:180px">
            <label class="v2-label" for="invite-password" style="display:block;margin-bottom:4px">
              Password
            </label>
            <input
              id="invite-password"
              name="password"
              type="password"
              autocomplete="new-password"
              class="v2-input"
              style="width:100%"
            />
          </div>
          <div>
            <label class="v2-label" for="invite-role" style="display:block;margin-bottom:4px">
              Role
            </label>
            <select id="invite-role" name="role" class="v2-input" style="width:130px">
              <option value="USER">Member</option>
              <option value="ADMIN">Admin</option>
            </select>
          </div>
          <button class="v2-btn v2-btn-primary" disabled={busy}>Add user</button>
          <button type="button" class="v2-btn" disabled={busy} onclick={() => (inviting = false)}>
            Cancel
          </button>
          {#if form?.invite?.error}
            <p
              class="v2-sub"
              style="color:var(--v2-rust);font-size:12px;flex-basis:100%;margin:2px 0 0"
            >
              {form.invite.error}
            </p>
          {/if}
        </form>
      {/if}

      {#if form?.invited}
        <p
          class="v2-sub"
          style="color:var(--v2-moss);font-size:12.5px;margin:0 0 16px;font-weight:550"
        >
          {form.invited} is a member now. They show below as “never” signed in until they sign in with
          that email.
        </p>
      {:else if form?.edited}
        <p
          class="v2-sub"
          style="color:var(--v2-moss);font-size:12.5px;margin:0 0 16px;font-weight:550"
        >
          Changes saved.
        </p>
      {:else if form?.error}
        <div style="margin-bottom:16px">
          <NextAction label="That did not work" text={form.error} tone="rust" />
        </div>
      {/if}

      {#if data.totals.tokens_on_deactivated}
        <!--
          A dormant liability, not a live one. Deactivating a profile already
          stops its tokens at login (resolve_valid_pat checks profile.is_active),
          but it does not revoke the PersonalAccessToken rows. They would
          authenticate again if the account were reactivated. Worth clearing as
          part of offboarding, hence clay rather than rust.
        -->
        <div style="margin-bottom:20px">
          <NextAction
            label="Loose end"
            text={`${data.totals.tokens_on_deactivated} API ${data.totals.tokens_on_deactivated === 1 ? 'token belongs' : 'tokens belong'} to a deactivated account. Deactivating already stops them at login, but they are not revoked. Reactivating the account would bring them back. Revoke to close that off.`}
            action="Review tokens"
            href="/settings/api-tokens"
          />
        </div>
      {/if}

      <div class="v2-label" style="margin-bottom:10px">People</div>
      <div class="v2-table-wrap" style="margin-bottom:26px">
        <table class="v2-table">
          <thead>
            <tr>
              <th>Person</th>
              <th>Role</th>
              <th>Teams</th>
              <th data-m="hide">Tokens</th>
              <th class="v2-r">Last signed in</th>
              <th class="v2-r">Manage</th>
            </tr>
          </thead>
          <tbody>
            {#each [...data.active, ...data.inactive] as m (m.id)}
              {@const isLastAdmin = m.user_id === data.last_admin_id}
              <tr style={m.is_active ? '' : 'opacity:.62'}>
                <td>
                  <span style="display:flex;gap:9px;align-items:center">
                    <Avatar name={m.name} size={27} />
                    <span style="min-width:0">
                      <span class="v2-table-primary">
                        {m.name}{#if m.is_you}<span class="v2-sub" style="font-weight:400"
                            >, you</span
                          >{/if}
                      </span>
                      <span class="v2-table-secondary" style="display:block">{m.email}</span>
                    </span>
                  </span>
                </td>
                <td data-m="tag">
                  <Pill tone={m.is_active ? ROLE_TONE[m.role] : 'slate'}>{ROLE_LABEL[m.role]}</Pill>
                  {#if !m.is_active}
                    <span class="v2-table-secondary" style="display:block">Deactivated</span>
                  {/if}
                </td>
                <td>
                  {#if m.teams.length}
                    {m.teams.join(', ')}
                  {:else}
                    <span class="v2-muted">—</span>
                  {/if}
                </td>
                <td data-m="hide">
                  {#if m.active_token_count}
                    <a
                      href={resolve('settings/api-tokens')}
                      style="display:inline-flex;gap:5px;align-items:center;color:{m.is_active
                        ? 'inherit'
                        : 'var(--v2-clay)'};font-weight:{m.is_active ? 400 : 600}"
                    >
                      <KeyRound size={13} />
                      <span class="v2-num">{m.active_token_count}</span>
                    </a>
                  {:else}
                    <span class="v2-muted">—</span>
                  {/if}
                </td>
                <td class="v2-r">
                  {#if m.last_login}
                    {relativeDays(m.last_login)}
                  {:else}
                    <span style="color:var(--v2-clay);font-weight:600">never</span>
                  {/if}
                </td>
                <td class="v2-r">
                  {#if m.is_you}
                    <button
                      type="button"
                      class="v2-btn v2-btn-sm"
                      disabled={busy}
                      onclick={() => (editingId = editingId === m.user_id ? null : m.user_id)}
                    >
                      Edit
                    </button>
                  {:else}
                    <span
                      style="display:inline-flex;gap:6px;justify-content:flex-end;flex-wrap:wrap"
                    >
                      <button
                        type="button"
                        class="v2-btn v2-btn-sm"
                        disabled={busy}
                        onclick={() => (editingId = editingId === m.user_id ? null : m.user_id)}
                      >
                        Edit
                      </button>
                      <!-- Role toggle. Two roles, so one button naming the
                           destination is clearer than a picker. The last admin
                           cannot be demoted; the server enforces it too. -->
                      <form method="POST" action="?/setRole" use:enhance={working}>
                        <input type="hidden" name="userId" value={m.user_id} />
                        <input
                          type="hidden"
                          name="role"
                          value={m.role === 'ADMIN' ? 'USER' : 'ADMIN'}
                        />
                        <button
                          class="v2-btn v2-btn-sm"
                          disabled={busy || (m.role === 'ADMIN' && isLastAdmin)}
                          title={m.role === 'ADMIN' && isLastAdmin
                            ? 'The org must keep at least one admin'
                            : ''}
                        >
                          {m.role === 'ADMIN' ? 'Make member' : 'Make admin'}
                        </button>
                      </form>
                      <!-- Activate / deactivate. The last active admin cannot
                           be deactivated; the server refuses it with a 400. -->
                      <form method="POST" action="?/setStatus" use:enhance={working}>
                        <input type="hidden" name="userId" value={m.user_id} />
                        <input
                          type="hidden"
                          name="status"
                          value={m.is_active ? 'Inactive' : 'Active'}
                        />
                        <button
                          class="v2-btn v2-btn-sm"
                          disabled={busy || (m.is_active && isLastAdmin)}
                          title={m.is_active && isLastAdmin
                            ? 'The org must keep at least one active admin'
                            : ''}
                          style={m.is_active ? 'color:var(--v2-rust)' : ''}
                        >
                          {m.is_active ? 'Deactivate' : 'Reactivate'}
                        </button>
                      </form>
                    </span>
                  {/if}
                </td>
              </tr>
              {#if editingId === m.user_id}
                <tr>
                  <td colspan="6" style="padding-right:0">
                    <form
                      method="POST"
                      action="?/edit"
                      class="person-edit"
                      use:enhance={editSubmit}
                      style="display:flex;gap:10px;align-items:flex-end;flex-wrap:wrap;padding:6px 0"
                    >
                      <input type="hidden" name="userId" value={m.user_id} />
                      <input type="hidden" name="originalEmail" value={m.email} />
                      <input
                        type="hidden"
                        name="originalName"
                        value={m.name === m.email ? '' : m.name}
                      />
                      <div style="flex:1;min-width:160px">
                        <label class="v2-label" for="edit-name-{m.user_id}">Name</label>
                        <input
                          id="edit-name-{m.user_id}"
                          name="name"
                          class="v2-input"
                          style="width:100%"
                          value={m.name === m.email ? '' : m.name}
                        />
                      </div>
                      <div style="flex:1;min-width:200px">
                        <label class="v2-label" for="edit-email-{m.user_id}">Email</label>
                        <input
                          id="edit-email-{m.user_id}"
                          name="email"
                          type="email"
                          required
                          class="v2-input"
                          style="width:100%"
                          value={m.email}
                        />
                      </div>
                      <div style="flex:1;min-width:160px">
                        <label class="v2-label" for="edit-password-{m.user_id}">
                          New password
                        </label>
                        <input
                          id="edit-password-{m.user_id}"
                          name="password"
                          type="password"
                          autocomplete="new-password"
                          class="v2-input"
                          style="width:100%"
                          placeholder="Leave blank to keep"
                        />
                      </div>
                      {#each [{ name: 'phone', label: 'Phone', value: m.phone }, { name: 'alternate_phone', label: 'Alternate phone', value: m.alternate_phone }] as field (field.name)}
                        <div style="flex:1;min-width:160px">
                          <label class="v2-label" for="edit-{field.name}-{m.user_id}"
                            >{field.label}</label
                          >
                          <input
                            id="edit-{field.name}-{m.user_id}"
                            name={field.name}
                            type="tel"
                            maxlength="20"
                            class="v2-input"
                            style="width:100%"
                            value={field.value}
                          />
                        </div>
                      {/each}
                      <button class="v2-btn v2-btn-primary" disabled={busy}>Save</button>
                      <button
                        type="button"
                        class="v2-btn"
                        disabled={busy}
                        onclick={() => (editingId = null)}
                      >
                        Cancel
                      </button>
                      {#if form?.edit?.userId === m.user_id && form.edit.error}
                        <p
                          class="v2-sub"
                          style="color:var(--v2-rust);font-size:12px;flex-basis:100%;margin:2px 0 0"
                        >
                          {form.edit.error}
                        </p>
                      {/if}
                    </form>
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      </div>

      <div class="v2-label" style="margin-bottom:10px">Teams</div>
      {#if isOrgAdmin(data)}
        <form method="POST" action="?/createTeam" use:enhance={working} class="v2-card team-create">
          <label class="v2-label" for="team-name">New team</label>
          <input
            id="team-name"
            name="name"
            required
            maxlength="100"
            class="v2-input"
            placeholder="Team name"
          />
          <label class="v2-label" for="team-description">Description (optional)</label>
          <input id="team-description" name="description" class="v2-input" />
          <button class="v2-btn v2-btn-primary" disabled={busy}>Create team</button>
        </form>
        {#if form?.message}
          <p role="status">{form.message}</p>
        {/if}
      {/if}
      <div class="v2-card" style="margin-bottom:14px">
        {#each data.teams as t (t.id)}
          <section class="team-section" aria-label={t.name}>
            <div class="team-heading">
              <div style="min-width:0;overflow-wrap:anywhere">
                <b>{t.name}</b>
                <p class="v2-sub">{t.description}</p>
                <span class="v2-sub"
                  >{t.member_count} {t.member_count === 1 ? 'member' : 'members'}</span
                >
              </div>
              {#if isOrgAdmin(data)}
                <ConfirmAction
                  action="?/deleteTeam"
                  hidden={{ teamId: t.id }}
                  explain="Delete this team? Member accounts stay active."
                />
              {/if}
            </div>
            {#if isOrgAdmin(data)}
              <input form="team-members" type="hidden" name="teamId" value={t.id} />
              <input form="team-members" type="hidden" name="name:{t.id}" value={t.name} />
              <input
                form="team-members"
                type="hidden"
                name="original:{t.id}"
                value={t.profile_ids.join(',')}
              />
              <fieldset>
                <legend class="v2-label">Members</legend>
                <div class="team-members">
                  {#each data.active as member (member.id)}
                    <label class="team-member">
                      <input
                        form="team-members"
                        type="checkbox"
                        name="member:{t.id}"
                        value={member.id}
                        checked={t.profile_ids.includes(member.id)}
                      />
                      <span>{member.name} <span class="v2-sub">({member.email})</span></span>
                    </label>
                  {:else}
                    <p class="v2-sub">No active members.</p>
                  {/each}
                </div>
              </fieldset>
            {/if}
          </section>
        {:else}
          <div class="v2-setting">
            <span class="v2-sub" style="font-size:12px">No teams yet.</span>
          </div>
        {/each}
      </div>
      {#if isOrgAdmin(data) && data.teams.length}
        <!-- Checkboxes join this form via form="team-members"; the delete forms rule out nesting. -->
        <form
          id="team-members"
          method="POST"
          action="?/setMembers"
          use:enhance={membersSubmit}
          class="team-save"
        >
          <button class="v2-btn v2-btn-primary" disabled={busy}>Save all team members</button>
        </form>
      {/if}

      <p class="v2-sub" style="font-size:11.5px">
        Roles are Admin and Member, the only two the API recognises. Admins can add people with a
        password, edit their name, email and password (only for people who belong to this
        organization alone), change roles and edit org settings; the server refuses to let anyone
        change their own role or deactivate the last admin.
      </p>
    </div>
  </div>
{/if}

<style>
  .person-edit input,
  .person-edit button {
    min-height: 44px;
  }

  .team-create {
    display: grid;
    gap: 10px;
    padding: 16px;
    margin-bottom: 16px;
  }
  .team-create input {
    width: 100%;
    min-width: 0;
  }
  .team-create button {
    min-height: 44px;
  }
  .team-save {
    position: sticky;
    bottom: 0;
    padding-block: 12px;
    margin-bottom: 14px;
    background: var(--v2-bg, inherit);
  }
  .team-save button {
    min-height: 44px;
    width: 100%;
  }
  .team-section {
    padding: 16px;
    border-bottom: 1px solid var(--v2-line);
    min-width: 0;
  }
  .team-heading {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 12px;
  }
  .team-heading :global(button) {
    min-height: 44px;
  }
  fieldset {
    border: 0;
    padding: 0;
    margin: 0 0 12px;
    min-width: 0;
  }
  .team-members {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr));
    gap: 4px 16px;
  }
  .team-member {
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 44px;
    overflow-wrap: anywhere;
  }
  .team-member input {
    flex-shrink: 0;
    width: 18px;
    height: 18px;
  }
  .team-member span {
    min-width: 0;
  }
</style>

<script lang="ts">
  import {
    Inbox,
    Mail,
    MessageCircle,
    MessageSquareText,
    PhoneIncoming,
    PhoneOutgoing,
    Users
  } from '@lucide/svelte';

  let {
    kind,
    direction = 'outbound',
    size = 13
  }: { kind: string; direction?: string; size?: number } = $props();
</script>

{#if kind === 'call'}
  {#if direction === 'inbound'}<PhoneIncoming {size} />{:else}<PhoneOutgoing {size} />{/if}
{:else if kind === 'meeting'}<Users {size} />
{:else if kind === 'email'}<Mail {size} />
{:else if kind === 'whatsapp'}<MessageCircle {size} />
{:else if kind === 'sms'}<MessageSquareText {size} />
{:else}<Inbox {size} />{/if}

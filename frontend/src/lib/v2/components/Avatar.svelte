<script lang="ts">
  import { initials } from '#lib/v2/format.js';

  let { name, size = 26 }: { name: string; size?: number } = $props();
</script>

<span
  class="v2-avatar"
  style="width:{size}px;height:{size}px;font-size:{(size * 0.38).toFixed(1)}px"
  title={name}
  aria-hidden="true">{initials(name)}</span
>

<script>
  import { cn } from '#lib/utils.js';

  /** @type {import('bits-ui').WithElementRef<import('svelte/elements').HTMLAttributes<HTMLDivElement>>} */
  let { ref = $bindable(null), class: className = undefined, children, ...restProps } = $props();
</script>

<div
  bind:this={ref}
  data-slot="dialog-header"
  class={cn('flex flex-col gap-2 text-center sm:text-start', className)}
  {...restProps}
>
  {@render children?.()}
</div>

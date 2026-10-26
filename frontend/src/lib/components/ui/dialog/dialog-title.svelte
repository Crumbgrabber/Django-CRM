<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogTitleProps } from 'bits-ui';
  import { cn } from '#lib/utils.js';

  let {
    ref = $bindable(null),
    class: className = undefined,
    ...restProps
  }: DialogTitleProps = $props();
</script>

<DialogPrimitive.Title
  bind:ref
  data-slot="dialog-title"
  class={cn('text-lg leading-none font-semibold', className)}
  {...restProps}
/>

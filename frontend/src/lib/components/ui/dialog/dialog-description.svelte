<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogDescriptionProps } from 'bits-ui';
  import { cn } from '#lib/utils.js';

  let {
    ref = $bindable(null),
    class: className = undefined,
    ...restProps
  }: DialogDescriptionProps = $props();
</script>

<DialogPrimitive.Description
  bind:ref
  data-slot="dialog-description"
  class={cn('text-muted-foreground text-sm', className)}
  {...restProps}
/>

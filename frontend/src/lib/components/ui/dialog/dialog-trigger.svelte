<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogTriggerProps } from 'bits-ui';

  let { ref = $bindable(null), ...restProps }: DialogTriggerProps = $props();
</script>

<DialogPrimitive.Trigger bind:ref data-slot="dialog-trigger" {...restProps} />

<script lang="ts">
  import { untrack } from 'svelte';
  import { refreshAll } from '$app/navigation';
  import { Upload } from '@lucide/svelte';
  import { Button } from '#lib/components/ui/button/index.js';
  import * as Dialog from '#lib/components/ui/dialog/index.js';
  import ImportFlow from '#lib/components/import/ImportFlow.svelte';
  import type { ImportConfig } from '#lib/import/entities.js';

  /**
   * The leads list's import dialog: `ImportFlow` in a dialog, refreshing the
   * list after an import. `singular` and `plural` are the org's own words for
   * a lead, so a pack that renames the module is not contradicted by this
   * dialog. `config` points the same dialog at a custom object's importer.
   */
  let {
    open = $bindable(false),
    onOpenChange,
    singular = 'lead',
    plural = 'leads',
    config
  }: {
    open: boolean;
    onOpenChange?: (v: boolean) => void;
    singular?: string;
    plural?: string;
    config?: ImportConfig;
  } = $props();

  let done = $state(false);
  /** Bumped on each opening, so every opening starts again at choosing a file. */
  let session = $state(0);

  $effect(() => {
    if (open) {
      untrack(() => {
        session += 1;
        done = false;
      });
    }
  });
</script>

<Dialog.Root bind:open onOpenChange={(v) => onOpenChange?.(v)}>
  <Dialog.Content class="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-3xl">
    <Dialog.Header>
      <Dialog.Title class="flex items-center gap-2">
        <Upload class="h-4 w-4" />
        Import {plural}
      </Dialog.Title>
      <Dialog.Description>
        Bring in a spreadsheet of {plural}. You'll check how its columns match, and nothing is
        written until you choose Import.
      </Dialog.Description>
    </Dialog.Header>

    {#key session}
      <ImportFlow
        entity={config ? undefined : 'leads'}
        {config}
        {singular}
        {plural}
        onDone={async () => {
          done = true;
          await refreshAll();
        }}
      />
    {/key}

    <Dialog.Footer>
      <Button class="max-md:h-11" type="button" variant="outline" onclick={() => (open = false)}>
        {done ? 'Close' : 'Cancel'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>

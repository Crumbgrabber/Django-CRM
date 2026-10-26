import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

const { listDeals, listBoard, getDealFormOptions, createDeal, updateDeal, getDeal, addDealNote } =
  await import('#lib/server/v2/deals.js');

const event = { cookies: { get: () => 'token' } } as any;

/**
 * Deals carry their own currency and there are no exchange rates, so the API
 * sends `amount_sum` and `weighted_sum` as `null` once there are several
 * currencies and splits them in `by_currency`. The header has to print each
 * currency on its own rather than a sum labelled in the org's currency.
 */
describe('pipeline totals', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('keeps each currency on its own', async () => {
    apiRequest.mockResolvedValue({
      opportunities: [],
      totals: {
        count: 3,
        amount_sum: null,
        weighted_sum: null,
        by_currency: [
          { currency: 'EUR', amount_sum: '300.00', weighted_sum: '150.40' },
          { currency: 'USD', amount_sum: '1000.00', weighted_sum: '500.00' }
        ],
        stalled_count: 1
      }
    });

    const { totals } = await listDeals(event);

    expect(totals.count).toBe(3);
    expect(totals.stalled_count).toBe(1);
    expect(totals.amount_by_currency).toEqual([
      { currency: 'EUR', amount: 300 },
      { currency: 'USD', amount: 1000 }
    ]);
    expect(totals.weighted_by_currency).toEqual([
      { currency: 'EUR', amount: 150 },
      { currency: 'USD', amount: 500 }
    ]);
  });

  it('holds nothing for an unpriced pipeline, so the page prints its own zero', async () => {
    apiRequest.mockResolvedValue({
      opportunities: [],
      totals: { count: 1, amount_sum: '0', weighted_sum: '0', by_currency: [], stalled_count: 0 }
    });

    const { totals } = await listDeals(event);

    expect(totals.amount_by_currency).toEqual([]);
    expect(totals.weighted_by_currency).toEqual([]);
  });
});

describe('pipelines', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('boards only open lanes, by kind rather than by code, and names them by label', async () => {
    apiRequest.mockResolvedValue({
      pipeline: { id: 'p-2', name: 'Renewals', is_default: false },
      columns: [
        { id: 'TALKING', name: 'Talking', kind: 'open', item_count: 1, items: [{ id: 'd-1' }] },
        // A won stage that is not called CLOSED_WON is still not a lane.
        { id: 'SIGNED', name: 'Signed', kind: 'won', item_count: 4, items: [] },
        { id: 'CHURNED', name: 'Churned', kind: 'lost', item_count: 0, items: [] }
      ]
    });

    const { lanes, pipelineId } = await listBoard(event, new URLSearchParams('pipeline=p-2'));

    expect(apiRequest.mock.calls[0][0]).toBe('/opportunities/kanban/?pipeline=p-2');
    expect(pipelineId).toBe('p-2');
    expect(lanes.map((l: any) => [l.stage, l.label, l.count])).toEqual([['TALKING', 'Talking', 1]]);
  });

  it("carries each card's own can_move, and locks one without it", async () => {
    apiRequest.mockResolvedValue({
      pipeline: { id: 'p-1', name: 'Sales', is_default: true },
      columns: [
        {
          id: 'TALKING',
          name: 'Talking',
          kind: 'open',
          item_count: 3,
          items: [{ id: 'd-1', can_move: true }, { id: 'd-2', can_move: false }, { id: 'd-3' }]
        }
      ]
    });

    const { lanes } = await listBoard(event);

    expect(lanes[0].rows.map((r: any) => [r.id, r.canMove])).toEqual([
      ['d-1', true],
      ['d-2', false],
      ['d-3', false]
    ]);
  });

  it("carries each deal's pipeline, stage label and kind through to the rows", async () => {
    apiRequest.mockResolvedValue({
      opportunities: [
        { id: 'd-1', pipeline: 'p-2', stage: 'SIGNED', stage_label: 'Signed', stage_kind: 'won' }
      ],
      totals: null
    });

    const { results } = await listDeals(event);

    expect(results[0]).toMatchObject({
      pipeline: 'p-2',
      stage: 'SIGNED',
      stage_label: 'Signed',
      stage_kind: 'won'
    });
  });

  it("starts a new deal in the default pipeline's first open stage", async () => {
    apiRequest.mockImplementation(async (path: string) => {
      if (path === '/opportunities/pipelines/') {
        return {
          pipelines: [
            {
              id: 'p-1',
              name: 'Sales',
              is_default: true,
              stages: [
                { id: 's-0', code: 'LOST', label: 'Lost', kind: 'lost' },
                { id: 's-1', code: 'FIRST', label: 'First', kind: 'open' }
              ]
            },
            { id: 'p-2', name: 'Other', is_default: false, stages: [] }
          ]
        };
      }
      return {};
    });

    const options = await getDealFormOptions(event);

    expect(options.defaults).toMatchObject({ pipeline: 'p-1', stage: 'FIRST' });
    expect(options.pipelines).toHaveLength(2);
  });
});

/**
 * G31: the list and the board carry each deal's next open task. `null` is the
 * flag (nothing the viewer can see is scheduled); a response that never
 * carried the key stays `undefined` so it is not mistaken for that flag.
 */
describe('next activity', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  const task = { id: 't-1', title: 'Send proposal', due_date: '2026-10-01' };

  it('reaches list rows, including the none flag', async () => {
    apiRequest.mockResolvedValue({
      opportunities: [
        { id: 'd-1', amount: '2', next_activity: task },
        { id: 'd-2', amount: '1', next_activity: null }
      ],
      totals: null
    });

    const { results } = await listDeals(event);

    expect(results[0].next_activity).toEqual(task);
    expect(results[1].next_activity).toBeNull();
  });

  it('reaches board cards', async () => {
    apiRequest.mockResolvedValue({
      pipeline: { id: 'p-1' },
      columns: [
        {
          id: 'OPEN',
          kind: 'open',
          item_count: 2,
          items: [
            { id: 'd-1', next_activity: { ...task, due_date: null } },
            { id: 'd-2', next_activity: null }
          ]
        }
      ]
    });

    const { lanes } = await listBoard(event);

    expect(lanes[0].rows[0].next_activity).toEqual({ ...task, due_date: null });
    expect(lanes[0].rows[1].next_activity).toBeNull();
  });

  it('stays undefined when the response did not compute it', async () => {
    apiRequest.mockResolvedValue({ opportunities: [{ id: 'd-1' }], totals: null });

    const { results } = await listDeals(event);

    expect(results[0].next_activity).toBeUndefined();
  });
});

describe('lead source', () => {
  beforeEach(() => {
    apiRequest.mockReset();
    apiRequest.mockResolvedValue({ id: 'd1' });
  });

  it('sends a key as chosen and "none" as an empty string, not null', async () => {
    await createDeal(event, { name: 'Renewal', lead_source: 'google ads', description: '' });
    const first = apiRequest.mock.calls[0][1].body;
    expect(first.lead_source).toBe('google ads');
    expect(first.description).toBeNull();

    await updateDeal(event, 'd1', { lead_source: '' });
    expect(apiRequest.mock.calls[1][1].body).toEqual({ lead_source: '' });
  });
});

describe('files and comments on a deal', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('lists the files through the download proxy, never a storage path', async () => {
    apiRequest.mockImplementation(async (path: string) => {
      if (path.startsWith('/opportunities/pipelines/')) return { pipelines: [] };
      return {
        opportunity_obj: {
          id: 'd1',
          name: 'Acme',
          created_at: '2026-10-01T00:00:00Z',
          line_items: []
        },
        comments: [],
        attachments: [
          {
            id: 'f1',
            file_name: 'sow.pdf',
            created_at: '2026-10-02T00:00:00Z',
            file_path: 'https://bucket/sow.pdf'
          }
        ]
      };
    });
    const { files } = await getDeal(event, 'd1');
    expect(files).toEqual([
      {
        id: 'f1',
        name: 'sow.pdf',
        at: '2026-10-02T00:00:00Z',
        href: '/api/attachments/f1/download'
      }
    ]);
  });

  it('posts a comment as JSON and a file as the opportunity attachment', async () => {
    apiRequest.mockResolvedValue({});
    await addDealNote(event, 'd1', 'Signed');
    expect(apiRequest.mock.calls[0].slice(0, 2)).toEqual([
      '/opportunities/d1/',
      { method: 'POST', body: { comment: 'Signed' } }
    ]);

    await addDealNote(event, 'd1', 'With the SOW', new File(['x'], 'sow.pdf'));
    const body = apiRequest.mock.calls[1][1].body;
    expect(body.get('opportunity_attachment')).toBeInstanceOf(File);
    expect(body.get('comment')).toBe('With the SOW');
  });
});

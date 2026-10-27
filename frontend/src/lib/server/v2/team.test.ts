import { describe, expect, it, vi } from 'vitest';
const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...args: any[]) => apiRequest(...args) }));
const { listTeam } = await import('./team.js');

it('loads every team and active member and tracks membership by Profile id', async () => {
  const member = (id: string) => ({
    id,
    user_details: { id: `user-${id}`, name: id, email: `${id}@example.com` },
    phone: '+15551112222',
    alternate_phone: '+15553334444',
    role: 'USER',
    is_active: true
  });
  const team = (id: string, users: { id: string }[]) => ({ id, name: id, users });
  apiRequest.mockImplementation(async (path: string) => {
    if (path === '/teams/') return { teams_count: 2, teams: [team('a', [{ id: 'p1' }])] };
    if (path === '/teams/?offset=1') return { teams: [team('b', [{ id: 'p2' }])] };
    if (path === '/users/')
      return {
        active_users: { active_users_count: 2, active_users: [member('p1')] },
        inactive_users: { inactive_users_count: 0, inactive_users: [] }
      };
    if (path === '/users/?offset=1')
      return {
        active_users: { active_users: [member('p2')] },
        inactive_users: { inactive_users: [] }
      };
    throw new Error(`Unexpected ${path}`);
  });
  const result = await listTeam({ cookies: { get: () => undefined } as any });
  expect(result.forbidden).toBe(false);
  if (result.forbidden) return;
  expect(result.active.map((m) => [m.id, m.teams])).toEqual([
    ['p1', ['a']],
    ['p2', ['b']]
  ]);
  expect(result.active[0].phone).toBe('+15551112222');
  expect(result.active[0].alternate_phone).toBe('+15553334444');
  expect(result.teams.map((t) => t.profile_ids)).toEqual([['p1'], ['p2']]);
});

describe('team permissions', () => {
  it('renders the forbidden state when the API rejects a non-admin', async () => {
    apiRequest.mockRejectedValue(Object.assign(new Error('forbidden'), { status: 403 }));
    expect(await listTeam({ cookies: { get: () => undefined } as any })).toEqual({
      forbidden: true
    });
  });
});

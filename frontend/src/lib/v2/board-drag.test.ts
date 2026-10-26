import { describe, it, expect, vi } from 'vitest';
import { canMoveCard, holdLockedCard } from './board-drag.js';

/**
 * A stand-in for a DOM node: `closest('[data-locked]')` answers whether the
 * node sits inside a locked card, which is all the handler asks.
 */
function node(insideLocked: boolean) {
  return {
    closest: (sel: string) => (sel === '[data-locked]' && insideLocked ? {} : null)
  };
}

function event(type: string, insideLocked: boolean, key?: string) {
  return { type, key, target: node(insideLocked), stopPropagation: vi.fn() };
}

describe('canMoveCard', () => {
  it('is true only when the server says true', () => {
    expect(canMoveCard({ can_move: true })).toBe(true);
    expect(canMoveCard({ can_move: false })).toBe(false);
  });

  it('locks a card whose payload has no flag, or a truthy non-boolean', () => {
    expect(canMoveCard({})).toBe(false);
    expect(canMoveCard({ can_move: 'true' })).toBe(false);
    expect(canMoveCard({ can_move: 1 })).toBe(false);
    expect(canMoveCard(null as any)).toBe(false);
  });
});

describe('holdLockedCard', () => {
  it('stops a pointer or touch press that starts inside a locked card', () => {
    for (const type of ['mousedown', 'touchstart']) {
      const e = event(type, true);
      holdLockedCard(e);
      expect(e.stopPropagation).toHaveBeenCalledOnce();
    }
  });

  it('stops Space and Enter on a locked card, the keys that start a keyboard drag', () => {
    for (const key of [' ', 'Enter']) {
      const e = event('keydown', true, key);
      holdLockedCard(e);
      expect(e.stopPropagation).toHaveBeenCalledOnce();
    }
  });

  it('leaves every other key alone, so shortcuts and tabbing still work', () => {
    for (const key of ['Tab', 'ArrowDown', 'k', 'Escape']) {
      const e = event('keydown', true, key);
      holdLockedCard(e);
      expect(e.stopPropagation).not.toHaveBeenCalled();
    }
  });

  it('lets a movable card be picked up', () => {
    for (const [type, key] of [
      ['mousedown', undefined],
      ['touchstart', undefined],
      ['keydown', ' ']
    ]) {
      const e = event(type as string, false, key);
      holdLockedCard(e);
      expect(e.stopPropagation).not.toHaveBeenCalled();
    }
  });

  it('ignores a target that is not an element', () => {
    const e = { type: 'mousedown', target: null, stopPropagation: vi.fn() };
    holdLockedCard(e);
    expect(e.stopPropagation).not.toHaveBeenCalled();
  });
});

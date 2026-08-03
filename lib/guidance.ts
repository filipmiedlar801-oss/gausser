export const GUIDANCE_TEXT: Record<string, string> = {
  initializing: 'Rozglądaj się powoli — uruchamianie śledzenia…',
  tracking_lost: 'Utracono śledzenie — wróć powoli w poprzednie miejsce',
  tracking_limited: 'Słabe śledzenie — poruszaj się wolniej',
  slow_down: 'Zwolnij — ruch rozmazuje zdjęcia',
  rotate_slower: 'Obracaj telefon wolniej',
  hold_still: 'Przytrzymaj stabilnie — czekam na ostry kadr',
  too_dark: 'Za ciemno — włącz więcej światła',
  move_closer: 'Podejdź bliżej ścian',
  too_close: 'Odsuń się trochę',
  show_ceiling: 'Pokaż sufit',
  show_floor: 'Pokaż podłogę',
  more_angles: 'Obejdź z innych kątów — potrzeba wielu perspektyw',
  goto_gap: 'Idź do zaznaczonego miejsca',
  waypoint_reached: 'Miejsce uzupełnione ✓',
  area_completed: 'Obszar zeskanowany ✓',
  good: 'Dobrze, tak trzymaj',
};

export const TRANSIENT_CODES = new Set(['waypoint_reached', 'area_completed']);

export function guidanceText(code: string): string {
  return GUIDANCE_TEXT[code] ?? '';
}

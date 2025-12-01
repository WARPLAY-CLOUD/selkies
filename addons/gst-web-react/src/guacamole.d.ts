/**
 * Типы для библиотеки Guacamole.Keyboard
 */

declare namespace Guacamole {
  class Keyboard {
    onkeydown: ((keysym: number) => boolean | void) | null;
    onkeyup: ((keysym: number) => void) | null;
    modifiers: Keyboard.ModifierState;
    pressed: { [keysym: number]: boolean };

    constructor(element?: Window | Document);

    reset(): void;
    listenTo(element: Window | Document): void;
  }

  namespace Keyboard {
    class ModifierState {
      shift: boolean;
      ctrl: boolean;
      alt: boolean;
      meta: boolean;
      hyper: boolean;

      static fromKeyboardEvent(e: KeyboardEvent): ModifierState;
    }
  }
}

declare var Guacamole: {
  Keyboard: typeof Guacamole.Keyboard;
};


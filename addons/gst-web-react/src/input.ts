/**
 * Обработка ввода для WebRTC веб-приложения
 */

import { Queue } from './util';
import type { WarplayControl } from './warplayControl';

export interface InputCallbacks {
  onmenuhotkey?: () => void;
  onfullscreenhotkey?: () => void;
  onresizeend?: () => void;
}

type Listener = [EventTarget, string, EventListener];


export class Input {
  public element: HTMLVideoElement;
  private control: WarplayControl | null = null;
  public mouseRelative: boolean = false;
  private buttonMask: number = 0;
  private pressedKeys: Set<number> = new Set();
  public x: number = 0;
  public y: number = 0;
  public cursorScaleFactor: number | null = null;

  private callbacks: InputCallbacks = {};
  private listeners: Listener[] = [];
  private listeners_context: Listener[] = [];
  private _queue: Queue<number> = new Queue();

  // Переменные для resize
  private _rtime: Date | null = null;
  private _rtimeout: boolean = false;
  private _rdelta: number = 500;

  // Переменные для мыши и тачпада
  private _allowTrackpadScrolling: boolean = true;
  private _allowThreshold: boolean = true;
  private _smallestDeltaY: number = 10000;
  private _wheelThreshold: number = 100;
  private _scrollMagnitude: number = 10;

  constructor(element: HTMLVideoElement) {
    this.element = element;
  }

  setControl(control: WarplayControl | null): void {
    this.control = control;
  }

  setCallbacks(callbacks: InputCallbacks): void {
    this.callbacks = { ...this.callbacks, ...callbacks };
  }

  private warplayAbsMouseFromClient(clientX: number, clientY: number): { x16: number; y16: number } | null {
    const videoW = this.element.videoWidth;
    const videoH = this.element.videoHeight;
    if (!videoW || !videoH) return null;

    const rect = this.element.getBoundingClientRect();
    const containerW = rect.width;
    const containerH = rect.height;
    if (!containerW || !containerH) return null;

    const fit = getComputedStyle(this.element).objectFit || 'fill';

    const toAbs = (absX: number, absY: number): { x16: number; y16: number } => {
      const clampedX = Math.max(0, Math.min(videoW, Math.round(absX)));
      const clampedY = Math.max(0, Math.min(videoH, Math.round(absY)));
      const x16 = Math.round((clampedX / videoW) * 65535);
      const y16 = Math.round((clampedY / videoH) * 65535);
      return { x16, y16 };
    };

    const localX0 = clientX - rect.left;
    const localY0 = clientY - rect.top;

    // If the element stretches the video (default object-fit: fill), map directly to the element box.
    if (fit === 'fill') {
      const absX = localX0 * (videoW / containerW);
      const absY = localY0 * (videoH / containerH);
      return toAbs(absX, absY);
    }

    // Otherwise, approximate based on the selected fit mode.
    let ratio: number;
    if (fit === 'cover') {
      ratio = Math.max(containerW / videoW, containerH / videoH);
    } else if (fit === 'scale-down') {
      ratio = Math.min(1, Math.min(containerW / videoW, containerH / videoH));
    } else if (fit === 'none') {
      ratio = 1;
    } else {
      // contain (default)
      ratio = Math.min(containerW / videoW, containerH / videoH);
    }

    const dispW = videoW * ratio;
    const dispH = videoH * ratio;
    const offsetX = (containerW - dispW) / 2;
    const offsetY = (containerH - dispH) / 2;

    const localX = localX0 - offsetX;
    const localY = localY0 - offsetY;

    const clampedLocalX = Math.max(0, Math.min(dispW, localX));
    const clampedLocalY = Math.max(0, Math.min(dispH, localY));

    const absX = clampedLocalX * (videoW / dispW);
    const absY = clampedLocalY * (videoH / dispH);
    return toAbs(absX, absY);
  }

  /**
   * Вычисляет масштабный коэффициент курсора когда клиент и сервер имеют разные разрешения
   */
  getCursorScaleFactor({ remoteResolutionEnabled = false }: { remoteResolutionEnabled?: boolean } = {}): void {
    if (remoteResolutionEnabled) {
      this.cursorScaleFactor = null;
      return;
    }

    const clientResolution = this.getWindowResolution();
    const serverHeight = this.element.videoHeight;
    const serverWidth = this.element.videoWidth;

    if (isNaN(serverWidth) || isNaN(serverHeight)) {
      console.log("Invalid video height and width");
      return;
    }

    if (Math.abs(clientResolution[0] - serverWidth) <= 10 && Math.abs(clientResolution[1] - serverHeight) <= 10) {
      return;
    }

    this.cursorScaleFactor = Math.sqrt((serverWidth ** 2) + (serverHeight ** 2)) / Math.sqrt((clientResolution[0] ** 2) + (clientResolution[1] ** 2));
  }

  /**
   * Обрабатывает события кнопок мыши и движения
   */
  private mouseButtonMovement = (event: Event): void => {
    const mouseEvent = event as MouseEvent;
    const down = (mouseEvent.type === 'mousedown' ? 1 : 0);

    if (!document.pointerLockElement) {
      if (this.mouseRelative) {
        this.element.requestPointerLock().then(
          () => {
            console.log("pointer lock success");
          }
        ).catch(
          (e) => {
            console.log("pointer lock failed: ", e);
          }
        );
      }
    }

    // Горячая клавиша для включения pointer lock, Ctrl-Shift-LeftClick
    if (down && mouseEvent.button === 0 && mouseEvent.ctrlKey && mouseEvent.shiftKey) {
      this.element.requestPointerLock().then(
        () => {
          console.log("pointer lock success");
        }
      ).catch(
        (e) => {
          console.log("pointer lock failed: ", e);
        }
      );
      return;
    }

    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();
    if (controlConfigured && !controlReady) {
      mouseEvent.preventDefault();
      mouseEvent.stopPropagation();
      return;
    }
    if (!controlReady) return;

    if (document.pointerLockElement) {
      if (this.cursorScaleFactor != null) {
        this.x = Math.trunc(mouseEvent.movementX * this.cursorScaleFactor);
        this.y = Math.trunc(mouseEvent.movementY * this.cursorScaleFactor);
      } else {
        this.x = mouseEvent.movementX;
        this.y = mouseEvent.movementY;
      }

      if (mouseEvent.type === 'mousemove' && (this.x !== 0 || this.y !== 0)) {
        this.control!.sendInputPacket(this.control!.encodeMouseMove(this.x, this.y));
        mouseEvent.preventDefault();
        mouseEvent.stopPropagation();
        return;
      }
    } else if (mouseEvent.type === 'mousemove') {
      const abs = this.warplayAbsMouseFromClient(mouseEvent.clientX, mouseEvent.clientY);
      if (abs) {
        this.control!.sendInputPacket(this.control!.encodeAbsMouse(abs.x16, abs.y16));
        mouseEvent.preventDefault();
        mouseEvent.stopPropagation();
        return;
      }
    }

    if (mouseEvent.type === 'mousedown' || mouseEvent.type === 'mouseup') {
      this.control!.sendInputPacket(this.control!.encodeMouseButton(mouseEvent.button, down === 1));
      const mask = 1 << mouseEvent.button;
      if (down) {
        this.buttonMask |= mask;
      } else {
        this.buttonMask &= ~mask;
      }
      mouseEvent.preventDefault();
      mouseEvent.stopPropagation();
    }
  };

  /**
   * Обрабатывает touch события
   */
  private touch = (event: Event): void => {
    const touchEvent = event as TouchEvent;
    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();

    if (touchEvent.type === 'touchstart') {
      this.buttonMask |= 1;
    } else if (touchEvent.type === 'touchend') {
      this.buttonMask &= ~1;
    } else if (touchEvent.type === 'touchmove') {
      touchEvent.preventDefault();
    }

    const clientX = touchEvent.changedTouches[0].clientX;
    const clientY = touchEvent.changedTouches[0].clientY;

    if (controlConfigured && !controlReady) {
      touchEvent.preventDefault();
      return;
    }
    if (!controlReady) return;

    const abs = this.warplayAbsMouseFromClient(clientX, clientY);
    if (abs) {
      this.control!.sendInputPacket(this.control!.encodeAbsMouse(abs.x16, abs.y16));
    }
    if (touchEvent.type === 'touchstart') {
      this.control!.sendInputPacket(this.control!.encodeMouseButton(0, true));
    } else if (touchEvent.type === 'touchend') {
      this.control!.sendInputPacket(this.control!.encodeMouseButton(0, false));
    }
  };

  /**
   * Сбрасывает порог если значения указателя относятся к типу мыши
   */
  private dropThreshold(): boolean {
    let count = 0;
    let val1 = this._queue.dequeue();
    while (!this._queue.isEmpty()) {
      const valNext = this._queue.dequeue();
      if (valNext !== undefined && valNext >= 80 && val1 === valNext) {
        count++;
      }
      val1 = valNext;
    }
    return count >= 2;
  }

  /**
   * Обертка для _mouseWheel для корректировки прокрутки в зависимости от устройства указателя
   */
  private mouseWheelWrapper = (event: Event): void => {
    const wheelEvent = event as WheelEvent;
    const deltaY = Math.trunc(Math.abs(wheelEvent.deltaY));

    if (this._queue.size() < 4) {
      this._queue.enqueue(deltaY);
    }

    if (this._queue.size() === 4) {
      if (this.dropThreshold()) {
        this._allowThreshold = false;
        this._smallestDeltaY = 10000;
      } else {
        this._allowThreshold = true;
      }
    }

    if (this._allowThreshold && this._allowTrackpadScrolling) {
      this._allowTrackpadScrolling = false;
      this.mouseWheel(wheelEvent);
      setTimeout(() => this._allowTrackpadScrolling = true, this._wheelThreshold);
    } else if (!this._allowThreshold) {
      this.mouseWheel(wheelEvent);
    }
  };

  /**
   * Обрабатывает события колесика мыши
   */
  private mouseWheel = (event: WheelEvent): void => {
    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();
    if (controlConfigured && !controlReady) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    if (controlReady) {
      this.control!.sendInputPacket(this.control!.encodeWheel(-event.deltaY));
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    // Legacy scroll-to-datachannel is removed; prevent page scroll while over the video element.
    event.preventDefault();
  };

  /**
   * Захватывает контекстное меню мыши (правый клик) и предотвращает распространение события
   */
  private contextMenu = (event: Event): void => {
    event.preventDefault();
  };

  /**
   * Захватывает события клавиатуры для обнаружения нажатия CTRL-SHIFT горячих клавиш
   */
  private key = (event: Event): void => {
    const keyboardEvent = event as KeyboardEvent;
    // Отключаем проблемные горячие клавиши браузера
    if ((keyboardEvent.code === 'F5' && keyboardEvent.ctrlKey) ||
      (keyboardEvent.code === 'KeyI' && keyboardEvent.ctrlKey && keyboardEvent.shiftKey) ||
      (keyboardEvent.code === 'F11')) {
      keyboardEvent.preventDefault();
      return;
    }

    // Захватываем горячую клавишу меню
    if (keyboardEvent.type === 'keydown' && keyboardEvent.code === 'KeyM' && keyboardEvent.ctrlKey && keyboardEvent.shiftKey) {
      if (document.fullscreenElement === null && this.callbacks.onmenuhotkey) {
        this.callbacks.onmenuhotkey();
        keyboardEvent.preventDefault();
      }
      return;
    }

    // Захватываем горячую клавишу полноэкранного режима
    if (keyboardEvent.type === 'keydown' && keyboardEvent.code === 'KeyF' && keyboardEvent.ctrlKey && keyboardEvent.shiftKey) {
      if (document.fullscreenElement === null && this.callbacks.onfullscreenhotkey) {
        this.callbacks.onfullscreenhotkey();
        keyboardEvent.preventDefault();
      }
      return;
    }

    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();
    if (controlReady) {
      // warplay control expects vk_code (u16). Use legacy keyCode for compatibility.
      const vk = keyboardEvent.keyCode || 0;
      const down = keyboardEvent.type === 'keydown';
      this.control!.sendInputPacket(this.control!.encodeKey(vk, down));
      if (vk) {
        if (down) this.pressedKeys.add(vk);
        else this.pressedKeys.delete(vk);
      }
      keyboardEvent.preventDefault();
      keyboardEvent.stopPropagation();
    } else if (controlConfigured) {
      keyboardEvent.preventDefault();
      keyboardEvent.stopPropagation();
    }
  };

  private exitPointerLock = (): void => {
    try {
      document.exitPointerLock();
    } catch { }
  };

  // Gamepad input is handled by Warplay control-plane (separate WebRTC connection).

  /**
   * Когда включается полноэкранный режим, запрашивает блокировку клавиатуры и указателя
   */
  private onFullscreenChange = (): void => {
    if (document.fullscreenElement !== null) {
      if (document.pointerLockElement === null) {
        this.element.requestPointerLock().then(
          () => {
            console.log("pointer lock success");
          }
        ).catch(
          (e) => {
            console.log("pointer lock failed: ", e);
          }
        );
      }
      this.requestKeyboardLock();
    }
    this.resetInputState();
  };

  /**
   * Вызывается когда окно изменяет размер, используется для обнаружения когда изменение размера заканчивается
   */
  private resizeStart = (): void => {
    this._rtime = new Date();
    if (this._rtimeout === false) {
      this._rtimeout = true;
      setTimeout(() => { this.resizeEnd(); }, this._rdelta);
    }
  };

  /**
   * Вызывается в setTimeout цикле для обнаружения если изменение размера окна завершено
   */
  private resizeEnd = (): void => {
    if (this._rtime && new Date().getTime() - this._rtime.getTime() < this._rdelta) {
      setTimeout(() => { this.resizeEnd(); }, this._rdelta);
    } else {
      this._rtimeout = false;
      if (this.callbacks.onresizeend) {
        this.callbacks.onresizeend();
      }
    }
  };

  /**
   * Прикрепляет обработчики событий ввода к document, window и element
   */
  attach(): void {
    this.addListener(this.element.parentElement!, 'fullscreenchange', this.onFullscreenChange);
    this.addListener(window, 'resize', this.resizeStart);
    this.addListener(window, 'blur', () => this.resetInputState());
    this.addListener(document, 'visibilitychange', () => {
      if (document.visibilityState !== 'visible') this.resetInputState();
    });

    this.attach_context();
  }

  attach_context(): void {
    this.addListenerContext(this.element, 'wheel', this.mouseWheelWrapper);
    this.addListenerContext(this.element, 'contextmenu', this.contextMenu);
    this.addListenerContext(window, 'keydown', this.key);
    this.addListenerContext(window, 'keyup', this.key);

    if ('ontouchstart' in window) {
      this.addListenerContext(window, 'touchstart', this.touch);
      this.addListenerContext(this.element, 'touchend', this.touch);
      this.addListenerContext(this.element, 'touchmove', this.touch);
    } else {
      this.addListenerContext(this.element, 'mousemove', this.mouseButtonMovement);
      this.addListenerContext(this.element, 'mousedown', this.mouseButtonMovement);
      this.addListenerContext(this.element, 'mouseup', this.mouseButtonMovement);
    }

    if (document.fullscreenElement !== null && document.pointerLockElement === null) {
      this.element.requestPointerLock().then(
        () => {
          console.log("pointer lock success");
        }
      ).catch(
        (e) => {
          console.log("pointer lock failed: ", e);
        }
      );
    }
  }

  detach(): void {
    this.removeListeners(this.listeners);
    this.detach_context();
  }

  detach_context(): void {
    this.removeListeners(this.listeners_context);
    this.resetInputState();
    this.exitPointerLock();
  }

  resetInputState(): void {
    if (!this.control || !this.control.isConnected()) {
      this.pressedKeys.clear();
      this.buttonMask = 0;
      return;
    }

    for (const vk of this.pressedKeys) {
      this.control.sendInputPacket(this.control.encodeKey(vk, false));
    }
    this.pressedKeys.clear();

    for (let button = 0; button <= 7; button++) {
      if (this.buttonMask & (1 << button)) {
        this.control.sendInputPacket(this.control.encodeMouseButton(button, false));
      }
    }
    this.buttonMask = 0;
  }

  enterFullscreen(): void {
    if (document.pointerLockElement === null) {
      this.element.requestPointerLock().then(
        () => {
          console.log("pointer lock success");
        }
      ).catch(
        (e) => {
          console.log("pointer lock failed: ", e);
        }
      );
    }
    if (document.fullscreenElement === null) {
      this.element.parentElement!.requestFullscreen().then(
        () => {
          console.log("fullscreen success");
        }
      ).catch(
        (e) => {
          console.log("fullscreen failed: ", e);
        }
      );
    }
  }

  /**
   * Запрашивает блокировку клавиатуры, должен быть в полноэкранном режиме для работы
   */
  requestKeyboardLock(): void {
    if ('keyboard' in navigator && 'lock' in (navigator as any).keyboard) {
      const keys = [
        "AltLeft",
        "AltRight",
        "Tab",
        "Escape",
        "ContextMenu",
        "MetaLeft",
        "MetaRight"
      ];
      console.log("requesting keyboard lock");
      (navigator as any).keyboard.lock(keys).then(
        () => {
          console.log("keyboard lock success");
        }
      ).catch(
        (e: any) => {
          console.log("keyboard lock failed: ", e);
        }
      );
    }
  }

  getWindowResolution(): [number, number] {
    return [
      parseInt(String((() => {
        const offsetRatioWidth = document.body.offsetWidth * window.devicePixelRatio;
        return offsetRatioWidth - offsetRatioWidth % 2;
      })())),
      parseInt(String((() => {
        const offsetRatioHeight = document.body.offsetHeight * window.devicePixelRatio;
        return offsetRatioHeight - offsetRatioHeight % 2;
      })()))
    ];
  }

  /**
   * Принудительно обновляет математику окна (область ввода) после изменения размера
   * Используется когда размер видео элемента изменяется программно
   */
  updateWindowMath(): void {
    // Используем requestAnimationFrame для обновления после того, как браузер обновит размеры
    requestAnimationFrame(() => {
      // No-op: legacy window math removed (input is mapped to the video element rect).
    });
  }

  private addListener(target: EventTarget, event: string, handler: EventListener): void {
    target.addEventListener(event, handler);
    this.listeners.push([target, event, handler]);
  }

  private addListenerContext(target: EventTarget, event: string, handler: EventListener): void {
    target.addEventListener(event, handler);
    this.listeners_context.push([target, event, handler]);
  }

  private removeListeners(listeners: Listener[]): void {
    listeners.forEach(([target, event, handler]) => {
      target.removeEventListener(event, handler);
    });
  }
}

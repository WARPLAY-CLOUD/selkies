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

interface WindowMath {
  mouseMultiX: number;
  mouseMultiY: number;
  mouseOffsetX: number;
  mouseOffsetY: number;
  centerOffsetX: number;
  centerOffsetY: number;
  scrollX: number;
  scrollY: number;
  frameW: number;
  frameH: number;
}

type Listener = [EventTarget, string, EventListener];


export class Input {
  public element: HTMLVideoElement;
  private send: (data: string) => void;
  private control: WarplayControl | null = null;
  public mouseRelative: boolean = false;
  public m: WindowMath | null = null;
  private buttonMask: number = 0;
  private keyboard: Guacamole.Keyboard | null = null;
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

  constructor(element: HTMLVideoElement, send: (data: string) => void) {
    this.element = element;
    this.send = send;
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

    const ratio = Math.min(containerW / videoW, containerH / videoH);
    const dispW = videoW * ratio;
    const dispH = videoH * ratio;
    const offsetX = Math.max((containerW - dispW) / 2, 0);
    const offsetY = Math.max((containerH - dispH) / 2, 0);

    const localX = (clientX - rect.left) - offsetX;
    const localY = (clientY - rect.top) - offsetY;
    if (localX < 0 || localY < 0 || localX > dispW || localY > dispH) return null;

    const absX = Math.max(0, Math.min(videoW, Math.round(localX * (videoW / dispW))));
    const absY = Math.max(0, Math.min(videoH, Math.round(localY * (videoH / dispH))));

    const x16 = Math.round((absX / videoW) * 65535);
    const y16 = Math.round((absY / videoH) * 65535);
    return { x16, y16 };
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
    let mtype = "m";

    if (mouseEvent.type === 'mousemove' && !this.m) return;

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
    if (document.pointerLockElement) {
      mtype = "m2";
      if (this.cursorScaleFactor != null) {
        this.x = Math.trunc(mouseEvent.movementX * this.cursorScaleFactor);
        this.y = Math.trunc(mouseEvent.movementY * this.cursorScaleFactor);
      } else {
        this.x = mouseEvent.movementX;
        this.y = mouseEvent.movementY;
      }

      if (controlReady && mouseEvent.type === 'mousemove' && (this.x !== 0 || this.y !== 0)) {
        this.control!.sendInputPacket(this.control!.encodeMouseMove(this.x, this.y));
        mouseEvent.preventDefault();
        mouseEvent.stopPropagation();
        return;
      }
    } else if (mouseEvent.type === 'mousemove') {
      this.x = this.clientToServerX(mouseEvent.clientX);
      this.y = this.clientToServerY(mouseEvent.clientY);

      if (controlReady) {
        const abs = this.warplayAbsMouseFromClient(mouseEvent.clientX, mouseEvent.clientY);
        if (abs) {
          this.control!.sendInputPacket(this.control!.encodeAbsMouse(abs.x16, abs.y16));
          mouseEvent.preventDefault();
          mouseEvent.stopPropagation();
          return;
        }
      }
    }

    if (mouseEvent.type === 'mousedown' || mouseEvent.type === 'mouseup') {
      if (controlReady) {
        this.control!.sendInputPacket(this.control!.encodeMouseButton(mouseEvent.button, down === 1));
        mouseEvent.preventDefault();
        mouseEvent.stopPropagation();
        return;
      }
      const mask = 1 << mouseEvent.button;
      if (down) {
        this.buttonMask |= mask;
      } else {
        this.buttonMask &= ~mask;
      }
    }

    const toks = [
      mtype,
      this.x,
      this.y,
      this.buttonMask,
      0
    ];

    this.send(toks.join(","));
    mouseEvent.preventDefault();
  };

  /**
   * Обрабатывает touch события
   */
  private touch = (event: Event): void => {
    const touchEvent = event as TouchEvent;
    const mtype = "m";
    const mask = 1;
    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();

    if (touchEvent.type === 'touchstart') {
      this.buttonMask |= mask;
    } else if (touchEvent.type === 'touchend') {
      this.buttonMask &= ~mask;
    } else if (touchEvent.type === 'touchmove') {
      touchEvent.preventDefault();
    }

    const clientX = touchEvent.changedTouches[0].clientX;
    const clientY = touchEvent.changedTouches[0].clientY;

    if (controlConfigured && !controlReady) {
      touchEvent.preventDefault();
      return;
    }

    if (controlReady) {
      const abs = this.warplayAbsMouseFromClient(clientX, clientY);
      if (abs) {
        this.control!.sendInputPacket(this.control!.encodeAbsMouse(abs.x16, abs.y16));
      }
      if (touchEvent.type === 'touchstart') {
        this.control!.sendInputPacket(this.control!.encodeMouseButton(0, true));
      } else if (touchEvent.type === 'touchend') {
        this.control!.sendInputPacket(this.control!.encodeMouseButton(0, false));
      }
      return;
    }

    this.x = this.clientToServerX(clientX);
    this.y = this.clientToServerY(clientY);

    const toks = [
      mtype,
      this.x,
      this.y,
      this.buttonMask,
      0
    ];

    this.send(toks.join(","));
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

    const mtype = (document.pointerLockElement ? "m2" : "m");
    let button = 3;
    if (event.deltaY < 0) {
      button = 4;
    }

    let deltaY = Math.abs(Math.trunc(event.deltaY));

    if (deltaY < this._smallestDeltaY && deltaY != 0) {
      this._smallestDeltaY = deltaY;
    }

    deltaY = Math.floor(deltaY / this._smallestDeltaY);
    const magnitude = Math.min(deltaY, this._scrollMagnitude);
    const mask = 1 << button;

    // Симулируем нажатие и отпускание кнопки
    for (let i = 0; i < 2; i++) {
      if (i === 0) {
        this.buttonMask |= mask;
      } else {
        this.buttonMask &= ~mask;
      }
      const toks = [
        mtype,
        this.x,
        this.y,
        this.buttonMask,
        magnitude
      ];
      this.send(toks.join(","));
    }

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
      keyboardEvent.preventDefault();
      keyboardEvent.stopPropagation();
    } else if (controlConfigured) {
      keyboardEvent.preventDefault();
      keyboardEvent.stopPropagation();
    }
  };

  /**
   * Отправляет команду WebRTC приложению для переключения отображения удаленного указателя мыши
   */
  private pointerLock = (): void => {
    if (this.control) {
      // Cursor visibility is controlled via cursor sprite packets from control-plane.
      return;
    }
    if (document.pointerLockElement !== null) {
      this.send("p,1");
      console.log("remote pointer visibility to: True");
    } else {
      this.send("p,0");
      console.log("remote pointer visibility to: False");
    }
  };

  /**
   * Отправляет команду WebRTC приложению для скрытия удаленного указателя при выходе из pointer lock
   */
  private exitPointerLock = (): void => {
    document.exitPointerLock();
    if (!this.control) {
      this.send("p,0");
      console.log("remote pointer visibility to: False");
    }
  };

  /**
   * Захватывает размеры дисплея и видео, необходимые для вычисления позиции указателя мыши
   */
  private windowMath = (): void => {
    const windowW = this.element.offsetWidth;
    const windowH = this.element.offsetHeight;
    const frameW = this.element.videoWidth;
    const frameH = this.element.videoHeight;

    const multi = Math.min(windowW / frameW, windowH / frameH);
    const vpWidth = frameW * multi;
    const vpHeight = (frameH * multi);

    this.m = {
      mouseMultiX: frameW / vpWidth,
      mouseMultiY: frameH / vpHeight,
      mouseOffsetX: Math.max((windowW - vpWidth) / 2.0, 0),
      mouseOffsetY: Math.max((windowH - vpHeight) / 2.0, 0),
      centerOffsetX: 0,
      centerOffsetY: 0,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      frameW,
      frameH,
    };
  };

  /**
   * Переводит позицию указателя X на основе текущей математики окна
   */
  private clientToServerX(clientX: number): number {
    if (!this.m) return 0;
    let serverX = Math.round((clientX - this.m.mouseOffsetX - this.m.centerOffsetX + this.m.scrollX) * this.m.mouseMultiX);

    if (serverX === this.m.frameW - 1) serverX = this.m.frameW;
    if (serverX > this.m.frameW) serverX = this.m.frameW;
    if (serverX < 0) serverX = 0;

    return serverX;
  }

  /**
   * Переводит позицию указателя Y на основе текущей математики окна
   */
  private clientToServerY(clientY: number): number {
    if (!this.m) return 0;
    let serverY = Math.round((clientY - this.m.mouseOffsetY - this.m.centerOffsetY + this.m.scrollY) * this.m.mouseMultiY);

    if (serverY === this.m.frameH - 1) serverY = this.m.frameH;
    if (serverY > this.m.frameH) serverY = this.m.frameH;
    if (serverY < 0) serverY = 0;

    return serverY;
  }

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
    // Сбрасываем локальную клавиатуру
    if (this.keyboard !== null) {
      this.keyboard.reset();
    }
    // Сбрасываем застрявшие клавиши на стороне сервера
    this.send("kr");
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
    this.addListener(this.element, 'resize', this.windowMath);
    this.addListener(document, 'pointerlockchange', this.pointerLock);
    this.addListener(this.element.parentElement!, 'fullscreenchange', this.onFullscreenChange);
    this.addListener(window, 'resize', this.windowMath);
    this.addListener(window, 'resize', this.resizeStart);

    // Корректировка для scroll offset
    this.addListener(window, 'scroll', () => {
      if (this.m) {
        this.m.scrollX = window.scrollX;
        this.m.scrollY = window.scrollY;
      }
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

      if (!this.control) {
        console.log("Enabling mouse pointer display for touch devices.");
        this.send("p,1");
        console.log("remote pointer visibility to: True");
      }
    } else {
      this.addListenerContext(this.element, 'mousemove', this.mouseButtonMovement);
      this.addListenerContext(this.element, 'mousedown', this.mouseButtonMovement);
      this.addListenerContext(this.element, 'mouseup', this.mouseButtonMovement);
    }

    // Используем Guacamole.Keyboard только для legacy Selkies управления.
    // Для Warplay control-plane клавиши отправляются через this.key (vk_code).
    if (!this.control) {
      this.keyboard = new Guacamole.Keyboard(window);
      this.keyboard.onkeydown = (keysym) => {
        this.send("kd," + keysym);
      };
      this.keyboard.onkeyup = (keysym) => {
        this.send("ku," + keysym);
      };
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

    this.windowMath();
  }

  detach(): void {
    this.removeListeners(this.listeners);
    this.detach_context();
  }

  detach_context(): void {
    this.removeListeners(this.listeners_context);

    if (this.keyboard) {
      this.keyboard.onkeydown = null;
      this.keyboard.onkeyup = null;
      this.keyboard.reset();
      this.keyboard = null;
      this.send("kr");
    }

    this.exitPointerLock();
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
      this.windowMath();
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

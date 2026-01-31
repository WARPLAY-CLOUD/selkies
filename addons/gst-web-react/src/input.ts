/**
 * Input handling for Selkies gst-web-react using Warplay control-plane only.
 * Ported from warplay-srs-server/client (simple-webrtc-client.js) semantics.
 */

import type { WarplayControl } from './warplayControl';

export interface InputCallbacks {
  onmenuhotkey?: () => void;
  onfullscreenhotkey?: () => void;
  onresizeend?: () => void;
}

type Listener = [EventTarget, string, EventListener, AddEventListenerOptions | boolean | undefined];

type ResolutionData = {
  scaleX: number;
  scaleY: number;
  offsetX: number;
  offsetY: number;
  maxW: number;
  maxH: number;
};

export class Input {
  public element: HTMLVideoElement;
  private control: WarplayControl | null = null;

  private callbacks: InputCallbacks = {};
  private listeners: Listener[] = [];
  private listeners_context: Listener[] = [];

  private isPointerLocked = false;
  private pointerLockTimestamp = 0;
  private waitPointerLockClick = false;
  private resolutionData: ResolutionData | null = null;
  private lastVideoW = 0;
  private lastVideoH = 0;
  private resolutionProbeTimer: number | null = null;

  private prevInlineWidth: string | null = null;
  private prevInlineHeight: string | null = null;

  private pressedKeys: Set<number> = new Set();
  private buttonMask = 0;

  // Resize end detection (kept for existing UI code paths).
  private _rtime: Date | null = null;
  private _rtimeout = false;
  private _rdelta = 500;

  constructor(element: HTMLVideoElement) {
    this.element = element;
  }

  setControl(control: WarplayControl | null): void {
    this.control = control;
  }

  setCallbacks(callbacks: InputCallbacks): void {
    this.callbacks = { ...this.callbacks, ...callbacks };
  }

  private updateResolutionData(): void {
    const containerW = this.element.offsetWidth;
    const containerH = this.element.offsetHeight;
    const videoW = this.element.videoWidth;
    const videoH = this.element.videoHeight;
    if (!containerW || !containerH || !videoW || !videoH) return;

    const ratio = Math.min(containerW / videoW, containerH / videoH);
    const dispW = videoW * ratio;
    const dispH = videoH * ratio;

    this.resolutionData = {
      scaleX: videoW / dispW,
      scaleY: videoH / dispH,
      offsetX: Math.max((containerW - dispW) / 2, 0),
      offsetY: Math.max((containerH - dispH) / 2, 0),
      maxW: videoW,
      maxH: videoH,
    };
  }

  private sendAbsMouseFromEvent(e: MouseEvent): void {
    if (!this.control || !this.control.isConnected() || !this.resolutionData) return;
    const rect = this.element.getBoundingClientRect();
    const { scaleX, scaleY, offsetX, offsetY, maxW, maxH } = this.resolutionData;

    let localX = (e.clientX - rect.left) - offsetX;
    let localY = (e.clientY - rect.top) - offsetY;

    const displayedW = maxW / scaleX;
    const displayedH = maxH / scaleY;

    // Stretch the input area to the video itself: clamp to the rendered video edges.
    localX = Math.max(0, Math.min(displayedW, localX));
    localY = Math.max(0, Math.min(displayedH, localY));

    let absX = Math.round(localX * scaleX);
    let absY = Math.round(localY * scaleY);
    absX = Math.max(0, Math.min(maxW, absX));
    absY = Math.max(0, Math.min(maxH, absY));

    const x16 = Math.round((absX / maxW) * 65535);
    const y16 = Math.round((absY / maxH) * 65535);
    this.control.sendInputPacket(this.control.encodeAbsMouse(x16, y16));
  }

  private mouseMove = (event: Event): void => {
    const e = event as MouseEvent;
    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();

    if (controlConfigured && !controlReady) {
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (!controlReady) return;

    if (this.isPointerLocked) {
      const dx = e.movementX;
      const dy = e.movementY;
      if (dx !== 0 || dy !== 0) {
        this.control!.sendInputPacket(this.control!.encodeMouseMove(dx, dy));
      }
    } else {
      if (!this.resolutionData) return;
      this.sendAbsMouseFromEvent(e);
    }

    e.preventDefault();
    e.stopPropagation();
  };

  private mouseDown = (event: Event): void => {
    const e = event as MouseEvent;
    e.preventDefault();
    e.stopPropagation();

    if (this.waitPointerLockClick) {
      this.waitPointerLockClick = false;
      try {
        this.element.requestPointerLock();
      } catch { }
    }

    if (!this.control || !this.control.isConnected()) return;
    if (!this.isPointerLocked) this.sendAbsMouseFromEvent(e);

    this.control.sendInputPacket(this.control.encodeMouseButton(e.button, true));
    this.buttonMask |= 1 << e.button;
  };

  private mouseUp = (event: Event): void => {
    const e = event as MouseEvent;
    e.preventDefault();
    e.stopPropagation();
    if (!this.control || !this.control.isConnected()) return;

    if (!this.isPointerLocked) this.sendAbsMouseFromEvent(e);
    this.control.sendInputPacket(this.control.encodeMouseButton(e.button, false));
    this.buttonMask &= ~(1 << e.button);
  };

  private wheel = (event: Event): void => {
    const e = event as WheelEvent;
    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();
    if (controlConfigured && !controlReady) {
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (controlReady) {
      this.control!.sendInputPacket(this.control!.encodeWheel(-e.deltaY));
      e.preventDefault();
      e.stopPropagation();
    }
  };

  private contextMenu = (event: Event): void => {
    event.preventDefault();
    event.stopPropagation();
  };

  private key = (event: Event): void => {
    const e = event as KeyboardEvent;

    const controlConfigured = !!this.control;
    const controlReady = controlConfigured && this.control!.isConnected();
    if (controlReady) {
      const vk = e.keyCode || 0;
      const down = e.type === 'keydown';
      this.control!.sendInputPacket(this.control!.encodeKey(vk, down));
      if (vk) {
        if (down) this.pressedKeys.add(vk);
        else this.pressedKeys.delete(vk);
      }
      e.preventDefault();
      e.stopPropagation();
    } else if (controlConfigured) {
      e.preventDefault();
      e.stopPropagation();
    }
  };

  private onPointerLockChange = (): void => {
    this.isPointerLocked = (document.pointerLockElement === this.element);
    if (this.isPointerLocked) this.pointerLockTimestamp = performance.now();
    if (this.isPointerLocked) this.waitPointerLockClick = false;
  };

  private onFullscreenChange = (): void => {
    const isFullscreen = document.fullscreenElement === this.element;
    if (isFullscreen) {
      if (this.prevInlineWidth === null) this.prevInlineWidth = this.element.style.width;
      if (this.prevInlineHeight === null) this.prevInlineHeight = this.element.style.height;
      this.element.style.width = '100%';
      this.element.style.height = '100%';

      if (document.pointerLockElement === null) {
        try {
          this.element.requestPointerLock();
        } catch { }
      }
      this.requestKeyboardLock();
    } else {
      if (this.prevInlineWidth !== null) this.element.style.width = this.prevInlineWidth;
      if (this.prevInlineHeight !== null) this.element.style.height = this.prevInlineHeight;
      this.prevInlineWidth = null;
      this.prevInlineHeight = null;
    }
    this.resetInputState();
    this.updateResolutionData();
  };

  private resizeStart = (): void => {
    this._rtime = new Date();
    if (!this._rtimeout) {
      this._rtimeout = true;
      setTimeout(() => { this.resizeEnd(); }, this._rdelta);
    }
  };

  private resizeEnd = (): void => {
    if (this._rtime && new Date().getTime() - this._rtime.getTime() < this._rdelta) {
      setTimeout(() => { this.resizeEnd(); }, this._rdelta);
    } else {
      this._rtimeout = false;
      this.callbacks.onresizeend?.();
    }
  };

  attach(): void {
    try {
      this.element.setAttribute('tabindex', '0');
    } catch { }

    this.addListener(document, 'pointerlockchange', this.onPointerLockChange);
    this.addListener(document, 'pointerlockerror', () => { }, undefined);
    this.addListener(this.element, 'loadedmetadata', () => this.updateResolutionData());
    this.addListener(window, 'resize', () => this.updateResolutionData());
    this.addListener(window, 'resize', this.resizeStart);
    this.addListener(document, 'fullscreenchange', this.onFullscreenChange);
    this.addListener(window, 'blur', () => this.resetInputState());
    this.addListener(document, 'visibilitychange', () => {
      if (document.visibilityState !== 'visible') this.resetInputState();
    });

    // Detect video resolution changes (requestVideoFrameCallback if available).
    const checkResolutionChange = () => {
      const w = this.element.videoWidth;
      const h = this.element.videoHeight;
      if (w && h && (w !== this.lastVideoW || h !== this.lastVideoH)) {
        this.lastVideoW = w;
        this.lastVideoH = h;
        this.updateResolutionData();
      }
    };

    if ((this.element as any).requestVideoFrameCallback) {
      const loop = () => {
        checkResolutionChange();
        (this.element as any).requestVideoFrameCallback(loop);
      };
      (this.element as any).requestVideoFrameCallback(loop);
    } else {
      this.resolutionProbeTimer = window.setInterval(checkResolutionChange, 500);
    }

    this.updateResolutionData();
    this.attach_context();
  }

  attach_context(): void {
    this.addListenerContext(this.element, 'mousemove', this.mouseMove, { passive: false });
    this.addListenerContext(this.element, 'mousedown', this.mouseDown, { passive: false });
    this.addListenerContext(this.element, 'mouseup', this.mouseUp, { passive: false });
    this.addListenerContext(this.element, 'wheel', this.wheel, { passive: false });
    this.addListenerContext(this.element, 'contextmenu', this.contextMenu, { passive: false });
    this.addListenerContext(window, 'keydown', this.key, undefined);
    this.addListenerContext(window, 'keyup', this.key, undefined);
  }

  detach(): void {
    this.removeListeners(this.listeners);
    this.detach_context();
    if (this.resolutionProbeTimer !== null) {
      window.clearInterval(this.resolutionProbeTimer);
      this.resolutionProbeTimer = null;
    }
  }

  detach_context(): void {
    this.removeListeners(this.listeners_context);
    this.resetInputState();
    try { document.exitPointerLock(); } catch { }
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
    try {
      if (document.pointerLockElement === null) this.element.requestPointerLock();
    } catch { }
    try {
      if (document.fullscreenElement === null) this.element.requestFullscreen();
    } catch { }
  }

  requestKeyboardLock(): void {
    if ('keyboard' in navigator && 'lock' in (navigator as any).keyboard) {
      const keys = ["AltLeft", "AltRight", "Tab", "Escape", "ContextMenu", "MetaLeft", "MetaRight"];
      (navigator as any).keyboard.lock(keys).catch(() => { });
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

  getCursorScaleFactor({ remoteResolutionEnabled = false }: { remoteResolutionEnabled?: boolean } = {}): void {
    // Kept for compatibility with existing callers; pointer-lock uses raw movementX/Y.
    void remoteResolutionEnabled;
  }

  updateWindowMath(): void {
    // Compatibility no-op (legacy Selkies input path removed).
  }

  private addListener(target: EventTarget, event: string, handler: EventListener, options?: AddEventListenerOptions | boolean): void {
    target.addEventListener(event, handler, options);
    this.listeners.push([target, event, handler, options]);
  }

  private addListenerContext(target: EventTarget, event: string, handler: EventListener, options?: AddEventListenerOptions | boolean): void {
    target.addEventListener(event, handler, options);
    this.listeners_context.push([target, event, handler, options]);
  }

  private removeListeners(listeners: Listener[]): void {
    listeners.forEach(([target, event, handler, options]) => {
      target.removeEventListener(event, handler, options);
    });
    listeners.length = 0;
  }
}


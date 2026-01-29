/**
 * Warplay control-plane client:
 * - WebSocket signaling (JSON offer/answer/candidates)
 * - Separate WebRTC PeerConnection for input/gamepad/cursor (datachannels)
 * - Binary protocol 0x01..0x09 compatible with warplay-srs-server
 */
export interface WarplayControlCallbacks {
  onstatus?: (message: string) => void;
  onerror?: (message: string) => void;
  onconnected?: () => void;
  ondisconnected?: () => void;
  oncursor?: (handle: number, curdataBase64: string, hotspot: { x: number; y: number } | null, override: string | null) => void;
  ongamepadconnected?: (gamepadId: string) => void;
  ongamepaddisconnected?: () => void;
}

export interface WarplayControlConfig {
  wsUrl: string;
  rtcConfig: RTCConfiguration;
}

function clampI16(v: number): number {
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return v | 0;
}

function clampU16(v: number): number {
  if (v > 65535) return 65535;
  if (v < 0) return 0;
  return v | 0;
}

function clampU8(v: number): number {
  if (v > 255) return 255;
  if (v < 0) return 0;
  return v | 0;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

export class WarplayControl {
  private cfg: WarplayControlConfig;
  private callbacks: WarplayControlCallbacks = {};

  private ws: WebSocket | null = null;
  private pc: RTCPeerConnection | null = null;
  private inputDc: RTCDataChannel | null = null;
  private gamepadDc: RTCDataChannel | null = null;
  private rumbleDc: RTCDataChannel | null = null;
  private cursorDc: RTCDataChannel | null = null;

  private connected = false;
  private gamepadTimer: number | null = null;
  private activeGamepadIndex: number | null = null;
  private lastGamepadPacketHex: string | null = null;

  constructor(cfg: WarplayControlConfig) {
    this.cfg = cfg;
  }

  setCallbacks(callbacks: WarplayControlCallbacks): void {
    this.callbacks = { ...this.callbacks, ...callbacks };
  }

  isConnected(): boolean {
    return this.connected;
  }

  connect(): void {
    this.disconnect();

    try {
      this.ws = new WebSocket(this.cfg.wsUrl);
    } catch (e: any) {
      this.callbacks.onerror?.(`control ws init failed: ${String(e)}`);
      return;
    }

    this.ws.onopen = () => {
      this.callbacks.onstatus?.(`[control] ws connected: ${this.cfg.wsUrl}`);
      this.createPeer();
    };
    this.ws.onclose = () => {
      this.callbacks.onstatus?.('[control] ws closed');
      this.setDisconnected();
    };
    this.ws.onerror = () => {
      this.callbacks.onerror?.('[control] ws error');
    };
    this.ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        this.onSignal(msg);
      } catch (e: any) {
        this.callbacks.onerror?.(`[control] bad signal json: ${String(e)}`);
      }
    };
  }

  disconnect(): void {
    this.stopGamepadPolling();
    this.connected = false;
    this.lastGamepadPacketHex = null;
    this.activeGamepadIndex = null;

    try {
      this.inputDc?.close();
    } catch { }
    try {
      this.gamepadDc?.close();
    } catch { }
    try {
      this.rumbleDc?.close();
    } catch { }
    try {
      this.cursorDc?.close();
    } catch { }
    this.inputDc = null;
    this.gamepadDc = null;
    this.rumbleDc = null;
    this.cursorDc = null;

    try {
      this.pc?.close();
    } catch { }
    this.pc = null;

    try {
      this.ws?.close();
    } catch { }
    this.ws = null;
  }

  sendInputPacket(pkt: Uint8Array): void {
    if (!this.inputDc || this.inputDc.readyState !== 'open') return;
    try {
      this.inputDc.send(pkt);
    } catch { }
  }

  private sendGamepadPacket(pkt: Uint8Array): void {
    if (!this.gamepadDc || this.gamepadDc.readyState !== 'open') return;
    try {
      this.gamepadDc.send(pkt);
    } catch { }
  }

  private sendSignal(payload: any): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    try {
      this.ws.send(JSON.stringify(payload));
    } catch { }
  }

  private createPeer(): void {
    this.pc = new RTCPeerConnection(this.cfg.rtcConfig);
    this.pc.onicecandidate = (ev) => {
      if (!ev.candidate) return;
      this.sendSignal(ev.candidate.toJSON());
    };
    this.pc.onconnectionstatechange = () => {
      const st = this.pc?.connectionState;
      this.callbacks.onstatus?.(`[control] pc state: ${st}`);
      if (st === 'connected') {
        this.setConnected();
      }
      if (st === 'failed' || st === 'disconnected' || st === 'closed') {
        this.setDisconnected();
      }
    };

    // Negotiated channels expected by server: input(id=1), gamepad(id=2), rumble(id=3).
    this.inputDc = this.pc.createDataChannel('input', {
      negotiated: true,
      id: 1,
      ordered: false,
      maxRetransmits: 0,
    });
    this.inputDc.binaryType = 'arraybuffer';
    this.inputDc.onopen = () => {
      this.callbacks.onstatus?.('[control] input dc open');
    };
    this.inputDc.onmessage = (ev) => {
      // Ignore keepalive text from server.
      void ev;
    };

    this.gamepadDc = this.pc.createDataChannel('gamepad', {
      negotiated: true,
      id: 2,
      ordered: false,
      maxRetransmits: 0,
    });
    this.gamepadDc.binaryType = 'arraybuffer';
    this.gamepadDc.onopen = () => {
      this.callbacks.onstatus?.('[control] gamepad dc open');
      this.startGamepadPolling();
    };

    this.rumbleDc = this.pc.createDataChannel('rumble', {
      negotiated: true,
      id: 3,
      ordered: false,
      maxRetransmits: 0,
    });
    this.rumbleDc.binaryType = 'arraybuffer';
    this.rumbleDc.onopen = () => {
      this.callbacks.onstatus?.('[control] rumble dc open');
    };
    this.rumbleDc.onmessage = (ev) => this.onRumble(ev);

    // Extra unnegotiated DC to receive cursor sprite packets (server stores default channel refs).
    this.cursorDc = this.pc.createDataChannel('cursor', {
      ordered: false,
      maxRetransmits: 0,
    });
    this.cursorDc.binaryType = 'arraybuffer';
    this.cursorDc.onmessage = (ev) => this.onCursor(ev);

    this.pc.createOffer().then((offer) => {
      return this.pc!.setLocalDescription(offer).then(() => offer);
    }).then((offer) => {
      this.sendSignal({ type: 'offer', sdp: offer.sdp });
    }).catch((e: any) => {
      this.callbacks.onerror?.(`[control] createOffer failed: ${String(e)}`);
    });
  }

  private onSignal(msg: any): void {
    if (!this.pc) return;

    if (msg && msg.type === 'answer' && msg.sdp) {
      const desc = new RTCSessionDescription({ type: 'answer', sdp: msg.sdp });
      this.pc.setRemoteDescription(desc).catch((e) => {
        this.callbacks.onerror?.(`[control] setRemoteDescription failed: ${String(e)}`);
      });
      return;
    }

    // ICE candidate
    if (msg && (msg.candidate || msg.sdpMLineIndex !== undefined || msg.sdpMid !== undefined)) {
      const cand = new RTCIceCandidate(msg);
      this.pc.addIceCandidate(cand).catch((e) => {
        // Some candidates can fail if peer is not ready; log and continue.
        this.callbacks.onerror?.(`[control] addIceCandidate failed: ${String(e)}`);
      });
    }
  }

  private setConnected(): void {
    if (this.connected) return;
    this.connected = true;
    this.callbacks.onconnected?.();
  }

  private setDisconnected(): void {
    if (!this.connected) return;
    this.connected = false;
    this.stopGamepadPolling();
    this.callbacks.ondisconnected?.();
  }

  // ---------------- Gamepad (0x08) ----------------
  private startGamepadPolling(): void {
    if (this.gamepadTimer !== null) return;

    const poll = () => {
      this.gamepadTimer = window.requestAnimationFrame(poll);
      this.pollGamepadOnce();
    };
    this.gamepadTimer = window.requestAnimationFrame(poll);
  }

  private stopGamepadPolling(): void {
    if (this.gamepadTimer !== null) {
      window.cancelAnimationFrame(this.gamepadTimer);
      this.gamepadTimer = null;
    }
  }

  private pollGamepadOnce(): void {
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    if (!pads) return;

    let gp: Gamepad | null = null;
    if (this.activeGamepadIndex !== null && pads[this.activeGamepadIndex]) {
      gp = pads[this.activeGamepadIndex]!;
    } else {
      for (let i = 0; i < pads.length; i++) {
        if (pads[i]) {
          this.activeGamepadIndex = i;
          gp = pads[i]!;
          this.callbacks.ongamepadconnected?.(gp.id);
          break;
        }
      }
    }

    if (!gp) {
      if (this.activeGamepadIndex !== null) {
        this.activeGamepadIndex = null;
        this.callbacks.ongamepaddisconnected?.();
      }
      return;
    }

    const pkt = this.encodeGamepadPacket(gp);
    const hex = this.hexPreview(pkt, 64);
    if (hex !== this.lastGamepadPacketHex) {
      this.lastGamepadPacketHex = hex;
      this.sendGamepadPacket(pkt);
    }
  }

  private encodeGamepadPacket(gp: Gamepad): Uint8Array {
    const buf = new ArrayBuffer(24);
    const view = new DataView(buf);
    view.setUint8(0, 0x08); // Gamepad
    view.setUint8(1, 0); // pad_index reserved

    // Standard mapping (Xbox-like):
    // buttons: 0 A,1 B,2 X,3 Y,4 LB,5 RB,8 Back,9 Start,10 LS,11 RS,16 Guide
    let mask = 0;
    const pressed = (idx: number) => (gp.buttons[idx]?.pressed ? 1 : 0);
    mask |= pressed(0) << 0;
    mask |= pressed(1) << 1;
    mask |= pressed(2) << 2;
    mask |= pressed(3) << 3;
    mask |= pressed(4) << 4;
    mask |= pressed(5) << 5;
    mask |= pressed(8) << 6;
    mask |= pressed(9) << 7;
    mask |= pressed(10) << 8;
    mask |= pressed(11) << 9;
    mask |= pressed(16) << 10;
    view.setUint16(2, mask & 0xffff, true);

    const axis = (idx: number) => {
      const v = gp.axes[idx] ?? 0;
      const clamped = Math.max(-1, Math.min(1, v));
      return clampI16(Math.round(clamped * 32767));
    };
    view.setInt16(4, axis(0), true); // lx
    view.setInt16(6, axis(1), true); // ly
    view.setInt16(8, axis(2), true); // rx
    view.setInt16(10, axis(3), true); // ry

    const trigger = (idx: number) => clampU8(Math.round((gp.buttons[idx]?.value ?? 0) * 255));
    view.setUint8(12, trigger(6)); // lt
    view.setUint8(13, trigger(7)); // rt

    const dpad = (idx: number) => (gp.buttons[idx]?.pressed ? 1 : 0);
    const hatX = dpad(15) - dpad(14); // right - left
    const hatY = dpad(13) - dpad(12); // down - up
    view.setInt8(14, hatX);
    view.setInt8(15, hatY);
    // 16..23 reserved = 0
    return new Uint8Array(buf);
  }

  // ---------------- Cursor sprite (0x07) ----------------
  private onCursor(ev: MessageEvent): void {
    const data = ev.data;
    if (!(data instanceof ArrayBuffer)) return;
    const u8 = new Uint8Array(data);
    if (u8.length < 13 || u8[0] !== 0x07) return;

    const view = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const width = view.getUint16(1, true);
    const height = view.getUint16(3, true);
    const hotX = view.getUint16(5, true);
    const hotY = view.getUint16(7, true);
    const pngLen = view.getUint32(9, true);
    const pngStart = 13;
    if (pngStart + pngLen > u8.length) return;

    if (width === 0 || height === 0) {
      // Hidden cursor.
      this.callbacks.oncursor?.(1, '', null, 'none');
      return;
    }

    const png = u8.subarray(pngStart, pngStart + pngLen);
    const base64 = bytesToBase64(png);
    // Use a stable handle derived from dimensions to reuse cache across updates.
    const handle = ((width & 0xffff) << 16) | (height & 0xffff);
    this.callbacks.oncursor?.(handle, base64, { x: hotX, y: hotY }, null);
  }

  // ---------------- Rumble (0x09) ----------------
  private onRumble(ev: MessageEvent): void {
    const data = ev.data;
    if (!(data instanceof ArrayBuffer)) return;
    const u8 = new Uint8Array(data);
    if (u8.length < 6 || u8[0] !== 0x09) return;
    const duration = u8[1] | (u8[2] << 8);
    const strong = u8[3];
    const weak = u8[4];

    const idx = this.activeGamepadIndex;
    if (idx === null) return;
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    const gp = pads && pads[idx] ? pads[idx]! : null;
    if (!gp) return;

    const actuator: any = (gp as any).vibrationActuator;
    if (!actuator || typeof actuator.playEffect !== 'function') return;

    const strongMagnitude = strong / 255;
    const weakMagnitude = weak / 255;
    actuator.playEffect('dual-rumble', {
      startDelay: 0,
      duration,
      strongMagnitude,
      weakMagnitude,
    }).catch(() => { });
  }

  // ---------------- Input encoders ----------------
  encodeMouseMove(dx: number, dy: number): Uint8Array {
    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, 0x01);
    view.setInt16(1, clampI16(dx), true);
    view.setInt16(3, clampI16(dy), true);
    return new Uint8Array(buf);
  }

  encodeMouseButton(button: number, down: boolean): Uint8Array {
    return new Uint8Array([0x02, button & 0xff, down ? 1 : 0]);
  }

  encodeWheel(deltaY: number): Uint8Array {
    const buf = new ArrayBuffer(3);
    const view = new DataView(buf);
    view.setUint8(0, 0x03);
    view.setInt16(1, clampI16(deltaY), true);
    return new Uint8Array(buf);
  }

  encodeKey(vkCode: number, down: boolean): Uint8Array {
    const buf = new ArrayBuffer(4);
    const view = new DataView(buf);
    view.setUint8(0, 0x04);
    view.setUint16(1, clampU16(vkCode), true);
    view.setUint8(3, down ? 1 : 0);
    return new Uint8Array(buf);
  }

  encodeAbsMouse(x16: number, y16: number): Uint8Array {
    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, 0x06);
    view.setUint16(1, clampU16(x16), true);
    view.setUint16(3, clampU16(y16), true);
    return new Uint8Array(buf);
  }

  private hexPreview(buf: Uint8Array, maxBytes: number): string {
    const n = Math.min(buf.length, maxBytes);
    let out = '';
    for (let i = 0; i < n; i++) out += buf[i]!.toString(16).padStart(2, '0');
    return out + (buf.length > n ? '…' : '');
  }
}

/**
 * WebRTC демо клиент
 */

import { WebRTCDemoSignalling, SignallingCallbacks } from './signalling';
import { Input } from './input';
import { base64ToString } from './util';

export interface WebRTCCallbacks {
  ondebug?: (message: string) => void;
  onstatus?: (message: string) => void;
  onerror?: (message: string) => void;
  onconnectionstatechange?: (state: string) => void;
  ondatachannelclose?: () => void;
  ondatachannelopen?: () => void;
  onplaystreamrequired?: () => void;
  onclipboardcontent?: (content: string) => void;
  ongpustats?: (data: { load: number; memory_total: number; memory_used: number }) => void;
  onlatencymeasurement?: (latency_ms: number) => void;
  onsystemaction?: (action: string) => void;
  oncursorchange?: (handle: number, curdata: string, hotspot: { x: number; y: number } | null, override: string | null) => void;
  onsystemstats?: (stats: { cpu_percent?: number; mem_total?: number; mem_used?: number }) => void;
}

export interface ConnectionStats {
  general: {
    bytesReceived: number;
    bytesSent: number;
    connectionType: string;
    currentRoundTripTime: number | null;
    availableReceiveBandwidth: number;
  };
  video: {
    bytesReceived: number;
    decoder: string;
    frameHeight: number;
    frameWidth: number;
    framesPerSecond: number;
    packetsReceived: number;
    packetsLost: number;
    codecName: string;
    jitterBufferDelay: number;
    jitterBufferEmittedCount: number;
  };
  audio: {
    bytesReceived: number;
    packetsReceived: number;
    packetsLost: number;
    codecName: string;
    jitterBufferDelay: number;
    jitterBufferEmittedCount: number;
  };
  data: {
    bytesReceived: number;
    bytesSent: number;
    messagesReceived: number;
    messagesSent: number;
  };
  allReports: any[];
}

export class WebRTCDemo {
  public signalling: WebRTCDemoSignalling;
  public element: HTMLVideoElement | HTMLAudioElement;
  public peer_id: number;
  public forceTurn: boolean = false;
  public rtcPeerConfig: RTCConfiguration = {
    iceServers: [
      {
        urls: ["stun:stun.l.google.com:19302"]
      }
    ],
    iceTransportPolicy: "all"
  };
  public peerConnection: RTCPeerConnection | null = null;
  public input: Input;
  public cursor_cache: Map<number, string> = new Map();

  private callbacks: WebRTCCallbacks = {};
  private _connected: boolean = false;
  public _send_channel: RTCDataChannel | null = null;
  private streams: Array<[string, MediaStream[]]> = [];

  constructor(signalling: WebRTCDemoSignalling, element: HTMLVideoElement | HTMLAudioElement, peer_id: number) {
    this.signalling = signalling;
    this.element = element;
    this.peer_id = peer_id;

    this.input = new Input(element as HTMLVideoElement);

    // Привязываем callbacks signalling сервера
    this.signalling.setCallbacks({
      onsdp: this.onSDP.bind(this),
      onice: this.onSignallingICE.bind(this)
    });
  }

  setCallbacks(callbacks: WebRTCCallbacks): void {
    this.callbacks = { ...this.callbacks, ...callbacks };
  }

  private setStatus(message: string): void {
    if (this.callbacks.onstatus) {
      this.callbacks.onstatus(message);
    }
  }

  private setDebug(message: string): void {
    if (this.callbacks.ondebug) {
      this.callbacks.ondebug(message);
    }
  }

  private setError(message: string): void {
    if (this.callbacks.onerror) {
      this.callbacks.onerror(message);
    }
  }

  private setConnectionState(state: string): void {
    if (this.callbacks.onconnectionstatechange) {
      this.callbacks.onconnectionstatechange(state);
    }
  }

  /**
   * Обрабатывает входящий ICE кандидат от signalling сервера
   */
  private onSignallingICE(icecandidate: RTCIceCandidate): void {
    this.setDebug("received ice candidate from signalling server: " + JSON.stringify(icecandidate));
    if (this.forceTurn && JSON.stringify(icecandidate).indexOf("relay") < 0) {
      this.setDebug("Rejecting non-relay ICE candidate: " + JSON.stringify(icecandidate));
      return;
    }
    if (this.peerConnection) {
      this.peerConnection.addIceCandidate(icecandidate).catch(this.setError);
    }
  }

  /**
   * Обработчик ICE кандидата от peer connection
   */
  private onPeerICE = (event: RTCPeerConnectionIceEvent): void => {
    if (event.candidate === null) {
      this.setStatus("Completed ICE candidates from peer connection");
      return;
    }
    this.signalling.sendICE(event.candidate);
  };

  /**
   * Обрабатывает входящий SDP от signalling сервера
   */
  private onSDP(sdp: RTCSessionDescription): void {
    if (sdp.type !== "offer") {
      this.setError("received SDP was not type offer.");
      return;
    }
    console.log("Received remote SDP", sdp);
    if (!this.peerConnection) return;

    this.peerConnection.setRemoteDescription(sdp).then(() => {
      this.setDebug("received SDP offer, creating answer");
      this.peerConnection!.createAnswer()
        .then((local_sdp) => {
          if (!local_sdp.sdp) {
            throw new Error("SDP is undefined");
          }
          // Устанавливаем sps-pps-idr-in-keyframe=1
          if (!(/[^-]sps-pps-idr-in-keyframe=1[^\d]/gm.test(local_sdp.sdp)) && (/[^-]packetization-mode=/gm.test(local_sdp.sdp))) {
            console.log("Overriding WebRTC SDP to include sps-pps-idr-in-keyframe=1");
            if (/[^-]sps-pps-idr-in-keyframe=\d+/gm.test(local_sdp.sdp)) {
              local_sdp.sdp = local_sdp.sdp.replace(/sps-pps-idr-in-keyframe=\d+/gm, 'sps-pps-idr-in-keyframe=1');
            } else {
              local_sdp.sdp = local_sdp.sdp.replace('packetization-mode=', 'sps-pps-idr-in-keyframe=1;packetization-mode=');
            }
          }
          if (local_sdp.sdp.indexOf('multiopus') === -1) {
            // Включаем стерео для WebRTC Opus с Chromium
            if (!(/[^-]stereo=1[^\d]/gm.test(local_sdp.sdp)) && (/[^-]useinbandfec=/gm.test(local_sdp.sdp))) {
              console.log("Overriding WebRTC SDP to allow stereo audio");
              if (/[^-]stereo=\d+/gm.test(local_sdp.sdp)) {
                local_sdp.sdp = local_sdp.sdp.replace(/stereo=\d+/gm, 'stereo=1');
              } else {
                local_sdp.sdp = local_sdp.sdp.replace('useinbandfec=', 'stereo=1;useinbandfec=');
              }
            }
            // Уменьшаем размер пакета до 10 мс
            if (!(/[^-]minptime=10[^\d]/gm.test(local_sdp.sdp)) && (/[^-]useinbandfec=/gm.test(local_sdp.sdp))) {
              console.log("Overriding WebRTC SDP to allow low-latency audio packet");
              if (/[^-]minptime=\d+/gm.test(local_sdp.sdp)) {
                local_sdp.sdp = local_sdp.sdp.replace(/minptime=\d+/gm, 'minptime=10');
              } else {
                local_sdp.sdp = local_sdp.sdp.replace('useinbandfec=', 'minptime=10;useinbandfec=');
              }
            }
          }
          console.log("Created local SDP", local_sdp);
          this.peerConnection!.setLocalDescription(local_sdp).then(() => {
            this.setDebug("Sending SDP answer");
            this.signalling.sendSDP(this.peerConnection!.localDescription!);
          });
        }).catch(() => {
          this.setError("Error creating local SDP");
        });
    });
  }

  /**
   * Обрабатывает входящий track от peer connection
   */
  private onTrack = (event: RTCTrackEvent): void => {
    this.setStatus(`Received incoming ${event.track.kind} stream from peer`);
    if (!this.streams) this.streams = [];
    this.streams.push([event.track.kind, Array.from(event.streams)]);
    if (event.track.kind === "video" || event.track.kind === "audio") {
      this.element.srcObject = event.streams[0];
      this.playStream();
    }
  };

  /**
   * Обрабатывает входящие data channel события от peer connection
   */
  private onPeerDataChannel = (event: RTCDataChannelEvent): void => {
    this.setStatus("Peer data channel created: " + event.channel.label);

    this._send_channel = event.channel;
    this._send_channel.onmessage = this.onPeerDataChannelMessage.bind(this);
    this._send_channel.onopen = () => {
      if (this.callbacks.ondatachannelopen) {
        this.callbacks.ondatachannelopen();
      }
    };
    this._send_channel.onclose = () => {
      if (this.callbacks.ondatachannelclose) {
        this.callbacks.ondatachannelclose();
      }
    };
  };

  /**
   * Обрабатывает сообщения от peer data channel
   */
  private onPeerDataChannelMessage(event: MessageEvent): void {
    let msg: any;
    try {
      msg = JSON.parse(event.data);
    } catch (e) {
      if (e instanceof SyntaxError) {
        this.setError("error parsing data channel message as JSON: " + event.data);
      } else {
        this.setError("failed to parse data channel message: " + event.data);
      }
      return;
    }

    this.setDebug("data channel message: " + event.data);

    if (msg.type === 'pipeline') {
      this.setStatus(msg.data.status);
    } else if (msg.type === 'gpu_stats') {
      if (this.callbacks.ongpustats) {
        this.callbacks.ongpustats(msg.data);
      }
    } else if (msg.type === 'clipboard') {
      if (msg.data !== null) {
        const content = msg.data.content;
        const text = base64ToString(content);
        this.setDebug("received clipboard contents, length: " + content.length);

        if (this.callbacks.onclipboardcontent) {
          this.callbacks.onclipboardcontent(text);
        }
      }
    } else if (msg.type === 'cursor') {
      if (this.callbacks.oncursorchange && msg.data !== null) {
        const curdata = msg.data.curdata;
        const handle = msg.data.handle;
        const hotspot = msg.data.hotspot;
        const override = msg.data.override;
        this.setDebug(`received new cursor contents, handle: ${handle}, hotspot: ${JSON.stringify(hotspot)} image length: ${curdata.length}`);
        this.callbacks.oncursorchange(handle, curdata, hotspot, override);
      }
    } else if (msg.type === 'system') {
      if (msg.action !== null) {
        this.setDebug("received system msg, action: " + msg.data.action);
        const action = msg.data.action;
        if (this.callbacks.onsystemaction) {
          this.callbacks.onsystemaction(action);
        }
      }
    } else if (msg.type === 'ping') {
      this.setDebug("received server ping: " + JSON.stringify(msg.data));
      this.sendDataChannelMessage("pong," + new Date().getTime() / 1000);
    } else if (msg.type === 'system_stats') {
      this.setDebug("received systems stats: " + JSON.stringify(msg.data));
      if (this.callbacks.onsystemstats) {
        this.callbacks.onsystemstats(msg.data);
      }
    } else if (msg.type === 'latency_measurement') {
      if (this.callbacks.onlatencymeasurement) {
        this.callbacks.onlatencymeasurement(msg.data.latency_ms);
      }
    } else {
      this.setError("Unhandled message received: " + msg.type);
    }
  }

  /**
   * Обрабатывает изменение состояния peer connection
   */
  private handleConnectionStateChange(state: string): void {
    switch (state) {
      case "connected":
        this.setStatus("Connection complete");
        this._connected = true;
        break;

      case "disconnected":
        this.setError("Peer connection disconnected");
        if (this._send_channel !== null && this._send_channel.readyState === 'open') {
          this._send_channel.close();
        }
        this.element.load();
        break;

      case "failed":
        this.setError("Peer connection failed");
        this.element.load();
        break;
      default:
    }
  }

  /**
   * Отправляет сообщение в peer data channel
   */
  sendDataChannelMessage(message: string): void {
    if (this._send_channel !== null && this._send_channel.readyState === 'open') {
      this._send_channel.send(message);
    } else {
      this.setError("attempt to send data channel message before channel was open.");
    }
  }

  /**
   * Получает статистику подключения
   */
  getConnectionStats(): Promise<ConnectionStats> {
    const pc = this.peerConnection;
    if (!pc) {
      return Promise.reject(new Error("Peer connection not initialized"));
    }

    const connectionDetails: ConnectionStats = {
      general: {
        bytesReceived: 0,
        bytesSent: 0,
        connectionType: "NA",
        currentRoundTripTime: null,
        availableReceiveBandwidth: 0,
      },
      video: {
        bytesReceived: 0,
        decoder: "NA",
        frameHeight: 0,
        frameWidth: 0,
        framesPerSecond: 0,
        packetsReceived: 0,
        packetsLost: 0,
        codecName: "NA",
        jitterBufferDelay: 0,
        jitterBufferEmittedCount: 0,
      },
      audio: {
        bytesReceived: 0,
        packetsReceived: 0,
        packetsLost: 0,
        codecName: "NA",
        jitterBufferDelay: 0,
        jitterBufferEmittedCount: 0,
      },
      data: {
        bytesReceived: 0,
        bytesSent: 0,
        messagesReceived: 0,
        messagesSent: 0,
      },
      allReports: []
    };

    return new Promise((resolve, reject) => {
      pc.getStats().then((stats) => {
        const reports: any = {
          transports: {},
          candidatePairs: {},
          selectedCandidatePairId: null,
          remoteCandidates: {},
          codecs: {},
          videoRTP: null,
          videoTrack: null,
          audioRTP: null,
          audioTrack: null,
          dataChannel: null,
        };

        const allReports: any[] = [];

        stats.forEach((report) => {
          allReports.push(report);
          if (report.type === "transport") {
            reports.transports[report.id] = report;
          } else if (report.type === "candidate-pair") {
            reports.candidatePairs[report.id] = report;
            if ((report as any).selected === true) {
              reports.selectedCandidatePairId = report.id;
            }
          } else if (report.type === "inbound-rtp") {
            if ((report as any).kind === "video") {
              reports.videoRTP = report;
            } else if ((report as any).kind === "audio") {
              reports.audioRTP = report;
            }
          } else if (report.type === "track") {
            if ((report as any).kind === "video") {
              reports.videoTrack = report;
            } else if ((report as any).kind === "audio") {
              reports.audioTrack = report;
            }
          } else if (report.type === "data-channel") {
            reports.dataChannel = report;
          } else if (report.type === "remote-candidate") {
            reports.remoteCandidates[report.id] = report;
          } else if (report.type === "codec") {
            reports.codecs[report.id] = report;
          }
        });

        // Извлекаем статистику видео
        const videoRTP = reports.videoRTP;
        if (videoRTP !== null) {
          connectionDetails.video.bytesReceived = (videoRTP as any).bytesReceived || 0;
          connectionDetails.video.decoder = (videoRTP as any).decoderImplementation || "unknown";
          connectionDetails.video.frameHeight = (videoRTP as any).frameHeight || 0;
          connectionDetails.video.frameWidth = (videoRTP as any).frameWidth || 0;
          connectionDetails.video.framesPerSecond = (videoRTP as any).framesPerSecond || 0;
          connectionDetails.video.packetsReceived = (videoRTP as any).packetsReceived || 0;
          connectionDetails.video.packetsLost = (videoRTP as any).packetsLost || 0;

          const codec = reports.codecs[(videoRTP as any).codecId];
          if (codec !== undefined) {
            connectionDetails.video.codecName = (codec as any).mimeType.split("/")[1].toUpperCase();
          }
        }

        // Извлекаем статистику аудио
        const audioRTP = reports.audioRTP;
        if (audioRTP !== null) {
          connectionDetails.audio.bytesReceived = (audioRTP as any).bytesReceived || 0;
          connectionDetails.audio.packetsReceived = (audioRTP as any).packetsReceived || 0;
          connectionDetails.audio.packetsLost = (audioRTP as any).packetsLost || 0;

          const codec = reports.codecs[(audioRTP as any).codecId];
          if (codec !== undefined) {
            connectionDetails.audio.codecName = (codec as any).mimeType.split("/")[1].toUpperCase();
          }
        }

        const dataChannel = reports.dataChannel;
        if (dataChannel !== null) {
          connectionDetails.data.bytesReceived = (dataChannel as any).bytesReceived || 0;
          connectionDetails.data.bytesSent = (dataChannel as any).bytesSent || 0;
          connectionDetails.data.messagesReceived = (dataChannel as any).messagesReceived || 0;
          connectionDetails.data.messagesSent = (dataChannel as any).messagesSent || 0;
        }

        // Извлекаем транспортную статистику
        if (Object.keys(reports.transports).length > 0) {
          const transport = reports.transports[Object.keys(reports.transports)[0]];
          connectionDetails.general.bytesReceived = (transport as any).bytesReceived || 0;
          connectionDetails.general.bytesSent = (transport as any).bytesSent || 0;
          reports.selectedCandidatePairId = (transport as any).selectedCandidatePairId;
        } else if (reports.selectedCandidatePairId !== null) {
          const pair = reports.candidatePairs[reports.selectedCandidatePairId];
          if (pair) {
            connectionDetails.general.bytesReceived = (pair as any).bytesReceived || 0;
            connectionDetails.general.bytesSent = (pair as any).bytesSent || 0;
          }
        }

        // Получаем connection-pair
        if (reports.selectedCandidatePairId !== null) {
          const candidatePair = reports.candidatePairs[reports.selectedCandidatePairId];
          if (candidatePair !== undefined) {
            if ((candidatePair as any).availableIncomingBitrate !== undefined) {
              connectionDetails.general.availableReceiveBandwidth = (candidatePair as any).availableIncomingBitrate;
            }
            if ((candidatePair as any).currentRoundTripTime !== undefined) {
              connectionDetails.general.currentRoundTripTime = (candidatePair as any).currentRoundTripTime;
            }
            const remoteCandidate = reports.remoteCandidates[(candidatePair as any).remoteCandidateId];
            if (remoteCandidate !== undefined) {
              connectionDetails.general.connectionType = (remoteCandidate as any).candidateType;
            }
          }
        }

        // Вычисляем jitter buffer delay для видео
        if (reports.videoRTP !== null) {
          connectionDetails.video.jitterBufferDelay = (reports.videoRTP as any).jitterBufferDelay || 0;
          connectionDetails.video.jitterBufferEmittedCount = (reports.videoRTP as any).jitterBufferEmittedCount || 0;
        }

        // Вычисляем jitter buffer delay для аудио
        if (reports.audioRTP !== null) {
          connectionDetails.audio.jitterBufferDelay = (reports.audioRTP as any).jitterBufferDelay || 0;
          connectionDetails.audio.jitterBufferEmittedCount = (reports.audioRTP as any).jitterBufferEmittedCount || 0;
        }

        connectionDetails.allReports = allReports;

        resolve(connectionDetails);
      }).catch((e) => reject(e));
    });
  }

  /**
   * Начинает воспроизведение потока
   */
  playStream(): void {
    this.element.load();

    const playPromise = this.element.play();
    if (playPromise !== undefined) {
      playPromise.then(() => {
        this.setDebug("Stream is playing.");
      }).catch(() => {
        if (this.callbacks.onplaystreamrequired) {
          this.callbacks.onplaystreamrequired();
        } else {
          this.setDebug("Stream play failed and no onplaystreamrequired was bound.");
        }
      });
    }
  }

  /**
   * Инициирует подключение к signalling серверу
   */
  connect(): void {
    // Создаем peer connection объект и привязываем callbacks
    this.peerConnection = new RTCPeerConnection(this.rtcPeerConfig);
    this.peerConnection.ontrack = this.onTrack;
    this.peerConnection.onicecandidate = this.onPeerICE;
    this.peerConnection.ondatachannel = this.onPeerDataChannel;

    this.peerConnection.onconnectionstatechange = () => {
      if (!this.peerConnection) return;
      // Локальная обработка события
      this.handleConnectionStateChange(this.peerConnection.connectionState);

      // Передаем состояние слушателям событий
      this.setConnectionState(this.peerConnection.connectionState);
    };

    if (this.forceTurn) {
      this.setStatus("forcing use of TURN server");
      const config = this.peerConnection.getConfiguration();
      config.iceTransportPolicy = "relay";
      this.peerConnection.setConfiguration(config);
    }

    this.signalling.peer_id = this.peer_id;
    this.signalling.connect();
  }

  /**
   * Пытается сбросить webrtc подключение
   */
  reset(): void {
    // Очищаем кэш курсора
    this.cursor_cache = new Map();

    if (!this.peerConnection) return;
    const signalState = this.peerConnection.signalingState;
    if (this._send_channel !== null && this._send_channel.readyState === "open") {
      this._send_channel.close();
    }
    this.peerConnection.close();
    if (signalState !== "stable") {
      setTimeout(() => {
        this.connect();
      }, 3000);
    } else {
      this.connect();
    }
  }
}

